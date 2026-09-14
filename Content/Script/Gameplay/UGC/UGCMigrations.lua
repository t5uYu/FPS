--[[
    UGCMigrations.lua

    T15：显式迁移链 V1 → V2 → V3。

    设计约束：
      * 每一步只负责「i → i+1」，是纯函数：入参已是深拷贝，返回值即下一版快照。
      * Migrate 永不修改入参（失败时原快照原封不动），因此「迁移失败不损坏原文件」有结构保证。
      * 当前版本（CURRENT = 3）的快照不做任何补齐，只返回等值副本 —— 已是最新格式的存档
        必须逐字节不变，否则 golden 回归会立刻飘。
      * 未知/越界版本直接拒绝，不做猜测式迁移。

    V1 → V2（标识与分配器）：
      v1 来自旧 scene.json 时代的字段（id / prefab / t），没有 entityId / actorId / programId，
      也没有 nextSceneID。这一步把字段收敛到 v2 命名并补齐标识与自增游标。

    V2 → V3（容器与类型）：
      v3 引入 tags / properties / metadata、header.contentVersion、generatedGroups / worldSettings
      容器与布尔 external。这一步补齐容器、把组内成员的 sceneID 归一化成 number，
      并丢弃悬空引用（否则 ValidateSnapshot 会因「组引用了不存在的 sceneID」整份拒绝加载）。
]]

local Migrations = {}

Migrations.CURRENT = 3

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for k, v in pairs(value) do
        result[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return result
end

local DEFAULT_TRANSFORM = { 0, 0, 0, 0, 0, 0, 1, 1, 1 }

--- 旧存档里的布尔标志可能是 true / 1 / "1"，统一收敛成布尔
local function flag(value)
    if value == true then return true end
    return tonumber(value) == 1
end

local function normalizeTransform(value)
    if type(value) ~= "table" or #value ~= 9 then return deepCopy(DEFAULT_TRANSFORM) end
    local result = {}
    for index = 1, 9 do result[index] = tonumber(value[index]) or DEFAULT_TRANSFORM[index] end
    return result
end

--- 每一步：function(snapshot) -> snapshot, notes(table|nil)
Migrations.Steps = {
    [1] = function(snapshot)
        local header = snapshot.header or {}
        snapshot.header = header
        if header.documentId == nil or tostring(header.documentId) == "" then
            header.documentId = "ugc-migrated-doc"
        end
        header.documentId = tostring(header.documentId)
        header.schemaVersion = 2

        snapshot.entities = snapshot.entities or {}
        local maxSceneID = 0
        for _, record in ipairs(snapshot.entities) do
            local sceneID = tonumber(record.sceneID or record.id) or 0
            record.sceneID = sceneID
            record.id = nil
            if sceneID > maxSceneID then maxSceneID = sceneID end

            record.prefabName = record.prefabName or record.prefab or "Unknown"
            record.prefab = nil
            record.transform = normalizeTransform(record.transform or record.t)
            record.t = nil

            record.entityId = tostring(record.entityId or (header.documentId .. "-entity-" .. sceneID))
            record.actorId = record.actorId or ("actor_" .. sceneID)
            record.programId = record.programId or ("actor_prog_" .. sceneID)
            record.external = flag(record.external)
        end

        if tonumber(snapshot.nextSceneID) == nil then snapshot.nextSceneID = maxSceneID + 1 end
        return snapshot, {}
    end,

    [2] = function(snapshot)
        local header = snapshot.header or {}
        snapshot.header = header
        header.schemaVersion = 3
        header.contentVersion = tostring(header.contentVersion or "1")

        snapshot.entities = snapshot.entities or {}
        local known = {}
        for _, record in ipairs(snapshot.entities) do
            record.tags = record.tags or {}
            record.properties = record.properties or {}
            record.metadata = record.metadata or {}
            record.external = flag(record.external)
            known[tonumber(record.sceneID)] = true
        end

        local notes = { droppedGroupMembers = 0, droppedWorldRules = 0 }
        local groups = {}
        local nextBatch = 0
        for groupId, members in pairs(snapshot.generatedGroups or {}) do
            local cleaned = {}
            for _, memberID in ipairs(members) do
                local sceneID = tonumber(memberID)
                if sceneID and known[sceneID] then
                    cleaned[#cleaned + 1] = sceneID
                else
                    notes.droppedGroupMembers = notes.droppedGroupMembers + 1
                end
            end
            groups[tostring(groupId)] = cleaned
            local numeric = tonumber(tostring(groupId):match("^batch_(%d+)$"))
            if numeric and numeric >= nextBatch then nextBatch = numeric + 1 end
        end
        snapshot.generatedGroups = groups
        if tonumber(snapshot.nextBatchID) == nil then
            snapshot.nextBatchID = (nextBatch > 0) and nextBatch or 1
        end

        local settings = {}
        for rule, value in pairs(snapshot.worldSettings or {}) do
            local number = tonumber(value)
            if number == nil then
                notes.droppedWorldRules = notes.droppedWorldRules + 1
            else
                settings[tostring(rule)] = number
            end
        end
        snapshot.worldSettings = settings

        return snapshot, notes
    end,
}

--- @return boolean needsMigration, number version
function Migrations.NeedsMigration(snapshot)
    local header = type(snapshot) == "table" and (snapshot.header or {}) or {}
    local version = tonumber(header.schemaVersion) or 1
    return version < Migrations.CURRENT, version
end

--- 迁移到当前版本。
--- 失败时返回 nil + 原因，且绝不修改入参（内部先深拷贝）。
--- @return table|nil migratedSnapshot, table|string report|error
function Migrations.Migrate(snapshot)
    if type(snapshot) ~= "table" then return nil, "document snapshot must be a table" end

    local copy = deepCopy(snapshot)
    local header = copy.header or {}
    local original = header.schemaVersion
    local version = tonumber(original) or 1
    if version < 1 or version > Migrations.CURRENT then
        return nil, string.format("unsupported document schemaVersion: %s", tostring(original))
    end

    local report = { from = version, to = version, applied = {}, notes = {} }
    if version == Migrations.CURRENT then
        report.notes.unchanged = true
        return copy, report
    end

    copy.header = header
    while version < Migrations.CURRENT do
        local step = Migrations.Steps[version]
        if type(step) ~= "function" then
            return nil, string.format("missing migration step: %d -> %d", version, version + 1)
        end
        local ok, result, notes = pcall(step, copy)
        if not ok then
            return nil, string.format("migration step %d -> %d failed: %s", version, version + 1, tostring(result))
        end
        copy = type(result) == "table" and result or copy
        for key, value in pairs(notes or {}) do
            report.notes[key] = (report.notes[key] or 0) + value
        end
        report.applied[#report.applied + 1] = string.format("%d -> %d", version, version + 1)
        version = version + 1
        copy.header = copy.header or {}
        copy.header.schemaVersion = version
    end

    report.to = Migrations.CURRENT
    return copy, report
end

Migrations.DeepCopy = deepCopy

return Migrations
