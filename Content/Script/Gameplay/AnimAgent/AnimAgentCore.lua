--[[
    AnimAgentCore.lua
    AnimAgent 顶层编排器（Phase L1：本地导入）

    职责：
    - 持有 UAnimGenClient（C++ 组件）的引用
    - 订阅 OnAssetImported / OnAssetImportFailed
    - 资产导入完成后：
        ① 写入 AnimAssetLibrary
        ② 注册到 UGCPrefabRegistry 的 dyn:{uuid} 命名空间
        ③ （可选）触发 ImportBridge 加载为 UStaticMesh，缓存待用
    - 提供 Lua 侧 API 给 UI 调用：
        Core:ImportLocal(filePath, name)  → uuid
        Core:ExportLocal(uuid, targetPath) → bool
        Core:ListAssets()
        Core:RemoveAsset(uuid)

    依赖：
    - PlayerController 必须挂 UAnimGenClient（蓝图配置）
    - 可选挂 UAnimImportBridge（无则跳过 mesh 加载，仅做元数据登记）
]]

local Library  = require("Gameplay.AnimAgent.AnimAssetLibrary")
local Registry = require("Gameplay.UGC.UGCPrefabRegistry")

local Core = {}

local _pc      = nil
local _client  = nil   -- UAnimGenClient*
local _import  = nil   -- UAnimImportBridge*  (可选)
local _initialized = false

local function _packagesRoot()
    local ok, dir = pcall(function() return UE.UAnimGenClient.GetUGCPackagesRootDir() end)
    if ok and dir and dir ~= "" then
        return dir:gsub("\\", "/")
    end
    return UE.UKismetSystemLibrary.GetProjectDirectory() .. "Saved/UGC/Packages"
end

local function _manifestPath(packageID)
    return string.format("%s/%s/manifest.json", _packagesRoot():gsub("/$", ""), packageID)
end

local function _readManifest(manifestPath)
    local f = io.open(manifestPath, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local ok, json = pcall(require, "Gameplay.UGC.json")
    if not ok or not json then return nil end
    local okDecode, manifest = pcall(function() return json.decode(content) end)
    return okDecode and manifest or nil
end

--============================================================
-- 初始化
--============================================================

--- @param playerController APlayerController*
--- @param opts? { import_bridge?: UAnimImportBridge* }
function Core:Init(playerController, opts)
    if _initialized then return true end
    if not playerController then
        print("[AnimAgentCore] Init 失败：playerController 为 nil")
        return false
    end

    -- 优先用 GetAnimGenClient 蓝图 getter（需在 BP 里实现），失败兜底 GetComponentByClass
    local client = nil
    pcall(function() client = playerController:GetAnimGenClient() end)
    if not client then
        pcall(function() client = playerController:GetComponentByClass(UE.UAnimGenClient) end)
    end

    -- UnLua 的 GetComponentByClass 在没找到时可能返回"包了 nullptr 的 wrapper"而不是 nil；
    -- 用 IsValid 二次校验
    local valid = false
    if client then
        local ok, isValid = pcall(function() return UE.UKismetSystemLibrary.IsValid(client) end)
        valid = ok and isValid
    end
    if not valid then
        print("[AnimAgentCore] Init 失败：PlayerController 上没找到 UAnimGenClient 组件")
        print("[AnimAgentCore]   → 请打开 PlayerController 蓝图，Add Component 加 AnimGenClient")
        print("[AnimAgentCore]   → 当前 PlayerController 类: " .. tostring(playerController:GetClass():GetName()))
        return false
    end

    -- 同样 try import bridge（蓝图里挂没挂都能用，没挂就 nil，跳过 mesh 预加载）
    local importBridge = opts and opts.import_bridge or nil
    if not importBridge then
        pcall(function() importBridge = playerController:GetComponentByClass(UE.UAnimImportBridge) end)
        if importBridge then
            local ok, isValid = pcall(function() return UE.UKismetSystemLibrary.IsValid(importBridge) end)
            if not (ok and isValid) then importBridge = nil end
        end
    end

    _pc     = playerController
    _client = client
    _import = importBridge

    Library:Init()
    self:RehydrateRuntimeAssets()

    -- 注：UnLua 的 multicast delegate :Add 要求 self 必须是 UObject，Core 是 Lua table 不行。
    -- 当前 ImportLocalGLB 是同步实现，调用方拿到 uuid 立刻自己处理（见 ImportLocal 函数），
    -- 因此不订阅 OnAssetImported / OnAssetImportFailed。
    -- 后续 Fab 阶段如需异步事件，应让 PlayerController 作为接收 UObject 中转到 Lua。

    _initialized = true
    print(string.format("[AnimAgentCore] 初始化完成（runtime-package 模式，import_bridge=%s）",
        importBridge and "yes" or "no"))
    return true
end

function Core:Shutdown()
    if not _initialized then return end
    _client, _pc, _import = nil, nil, nil
    _initialized = false
end

function Core:IsReady()
    return _initialized and _client ~= nil
end

--============================================================
-- 公共 API
--============================================================

--- 从本地文件导入为 UGC runtime package（同步流程：构建 package → 写库 → 注册 → 预加载）
--- @param filePath string  绝对路径
--- @param desiredName? string
--- @return string package_id（失败返回 ""）
function Core:ImportLocal(filePath, desiredName)
    return self:ImportPackageFromFile(filePath, desiredName or "", "local", nil)
end

function Core:ImportPackageFromFile(filePath, desiredName, provider, extra)
    if not self:IsReady() then
        print("[AnimAgentCore] ImportPackageFromFile 失败：未初始化")
        return ""
    end
    if not filePath or filePath == "" then return "" end

    local packageID = _client:ImportLocalUGCPackage(filePath, desiredName or "", provider or "local")
    if not packageID or packageID == "" then return "" end

    self:_processRuntimePackage(packageID, _manifestPath(packageID), desiredName or "", provider or "local", extra)
    return packageID
end

--- 导出到本地路径
function Core:ExportLocal(uuid, targetPath)
    if not self:IsReady() or not uuid or uuid == "" then return false end
    return _client:ExportLocalGLB(uuid, targetPath or "")
end

--- 列出已导入资产（按时间倒序）
function Core:ListAssets()
    return Library:GetAll()
end

--- 删除资产（仅 Library / Registry 元数据；不删 Saved 目录文件）
function Core:RemoveAsset(uuid)
    if not uuid or uuid == "" then return false end
    Registry:RemovePrefab("pkg:" .. uuid .. ":main")
    Registry:RemovePrefab("dyn:" .. uuid)
    return Library:Remove(uuid)
end

--============================================================
-- 内部：导入完成后的统一处理
--============================================================

function Core:_processRuntimePackage(packageID, manifestPath, desiredName, provider, extra)
    local manifest = _readManifest(manifestPath) or {}
    local name = desiredName ~= "" and desiredName or (manifest.name or packageID)
    local sourceNote = manifest.original_name or manifest.original_path or ""
    local assetID = manifest.asset_id or "main"
    local packageDir = manifestPath:gsub("[/\\]manifest%.json$", "")
    local sourcePath = ""
    if manifest.model and manifest.model ~= "" then
        sourcePath = packageDir .. "/" .. tostring(manifest.model):gsub("\\", "/")
    end
    extra = extra or {}

    -- ② 写入资产库
    Library:Add({
        uuid          = packageID, -- 兼容旧调用方
        package_id    = packageID,
        asset_id      = assetID,
        name          = name,
        prompt        = extra.description or sourceNote,
        provider      = provider or manifest.provider or "local",
        manifest_path = manifestPath,
        model_path    = manifest.model or "",
        source_path   = sourcePath,
        thumbnail_path= manifest.thumbnail or "",
        prefab_id     = "pkg:" .. packageID .. ":" .. assetID,
        fab_id        = extra.fab_id,
        tags          = extra.tags or {},
        created_at    = tonumber(manifest.created_at) or os.time(),
    })

    -- ③ 注册到 UGCPrefabRegistry（出现在 UGC 编辑器的"UGC 资产"分类下）
    Registry:RegisterRuntimeAsset({
        package_id    = packageID,
        asset_id      = assetID,
        name          = name,
        manifest_path = manifestPath,
        provider      = provider or manifest.provider or "local",
        prompt        = extra.description or sourceNote,
        thumbnail_path= manifest.thumbnail or "",
    })

    -- ④ 让 ImportBridge 预加载 runtime asset（首次放置时无 IO 卡顿）
    if _import then
        pcall(function() _import:ImportRuntimeAssetAsync(packageID, manifestPath) end)
    end

    print(string.format("[AnimAgentCore] Runtime package 已就绪 package=%s name=%s", packageID, name))
end

function Core:RehydrateRuntimeAssets()
    local list = Library:GetAll()
    for _, item in ipairs(list or {}) do
        local packageID = item.package_id or item.uuid
        local manifestPath = item.manifest_path
        if packageID and packageID ~= "" and manifestPath and manifestPath ~= "" then
            Registry:RegisterRuntimeAsset({
                package_id    = packageID,
                asset_id      = item.asset_id or "main",
                name          = item.name or packageID,
                manifest_path = manifestPath,
                provider      = item.provider or "local",
                prompt        = item.prompt or "",
                thumbnail_path= item.thumbnail_path or "",
            })
        elseif item.glb_path and item.glb_path ~= "" then
            Registry:RegisterDynamicGLB({
                uuid     = item.uuid,
                name     = item.name,
                glb_path = item.glb_path,
                provider = item.provider or "legacy",
                prompt   = item.prompt or "",
            })
        end
    end
end

return Core
