--[[
    UGCPrefabRegistry.lua
    预制体注册表 — 自动扫描 + 元数据覆盖 + 玩家自定义

    数据来源（按顺序合并）：
      ① bridge:FindFilesInDirectory()  扫描 Content/_UGC/Placeables/*.uasset
           → 自动发现所有 BP_Placeable_Xxx / BA_Placeable_Xxx 蓝图（PIE/Development 可用）
      ② Content/_UGC/Placeables/placeable_manifest.json
           → 为已扫描到的资产补充 label / category / path（可选）
           → 只有显式提供 path / blueprintPath 时，才允许补充“未扫描到”的条目
      ③ Saved/UGC/custom_prefabs.json
           → 玩家运行时添加的自定义预制体

    新增预制体（开发者）：
      只需在 _UGC/Placeables/ 里建 BP_Placeable_Xxx / BA_Placeable_Xxx，下次 PIE 自动出现。
      想自定义显示名/分类：在 placeable_manifest.json 加一行即可。
      如果资源名不遵循默认命名规则，可在 manifest 里显式填写 path。

    新增预制体（玩家/运行时）：
      Registry:AddCustomPrefab({ id, label, category, blueprintPath })
]]

-- JSON 工具：使用统一的 json.lua 模块
local json = require("Gameplay.UGC.json")

local Registry = {}

Registry.Prefabs    = {}
Registry.Categories = {}
Registry.Meta       = {}   -- id → { description, tags, label, category }
Registry._dynamic   = {}   -- 仅玩家自定义条目，用于序列化

-- AnimAgent 动态 glb 资产
-- key: "dyn:{uuid}", value: { uuid, name, glb_path, provider, prompt }
-- 与传统 Blueprint 预制体并列，spawn 时走 UAnimImportBridge 而非 SpawnActor
Registry.DynamicGLB = {}
local DYN_PREFIX = "dyn:"

-- UGC runtime package 资产
-- key: "pkg:{package_id}:{asset_id}", value: { package_id, asset_id, manifest_path, name, provider, prompt }
Registry.RuntimeAssets = {}
local PKG_PREFIX = "pkg:"

local PLACEABLE_BASE = "/Game/_UGC/Placeables/"

local function assetNameToClassPath(assetName)
    return PLACEABLE_BASE .. assetName .. "." .. assetName .. "_C"
end

-- blueprintPath 命名规则：从 id 自动推导
local function idToPath(id)
    return assetNameToClassPath("BP_Placeable_" .. id)
end

local function normalizeBlueprintClassPath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    if path:match("_C$") then
        return path
    end

    local assetName = path:match("([^/%.]+)$")
    if not assetName then
        return path
    end

    if path:find(".", 1, true) then
        return path .. "_C"
    end

    return path .. "." .. assetName .. "_C"
end

local function makeScannedEntry(assetName)
    local prefix, id = assetName:match("^(BP_Placeable_)(.+)$")
    if not id then
        prefix, id = assetName:match("^(BA_Placeable_)(.+)$")
    end
    if not id then
        return nil
    end

    return {
        id       = id,
        label    = id,
        category = "方块",
        path     = assetNameToClassPath(prefix .. id),
        _scanned = true,
    }
end

--============================================================
-- 重建 Prefabs + Categories（从条目列表）
--============================================================

local function buildRegistry(entries)
    Registry.Prefabs    = {}
    Registry.Categories = {}
    Registry.Meta       = {}

    local catMap   = {}
    local catOrder = {}

    for _, e in ipairs(entries) do
        Registry.Prefabs[e.id] = e.path or idToPath(e.id)
        Registry.Meta[e.id] = {
            label       = e.label or e.id,
            category    = e.category or "方块",
            description = e.description,
            tags        = e.tags,
        }

        local cat = e.category or "方块"
        if not catMap[cat] then
            catMap[cat] = {}
            catOrder[#catOrder+1] = cat
        end
        catMap[cat][#catMap[cat]+1] = { id=e.id, label=e.label or e.id }
    end

    for _, catName in ipairs(catOrder) do
        Registry.Categories[#Registry.Categories+1] = { name=catName, items=catMap[catName] }
    end
end

--============================================================
-- 文件路径工具
--============================================================

local function getContentDir()
    return UE.UKismetSystemLibrary.GetProjectDirectory() .. "Content/"
end

local function getSavedDir()
    return UE.UKismetSystemLibrary.GetProjectDirectory() .. "Saved/UGC/"
end

local function ensureSavedDir()
    pcall(function() UE.UKismetSystemLibrary.MakeDirectory(getSavedDir()) end)
end

--============================================================
-- LoadDynamic：三步合并
--============================================================

--- @param bridge UUGCEditorBridge  用于扫描文件系统
function Registry:LoadDynamic(bridge)
    local entries = {}   -- 最终合并结果（有序）
    local seen    = {}   -- 去重

    -- ① 扫描 _UGC/Placeables/*.uasset
    if bridge then
        local dir   = getContentDir() .. "_UGC/Placeables/"
        local files = bridge:FindFilesInDirectory(dir, "*.uasset")
        for i = 1, files:Num() do
            local name = files[i]:match("([^/\\]+)%.uasset$")
            if name then
                local entry = makeScannedEntry(name)
                if entry and not seen[entry.id] then
                    seen[entry.id] = true
                    entries[#entries+1] = entry
                end
            end
        end
        print(string.format("[UGCPrefabRegistry] 扫描到 %d 个预制体", #entries))
    end

    -- ② 读 placeable_manifest.json 补充 label / category / path
    local manifestPath = getContentDir() .. "_UGC/Placeables/placeable_manifest.json"
    local mf = io.open(manifestPath, "r")
    if mf then
        local arr = json.decode(mf:read("*a")) or {}
        mf:close()
        local meta = {}
        for _, item in ipairs(arr) do
            if item.id then meta[item.id] = item end
        end

        for _, e in ipairs(entries) do
            local item = meta[e.id]
            if item then
                e.label       = item.label       or e.label
                e.category    = item.category    or e.category
                e.description = item.description or e.description
                e.tags        = item.tags        or e.tags
                e.path        = normalizeBlueprintClassPath(item.blueprintPath or item.path) or e.path
                meta[e.id] = nil
            end
        end

        local manifestOnlyCount = 0
        local skippedCount = 0
        for id, item in pairs(meta) do
            if not seen[id] then
                local explicitPath = normalizeBlueprintClassPath(item.blueprintPath or item.path)
                if explicitPath then
                    seen[id] = true
                    entries[#entries+1] = {
                        id          = id,
                        label       = item.label or id,
                        category    = item.category or "方块",
                        description = item.description,
                        tags        = item.tags,
                        path        = explicitPath,
                    }
                    manifestOnlyCount = manifestOnlyCount + 1
                else
                    skippedCount = skippedCount + 1
                end
            end
        end

        if manifestOnlyCount > 0 then
            print(string.format("[UGCPrefabRegistry] Manifest 补充 %d 个显式路径预制体", manifestOnlyCount))
        end
        if skippedCount > 0 then
            print(string.format("[UGCPrefabRegistry] Manifest 中 %d 个未落地资源已跳过（缺少扫描结果且未提供 path）", skippedCount))
        end
    end

    -- ③ 加载玩家自定义 JSON
    Registry._dynamic = {}
    local customPath = getSavedDir() .. "custom_prefabs.json"
    local cf = io.open(customPath, "r")
    if not cf then
        ensureSavedDir()
        local fw = io.open(customPath, "w")
        if fw then fw:write("[]"); fw:close() end
    else
        local arr = json.decode(cf:read("*a")) or {}
        cf:close()
        for _, e in ipairs(arr) do
            local dynamicPath = normalizeBlueprintClassPath(e.blueprintPath or e.path)
            if e.id and dynamicPath and not seen[e.id] then
                seen[e.id] = true
                Registry._dynamic[#Registry._dynamic+1] = {
                    id           = e.id,
                    label        = e.label,
                    category     = e.category,
                    blueprintPath= dynamicPath,
                }
                entries[#entries+1] = {
                    id       = e.id,
                    label    = e.label    or e.id,
                    category = e.category or "玩家自定义",
                    path     = dynamicPath,
                }
            end
        end
        print(string.format("[UGCPrefabRegistry] 加载 %d 个自定义预制体", #Registry._dynamic))
    end

    buildRegistry(entries)
    print(string.format("[UGCPrefabRegistry] 就绪，共 %d 个预制体", #entries))
end

--============================================================
-- 持久化（只保存玩家自定义）
--============================================================

function Registry:SaveDynamic()
    ensureSavedDir()
    local path = getSavedDir() .. "custom_prefabs.json"
    local f    = io.open(path, "w")
    if f then
        f:write(json.encode(Registry._dynamic, "  "))
        f:close()
    end
end

--============================================================
-- 公共查询
--============================================================

function Registry.GetPath(id)  return Registry.Prefabs[id] end
function Registry.IsValid(id)
    return Registry.Prefabs[id] ~= nil or Registry.DynamicGLB[id] ~= nil or Registry.RuntimeAssets[id] ~= nil
end

--- 判定预制体类型："blueprint" | "dynamic_glb" | "runtime_asset" | nil
function Registry.GetKind(id)
    if Registry.RuntimeAssets[id] then return "runtime_asset" end
    if Registry.DynamicGLB[id] then return "dynamic_glb" end
    if Registry.Prefabs[id] then return "blueprint" end
    return nil
end

--- 取动态 glb 资产数据（含 glb_path）
function Registry.GetDynamicGLB(id)
    return Registry.DynamicGLB[id]
end

--- 取 UGC runtime package 资产数据（含 manifest_path）
function Registry.GetRuntimeAsset(id)
    return Registry.RuntimeAssets[id]
end

--- 获取预制体元数据（description, tags, label, category）
function Registry.GetMeta(id)  return Registry.Meta[id] end

--- 为 LLM Schema 生成语义描述（包含所有预制体的 description 和 tags）
--- 格式：Box — 基础掩体方块(掩体,墙壁,地板); SpawnPoint — 玩家出生位置(出生,玩家,必需); ...
function Registry:GetSemanticDesc()
    local parts = {}
    for id, meta in pairs(Registry.Meta) do
        local desc = meta.description or meta.label or id
        local tagStr = ""
        if meta.tags and #meta.tags > 0 then
            tagStr = " (" .. table.concat(meta.tags, ",") .. ")"
        end
        table.insert(parts, id .. " — " .. desc .. tagStr)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

--============================================================
-- 运行时添加自定义预制体（玩家上传）
--============================================================

function Registry:AddCustomPrefab(def)
    assert(def.id and def.blueprintPath, "AddCustomPrefab: 缺少 id 或 blueprintPath")
    if Registry.Prefabs[def.id] then
        print("[UGCPrefabRegistry] id=" .. def.id .. " 已存在")
        return false
    end

    local normalizedPath = normalizeBlueprintClassPath(def.blueprintPath)
    local entry = {
        id            = def.id,
        label         = def.label        or def.id,
        category      = def.category     or "玩家自定义",
        blueprintPath = normalizedPath,
    }
    Registry._dynamic[#Registry._dynamic+1] = entry
    Registry.Prefabs[entry.id] = normalizedPath

    -- 追加到 Categories
    local catName = entry.category
    for _, cat in ipairs(Registry.Categories) do
        if cat.name == catName then
            cat.items[#cat.items+1] = { id=entry.id, label=entry.label }
            self:SaveDynamic()
            return true
        end
    end

    Registry.Categories[#Registry.Categories+1] = {
        name  = catName,
        items = { { id=entry.id, label=entry.label } },
    }
    self:SaveDynamic()
    print("[UGCPrefabRegistry] 已添加: " .. entry.id)
    return true
end

function Registry:RemovePrefab(id)
    -- Runtime package 动态资产：直接从 RuntimeAssets 移除
    if Registry.RuntimeAssets[id] then
        Registry.RuntimeAssets[id] = nil
        Registry.Prefabs[id] = nil
        return true
    end

    -- 动态 glb：直接从 DynamicGLB 移除
    if Registry.DynamicGLB[id] then
        Registry.DynamicGLB[id] = nil
        return true
    end

    for i, e in ipairs(Registry._dynamic) do
        if e.id == id then
            table.remove(Registry._dynamic, i)
            Registry.Prefabs[id] = nil
            self:SaveDynamic()
            return true
        end
    end
    print("[UGCPrefabRegistry] 不可删除（非自定义）: " .. id)
    return false
end

--============================================================
-- AnimAgent 动态 glb 资产注册
--============================================================

--- 注册一个 UGC runtime package 资产
--- @param def { package_id, asset_id?, manifest_path, name?, provider?, prompt?, label?, category? }
--- @return string id（"pkg:{package_id}:{asset_id}"）或 nil
function Registry:RegisterRuntimeAsset(def)
    if not def or not def.package_id or not def.manifest_path then
        print("[UGCPrefabRegistry] RegisterRuntimeAsset 失败：缺少 package_id 或 manifest_path")
        return nil
    end

    local assetID = def.asset_id or "main"
    local id = PKG_PREFIX .. def.package_id .. ":" .. assetID
    Registry.RuntimeAssets[id] = {
        package_id    = def.package_id,
        asset_id      = assetID,
        name          = def.name or def.package_id,
        manifest_path = def.manifest_path,
        provider      = def.provider or "unknown",
        prompt        = def.prompt or "",
        thumbnail_path= def.thumbnail_path or "",
    }

    Registry.Prefabs[id] = "/Script/FPS.AnimAgentDynamicPlaceable"
    Registry.Meta[id] = {
        label    = def.label or def.name or def.package_id,
        category = def.category or "UGC 资产",
    }

    local catName = Registry.Meta[id].category
    for _, cat in ipairs(Registry.Categories) do
        if cat.name == catName then
            for _, item in ipairs(cat.items or {}) do
                if item.id == id then
                    item.label = Registry.Meta[id].label
                    return id
                end
            end
            cat.items[#cat.items+1] = { id = id, label = Registry.Meta[id].label }
            return id
        end
    end

    Registry.Categories[#Registry.Categories+1] = {
        name  = catName,
        items = { { id = id, label = Registry.Meta[id].label } },
    }
    return id
end

--- 注册一个由 AnimAgent 生成 / 导入的动态资产
--- @param def { uuid, name, glb_path, provider?, prompt?, label?, category? }
--- @return string id（"dyn:{uuid}"）或 nil
function Registry:RegisterDynamicGLB(def)
    if not def or not def.uuid or not def.glb_path then
        print("[UGCPrefabRegistry] RegisterDynamicGLB 失败：缺少 uuid 或 glb_path")
        return nil
    end

    local id = DYN_PREFIX .. def.uuid
    Registry.DynamicGLB[id] = {
        uuid     = def.uuid,
        name     = def.name or def.uuid,
        glb_path = def.glb_path,
        provider = def.provider or "unknown",
        prompt   = def.prompt or "",
    }

    -- 所有 dyn 资产都用同一个 native host 类。SpawnPlaceable 内部 LoadClass 支持 native 类路径。
    -- spawn 后由 UGCEditorCore 立即调 SetDynMesh 注入实际的 UStaticMesh。
    Registry.Prefabs[id] = "/Script/FPS.AnimAgentDynamicPlaceable"
    Registry.Meta[id] = {
        label    = def.label or def.name or def.uuid,
        category = def.category or "AI 生成",
    }

    local catName = Registry.Meta[id].category
    for _, cat in ipairs(Registry.Categories) do
        if cat.name == catName then
            cat.items[#cat.items+1] = { id = id, label = Registry.Meta[id].label }
            return id
        end
    end
    Registry.Categories[#Registry.Categories+1] = {
        name  = catName,
        items = { { id = id, label = Registry.Meta[id].label } },
    }
    return id
end

--- 列出所有 UGC runtime package 动态资产
function Registry:ListRuntimeAssets()
    local list = {}
    for id, v in pairs(Registry.RuntimeAssets) do
        table.insert(list, { id = id, data = v })
    end
    return list
end

--- 列出所有 AnimAgent 动态资产
function Registry:ListDynamicGLB()
    local list = {}
    for id, v in pairs(Registry.DynamicGLB) do
        table.insert(list, { id = id, data = v })
    end
    return list
end

return Registry
