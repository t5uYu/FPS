--[[
    UGCPrefabRegistry.lua
    预制体注册表 — 打包 Catalog + Editor-only 资产发现

    运行时只信任 UGCPlaceableConfig.lua 中审核过的显式资产路径；Editor PIE
    可扫描 Content/_UGC/Placeables 以发现开发中的新资产。玩家提供任意
    BlueprintClass 路径的入口已禁用，后续应由带哈希和校验的内容 Provider 取代。
]]

-- JSON 工具：使用统一的 json.lua 模块
local PackagedCatalog = require("Gameplay.UGC.UGCPlaceableConfig")
local UGCLog = require("Gameplay.UGC.UGCLog")

local Registry = {}

Registry.Prefabs    = {}
Registry.Categories = {}
Registry.Meta       = {}   -- id → { description, tags, label, category }
Registry._dynamic   = {}   -- 仅玩家自定义条目，用于序列化

local PLACEABLE_BASE = "/Game/_UGC/Placeables/"

local function assetNameToClassPath(assetName)
    return PLACEABLE_BASE .. assetName .. "." .. assetName .. "_C"
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
        Registry.Prefabs[e.id] = assert(e.path, "prefab catalog entry requires path")
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

--============================================================
-- LoadDynamic：三步合并
--============================================================

--- @param bridge UUGCEditorBridge  用于扫描文件系统
function Registry:LoadDynamic(bridge)
    local entries = {}   -- 最终合并结果（有序）
    local seen    = {}   -- 去重

    -- ⓪ Packaged catalog: runtime-safe source of truth for shipped assets.
    for _, item in ipairs(PackagedCatalog) do
        local path = normalizeBlueprintClassPath(item.path or item.blueprintPath)
        if item.id and path and not seen[item.id] then
            seen[item.id] = true
            entries[#entries + 1] = {
                id=item.id, label=item.label, category=item.category,
                description=item.description, tags=item.tags, path=path,
            }
        end
    end

    -- ① Editor-only discovery of newly authored assets.
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
        UGCLog.Info("prefab_scan", { discovered = #entries })
    end

    -- Player-supplied Blueprint paths remain disabled until a dedicated
    -- importer/provider performs content hashing and asset validation.
    Registry._dynamic = {}

    buildRegistry(entries)
    UGCLog.Info("prefab_registry_ready", { total = #entries })
end

--============================================================
-- 持久化（只保存玩家自定义）
--============================================================

function Registry:SaveDynamic()
    return false
end

--============================================================
-- 公共查询
--============================================================

function Registry.GetPath(id)  return Registry.Prefabs[id] end
function Registry.IsValid(id)  return Registry.Prefabs[id] ~= nil end
function Registry.ListIDs()
    local ids = {}
    for id in pairs(Registry.Prefabs) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
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

function Registry:AddCustomPrefab(_)
    UGCLog.Warn("custom_prefab_disabled", { hint = "玩家 Blueprint 路径导入已禁用，请使用受验证的内容 Provider" })
    return false
end

function Registry:RemovePrefab(_)
    return false
end

return Registry
