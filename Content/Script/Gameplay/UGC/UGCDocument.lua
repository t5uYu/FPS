--[[
    UGCDocument.lua

    Pure UGC document model. This module deliberately contains no UObject,
    Actor, Widget, file IO, or World access. Runtime projection and persistence
    are handled by separate services.
]]

local Migrations = require("Gameplay.UGC.UGCMigrations")

local Document = {}
Document.__index = Document

local CURRENT_SCHEMA_VERSION = Migrations.CURRENT

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

local function makeDocumentId()
    local timestamp = os.time and os.time() or 0
    local salt = math.random(0, 0x7fffffff)
    return string.format("ugc-%x-%08x", timestamp, salt)
end

local function normalizeRecord(self, record)
    local sceneID = assert(tonumber(record.sceneID), "entity record requires sceneID")
    local entityId = record.entityId or string.format("%s-entity-%d", self.header.documentId, sceneID)
    return {
        sceneID = sceneID,
        entityId = tostring(entityId),
        actorId = record.actorId or ("actor_" .. sceneID),
        programId = record.programId or ("actor_prog_" .. sceneID),
        prefabName = record.prefabName or record.prefab or "Unknown",
        transform = deepCopy(record.transform or record.t or {0, 0, 0, 0, 0, 0, 1, 1, 1}),
        external = record.external == true,
        metadata = deepCopy(record.metadata or {}),
        tags = deepCopy(record.tags or {}),
        properties = deepCopy(record.properties or {}),
    }
end

function Document.New(options)
    options = options or {}
    local self = setmetatable({}, Document)
    self.header = {
        documentId = options.documentId or makeDocumentId(),
        schemaVersion = CURRENT_SCHEMA_VERSION,
        revision = tonumber(options.revision) or 0,
        contentVersion = options.contentVersion or "1",
    }
    self.nextSceneID = tonumber(options.nextSceneID) or 1
    self.nextBatchID = tonumber(options.nextBatchID) or 1
    self.entities = {}
    self.programs = {}
    self.generatedGroups = {}
    self.worldSettings = {}
    self.dirty = false
    return self
end

function Document:Touch()
    self.header.revision = self.header.revision + 1
    self.dirty = true
end

function Document:AllocateSceneID()
    local sceneID = self.nextSceneID
    self.nextSceneID = sceneID + 1
    return sceneID
end

function Document:PeekGroupID()
    return "batch_" .. self.nextBatchID
end

function Document:AllocateGroupID()
    local groupId = self:PeekGroupID()
    self.nextBatchID = self.nextBatchID + 1
    return groupId
end

function Document:MakeEntityRecord(prefabName, transform, options)
    options = options or {}
    local sceneID = options.sceneID or self:AllocateSceneID()
    if sceneID >= self.nextSceneID then self.nextSceneID = sceneID + 1 end
    return normalizeRecord(self, {
        sceneID = sceneID,
        entityId = options.entityId,
        actorId = options.actorId,
        programId = options.programId,
        prefabName = prefabName,
        transform = transform,
        external = options.external,
        metadata = options.metadata,
        tags = options.tags,
        properties = options.properties,
    })
end

function Document:InsertEntity(record)
    local normalized = normalizeRecord(self, record)
    if self.entities[normalized.sceneID] then
        return false, "sceneID already exists: " .. tostring(normalized.sceneID)
    end
    self.entities[normalized.sceneID] = normalized
    if normalized.sceneID >= self.nextSceneID then
        self.nextSceneID = normalized.sceneID + 1
    end
    return true, normalized
end

function Document:RemoveEntity(sceneID)
    local record = self.entities[sceneID]
    if not record then return nil end
    self.entities[sceneID] = nil
    self.programs[record.programId] = nil
    local emptyGroups = {}
    for groupId, members in pairs(self.generatedGroups) do
        for i = #members, 1, -1 do
            if members[i] == sceneID then table.remove(members, i) end
        end
        if #members == 0 then emptyGroups[#emptyGroups + 1] = groupId end
    end
    for _, groupId in ipairs(emptyGroups) do self.generatedGroups[groupId] = nil end
    return record
end

function Document:GetEntity(sceneID)
    return self.entities[sceneID]
end

function Document:SetTransform(sceneID, transform)
    local record = self.entities[sceneID]
    if not record then return false end
    record.transform = deepCopy(transform)
    return true
end

function Document:Count()
    local count = 0
    for _ in pairs(self.entities) do count = count + 1 end
    return count
end

function Document:SetProgram(programId, data)
    if not programId or programId == "" then return false end
    self.programs[programId] = deepCopy(data)
    return true
end

function Document:GetProgram(programId)
    return self.programs[programId]
end

function Document:RemoveProgram(programId)
    local oldValue = self.programs[programId]
    self.programs[programId] = nil
    return oldValue
end

function Document:CreateGroup(groupId)
    if not groupId then
        groupId = self:AllocateGroupID()
    elseif not self.generatedGroups[groupId] then
        local numericId = tonumber(tostring(groupId):match("^batch_(%d+)$"))
        if numericId and numericId >= self.nextBatchID then
            self.nextBatchID = numericId + 1
        end
    end
    if not self.generatedGroups[groupId] then self.generatedGroups[groupId] = {} end
    return groupId
end

function Document:AddToGroup(groupId, sceneID)
    local group = self.generatedGroups[groupId]
    if not group or not self.entities[sceneID] then return false end
    for _, memberId in ipairs(group) do
        if memberId == sceneID then return true end
    end
    group[#group + 1] = sceneID
    return true
end

function Document:RemoveFromGroup(groupId, sceneID)
    local group = self.generatedGroups[groupId]
    if not group then return false end
    for i = #group, 1, -1 do
        if group[i] == sceneID then
            table.remove(group, i)
            return true
        end
    end
    return false
end

function Document:RemoveGroup(groupId)
    local group = self.generatedGroups[groupId]
    self.generatedGroups[groupId] = nil
    return group
end

function Document:Snapshot()
    local entities = {}
    for _, record in pairs(self.entities) do
        entities[#entities + 1] = deepCopy(record)
    end
    table.sort(entities, function(a, b) return a.sceneID < b.sceneID end)
    return {
        header = deepCopy(self.header),
        nextSceneID = self.nextSceneID,
        nextBatchID = self.nextBatchID,
        entities = entities,
        programs = deepCopy(self.programs),
        generatedGroups = deepCopy(self.generatedGroups),
        worldSettings = deepCopy(self.worldSettings),
    }
end

function Document.ValidateSnapshot(snapshot)
    if type(snapshot) ~= "table" then return false, "document snapshot must be a table" end
    local header = snapshot.header or {}
    local schemaVersion = tonumber(header.schemaVersion) or 1
    if schemaVersion < 1 or schemaVersion > CURRENT_SCHEMA_VERSION then
        return false, "unsupported document schemaVersion: " .. tostring(header.schemaVersion)
    end
    if snapshot.entities ~= nil and type(snapshot.entities) ~= "table" then
        return false, "document entities must be an array"
    end
    if snapshot.programs ~= nil and type(snapshot.programs) ~= "table" then
        return false, "document programs must be a table"
    end
    if snapshot.generatedGroups ~= nil and type(snapshot.generatedGroups) ~= "table" then
        return false, "document generatedGroups must be a table"
    end

    local sceneIDs, entityIDs = {}, {}
    for _, record in ipairs(snapshot.entities or {}) do
        local sceneID = tonumber(record.sceneID)
        if not sceneID or sceneID < 1 or sceneID % 1 ~= 0 then return false, "invalid sceneID" end
        if sceneIDs[sceneID] then return false, "duplicate sceneID: " .. tostring(sceneID) end
        sceneIDs[sceneID] = true
        if record.entityId then
            local entityId = tostring(record.entityId)
            if entityIDs[entityId] then return false, "duplicate entityId: " .. entityId end
            entityIDs[entityId] = true
        end
        if type(record.transform or record.t) ~= "table" or #(record.transform or record.t) ~= 9 then
            return false, "entity transform must contain 9 values for sceneID " .. tostring(sceneID)
        end
    end
    for groupId, members in pairs(snapshot.generatedGroups or {}) do
        if type(groupId) ~= "string" or type(members) ~= "table" then return false, "invalid generated group" end
        for _, sceneID in ipairs(members) do
            if not sceneIDs[tonumber(sceneID)] then
                return false, "generated group references missing sceneID: " .. tostring(sceneID)
            end
        end
    end
    return true
end

function Document.FromSnapshot(snapshot)
    snapshot = snapshot or {}
    -- T15：任何入口（新包 / 旧包 / 旧 scene.json 兼容层）都先过显式迁移链，
    -- 迁移失败时直接拒绝，不做半套加载。
    local migrated, report = Migrations.Migrate(snapshot)
    if not migrated then
        return nil, "迁移失败: " .. tostring(report)
    end
    snapshot = migrated

    local valid, validationError = Document.ValidateSnapshot(snapshot)
    if not valid then return nil, validationError end
    local header = snapshot.header or {}
    local self = Document.New({
        documentId = header.documentId,
        revision = header.revision,
        contentVersion = header.contentVersion,
        nextSceneID = snapshot.nextSceneID,
        nextBatchID = snapshot.nextBatchID,
    })
    self.header.schemaVersion = tonumber(header.schemaVersion) or CURRENT_SCHEMA_VERSION
    for _, record in ipairs(snapshot.entities or {}) do
        local ok, err = self:InsertEntity(record)
        if not ok then return nil, err end
    end
    self.programs = deepCopy(snapshot.programs or {})
    self.generatedGroups = deepCopy(snapshot.generatedGroups or {})
    self.worldSettings = deepCopy(snapshot.worldSettings or {})
    self.dirty = false
    return self
end

Document.DeepCopy = deepCopy
Document.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION

return Document
