--[[
    UGCPrefabRegistry.lua
    预制体注册表 — Definition 优先 + 三级兜底

    T5 起预制体的**唯一主来源**是 AssetManager 里的 `UUGCPrefabDefinition`（PrimaryDataAsset，
    ID 形如 `UGCPrefab:Box`），它同时覆盖磁盘资产与运行时注册的动态资产（GLB / runtime package）。
    Lua 侧只用桥接层的 `GetPrefabDefinitionsJson()` 取一份扁平列表，不再自己维护权威 Catalog。

    兜底顺序（同 id 先到先得，并记录来源到 Registry.Sources）：
      ① definition  AssetManager 扫描到的 UUGCPrefabDefinition（含运行时 AddDynamicAsset 注册）
      ② catalog     UGCPlaceableConfig.lua —— 迁移期兜底，只为没有 Definition 的旧资产补齐
      ③ scan        Editor 下扫描 Content/_UGC/Placeables/*.uasset，并警告「缺 Definition」

    玩家提供任意 BlueprintClass 路径的入口仍然禁用。
]]

local PackagedCatalog = require("Gameplay.UGC.UGCPlaceableConfig")   -- T5：迁移期兜底，不是权威来源
local UGCLog = require("Gameplay.UGC.UGCLog")
local json = require("Util.json")

local Registry = {}

Registry.Prefabs    = {}
Registry.Categories = {}
Registry.Meta       = {}   -- id → { description, tags, label, category }
Registry.Sources    = {}   -- id → "definition" | "catalog" | "scan"（诊断用）
Registry._dynamic   = {}   -- 仅玩家自定义条目，用于序列化

local _bridge = nil        -- T5：LoadDynamic 时记住桥接层，运行时注册要用

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
-- T5：从 AssetManager（UUGCPrefabDefinition）取定义列表
--============================================================

local function definitionsFromBridge(bridge)
    if not bridge or not bridge.GetPrefabDefinitionsJson then return nil end
    local ok, raw = pcall(function() return bridge:GetPrefabDefinitionsJson() end)
    if not ok or type(raw) ~= "string" or raw == "" then
        UGCLog.Warn("prefab_definitions_unavailable", { reason = tostring(raw) })
        return nil
    end
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then
        UGCLog.Warn("prefab_definitions_unavailable", { reason = "decode failed" })
        return nil
    end
    return decoded
end

--============================================================
-- LoadDynamic：Definition → Catalog(迁移兜底) → Editor 扫描
--============================================================

--- @param bridge UUGCEditorBridge  取 Definition / 扫描文件系统
function Registry:LoadDynamic(bridge)
    _bridge = bridge
    local entries = {}   -- 最终合并结果（有序）
    local seen    = {}   -- 去重
    local counts  = { definition = 0, catalog = 0, scan = 0 }

    Registry.Sources = {}

    -- ⓪a 主来源：AssetManager 里的 UUGCPrefabDefinition（磁盘资产 + 运行时动态注册）
    local definitions = definitionsFromBridge(bridge)
    if definitions then
        for _, def in ipairs(definitions) do
            local path = normalizeBlueprintClassPath(def.classPath or def.path)
            if def.id and path and not seen[def.id] then
                seen[def.id] = true
                entries[#entries + 1] = {
                    id = def.id, label = def.label, category = def.category,
                    description = def.description, tags = def.tags, path = path,
                    version = def.version, cost = def.cost, bounds = def.bounds,
                    allowedModes = def.allowedModes, fromDefinition = def.source,
                }
                Registry.Sources[def.id] = "definition"
                counts.definition = counts.definition + 1
            end
        end
    end

    -- ⓪b 迁移期兜底：旧 Catalog 只为「还没有 Definition」的资产补齐
    for _, item in ipairs(PackagedCatalog) do
        local path = normalizeBlueprintClassPath(item.path or item.blueprintPath)
        if item.id and path and not seen[item.id] then
            seen[item.id] = true
            entries[#entries + 1] = {
                id=item.id, label=item.label, category=item.category,
                description=item.description, tags=item.tags, path=path,
            }
            Registry.Sources[item.id] = "catalog"
            counts.catalog = counts.catalog + 1
        end
    end

    -- ① Editor-only discovery：只为缺 Definition 的新资产兜底，并明确报警
    if bridge and bridge.FindFilesInDirectory then
        local dir   = getContentDir() .. "_UGC/Placeables/"
        local files = bridge:FindFilesInDirectory(dir, "*.uasset")
        local missingDefinition = 0
        for i = 1, files:Num() do
            local name = files[i]:match("([^/\\]+)%.uasset$")
            if name then
                local entry = makeScannedEntry(name)
                if entry and not seen[entry.id] then
                    seen[entry.id] = true
                    entries[#entries+1] = entry
                    Registry.Sources[entry.id] = "scan"
                    counts.scan = counts.scan + 1
                    missingDefinition = missingDefinition + 1
                end
            end
        end
        if missingDefinition > 0 then
            UGCLog.Warn("prefab_definition_missing", { count = missingDefinition, dir = "_UGC/Placeables" })
        end
    end

    -- Player-supplied Blueprint paths remain disabled until a dedicated
    -- importer/provider performs content hashing and asset validation.
    Registry._dynamic = {}

    buildRegistry(entries)
    UGCLog.Info("prefab_registry_ready", {
        total = #entries, definitions = counts.definition,
        catalogFallback = counts.catalog, scanned = counts.scan,
    })
end

--- 条目来源（诊断/回归用）："definition" | "catalog" | "scan" | nil
function Registry.GetSource(id)
    return Registry.Sources[id]
end

--- 各来源条目数
function Registry.CountBySource()
    local counts = { definition = 0, catalog = 0, scan = 0 }
    for _, source in pairs(Registry.Sources) do
        if counts[source] ~= nil then counts[source] = counts[source] + 1 end
    end
    return counts
end

--- T5：把运行时动态资产也登记进 AssetManager 的 PrimaryAssetId 空间。
--- 身份与元数据（id/类路径/label/category/tags）进 Definition；spawn 需要的运行期载荷
--- （uuid / glb_path / manifest_path / provider / prompt）留在 Lua 侧，它不是资产元数据。
local function pushRuntimeDefinition(kind, id, classPath, meta)
    if not _bridge or not _bridge.RegisterRuntimePrefabDefinition then return false end
    local ok, registered = pcall(function()
        return _bridge:RegisterRuntimePrefabDefinition(kind, id, classPath,
            meta.label or id, meta.category or "", meta.description or "", meta.tags or {})
    end)
    if not ok or registered ~= true then
        UGCLog.Warn("prefab_definition_register_failed", { prefab = tostring(id), kind = tostring(kind) })
        return false
    end
    Registry.Sources[id] = "definition"
    return true
end

Registry.DefinitionKind = {
    blueprint     = "blueprint",
    runtime_asset = "runtime_asset",
    dynamic_glb   = "dynamic_glb",
}

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

--- 全部预制体 id（排序）。
--- 注意：UGCFunctionRegistry 的 place_object 用它做 enum 白名单，
--- 缺了它 RegisterAll 会在运行时整体抛异常（2026-09-15 PIE 实测踩到过：函数在 05a55fe 重构时被删掉）。
function Registry.ListIDs()
    local ids = {}
    for id in pairs(Registry.Prefabs) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
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

function Registry:AddCustomPrefab(_)
    UGCLog.Warn("custom_prefab_disabled", { hint = "玩家 Blueprint 路径导入已禁用，请使用受验证的内容 Provider" })
    return false
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
    UGCLog.Warn("prefab_not_removable", { prefab = tostring(id) })
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
        UGCLog.Warn("prefab_register_failed", { context = "RegisterRuntimeAsset", reason = "missing package_id or manifest_path" })
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
    -- T5：身份与元数据同时登记进 AssetManager 的 PrimaryAssetId 空间
    pushRuntimeDefinition(Registry.DefinitionKind.runtime_asset, id, Registry.Prefabs[id], Registry.Meta[id])

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
        UGCLog.Warn("prefab_register_failed", { context = "RegisterDynamicGLB", reason = "missing uuid or glb_path" })
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
    -- T5：身份与元数据同时登记进 AssetManager 的 PrimaryAssetId 空间
    pushRuntimeDefinition(Registry.DefinitionKind.dynamic_glb, id, Registry.Prefabs[id], Registry.Meta[id])

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
