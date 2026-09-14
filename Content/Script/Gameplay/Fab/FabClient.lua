--[[
    FabClient.lua
    Fab 客户端（路线 B：UMG 登录 + 内嵌 WebBrowser）Lua 侧薄壳

    定位：
    - C++ 层：
        * UFabClientBridge     → 鉴权 + 下载（2 条主要能力）
        * UFabUrlDispatcher    → 拦截 uefab:// scheme 并派发到 Bridge
      承接全部 HTTP 异步逻辑；UnLua 对 dynamic delegate / multicast delegate 的限制让
      "把异步回调写在 Lua 里" 并不划算。
    - 本文件只做三件事：
        1) 在 PlayerController 上定位 Bridge 并缓存
        2) 暴露同步状态查询（IsLoggedIn / GetUser / GetBridge 等）
        3) 给下载成功的资产做"落库 + 注册 + 预加载"的统一收口 RegisterDownloadedAsset
           （FabUrlDispatcher 或蓝图完成下载后都应调用这个）

    真正的异步调用（Login / DownloadAsset）建议从 UMG Blueprint 直接调 Bridge 的
    UFUNCTION：
        Bridge:Login(acc, pwd, Event OnLoginDone)
    其中 OnLoginDone 是 BP 里用 "Add Custom Event" 自动生成的匹配签名节点。

    用法：
        local FabClient = require("Gameplay.Fab.FabClient")
        FabClient:Init(playerController)
        if FabClient:IsLoggedIn() then
            print("当前用户：" .. FabClient:GetUser().user_account)
        end
]]

local Library  = require("Gameplay.AnimAgent.AnimAssetLibrary")
local Registry = require("Gameplay.UGC.UGCPrefabRegistry")

local FabClient = {}

local _pc      = nil
local _bridge  = nil     -- UFabClientBridge*
local _import  = nil     -- UAnimImportBridge*（可选，用于 mesh 预加载）
local _initialized = false

local function _tryGetComp(pc, cls)
    if not pc or not cls then return nil end
    local comp = nil
    pcall(function() comp = pc:GetComponentByClass(cls) end)
    if not comp then return nil end
    local ok, valid = pcall(function() return UE.UKismetSystemLibrary.IsValid(comp) end)
    return (ok and valid) and comp or nil
end

--============================================================
-- 初始化
--============================================================

--- @param playerController APlayerController*
--- @return boolean
function FabClient:Init(playerController)
    if _initialized then return true end
    if not playerController then
        print("[FabClient] Init 失败：playerController 为 nil")
        return false
    end

    _bridge = _tryGetComp(playerController, UE.UFabClientBridge)
    if not _bridge then
        print("[FabClient] Init 失败：PlayerController 上没找到 UFabClientBridge 组件")
        print("[FabClient]   → 请在 PC 蓝图 Add Component 加 FabClientBridge")
        return false
    end

    _import = _tryGetComp(playerController, UE.UAnimImportBridge) -- 可选

    _pc = playerController
    Library:Init()
    _initialized = true

    print(string.format(
        "[FabClient] 初始化完成（bridge=%s, import=%s, logged_in=%s）",
        _bridge and "yes" or "no",
        _import and "yes" or "no",
        self:IsLoggedIn() and "yes" or "no"))
    return true
end

function FabClient:Shutdown()
    _pc, _bridge, _import = nil, nil, nil
    _initialized = false
end

function FabClient:IsReady()
    return _initialized and _bridge ~= nil
end

--============================================================
-- 同步状态查询
--============================================================

function FabClient:GetBridge()
    return _bridge
end

function FabClient:GetImportBridge()
    return _import
end

function FabClient:IsLoggedIn()
    if not _bridge then return false end
    local ok, result = pcall(function() return _bridge:IsLoggedIn() end)
    return ok and result or false
end

--- 返回 plain table 形式的当前用户，未登录时字段全是默认值
function FabClient:GetUser()
    if not _bridge then return {} end
    local u = _bridge:GetCurrentUser()
    return {
        id           = u and u.Id or 0,
        user_account = u and u.UserAccount or "",
        user_name    = u and u.UserName or "",
        is_admin     = u and (u.UserRole == UE.EFabUserRole.Admin) or false,
        ai_quota     = u and u.AiQuota or 0,
        ai_used      = u and u.AiUsed or 0,
    }
end

function FabClient:Logout()
    if not _bridge then return end
    _bridge:Logout()
end

--- 返回当前 access_token（给 WBP_FabPanel 注入 CEF cookie 用）
--- 未登录时返回 ""
function FabClient:GetAccessToken()
    if not _bridge then return "" end
    local ok, t = pcall(function() return _bridge:GetAccessToken() end)
    return (ok and t) or ""
end

function FabClient:GetRefreshToken()
    if not _bridge then return "" end
    local ok, t = pcall(function() return _bridge:GetRefreshToken() end)
    return (ok and t) or ""
end

--- 返回本地资产库中已经关联过的 Fab 资产 ID。
--- 给 WBP_FabPanel 注入 Web localStorage，用于详情页显示“已在 Project 中”。
function FabClient:GetDownloadedFabIds()
    Library:Init()
    local ids = {}
    local seen = {}
    local list = Library:GetAll()
    for _, item in ipairs(list or {}) do
        local id = item and item.fab_id
        if id and id ~= "" and not seen[tostring(id)] then
            table.insert(ids, id)
            seen[tostring(id)] = true
        end
    end
    return ids
end

--============================================================
-- 下载成功后统一入库
--============================================================

--- 把一条 Fab 下载结果接入到本地资产管线。
--- 调用方一般是 WBP_FabPanel 的蓝图（在拿到 UFabUrlDispatcher/Bridge 下载完成事件后）。
---
--- @param downloadResult table  FFabDownloadResult struct 的 Lua 镜像，字段: AssetId / LocalFilePath / LocalUuid / SizeBytes
--- @param meta table|nil        { name, description, tags, source } 选填；缺失字段用 fab:{asset_id} 兜底
--- @return string uuid  成功返回本地 uuid；失败返回 ""
function FabClient:RegisterDownloadedAsset(downloadResult, meta)
    if not self:IsReady() then
        print("[FabClient] RegisterDownloadedAsset 失败：未初始化")
        return ""
    end
    if not downloadResult or not downloadResult.LocalFilePath or downloadResult.LocalFilePath == "" then
        print("[FabClient] RegisterDownloadedAsset 失败：downloadResult 无效")
        return ""
    end

    local uuid    = downloadResult.LocalUuid or ""
    local glbPath = downloadResult.LocalFilePath
    if uuid == "" then
        uuid = glbPath:match("assets[/\\]([^/\\]+)[/\\]source") or tostring(downloadResult.AssetId or "unknown")
    end

    meta = meta or {}
    local name = meta.name or ("Fab#" .. tostring(downloadResult.AssetId or uuid))

    Library:Add({
        uuid       = uuid,
        name       = name,
        prompt     = meta.description or "",
        provider   = meta.source or "fab",
        glb_path   = glbPath,
        fab_id     = downloadResult.AssetId,
        tags       = meta.tags or {},
        created_at = os.time(),
    })

    Registry:RegisterDynamicGLB({
        uuid     = uuid,
        name     = name,
        glb_path = glbPath,
        provider = "fab",
        prompt   = meta.description or "",
    })

    if _import then
        pcall(function() _import:ImportGLBAsync(uuid, glbPath) end)
    end

    print(string.format("[FabClient] 资产入库 uuid=%s name=%s path=%s",
        uuid, name, glbPath))
    return uuid
end

return FabClient
