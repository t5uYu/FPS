--[[
    UGCDocument.lua

    Pure UGC document model. This module deliberately contains no UObject,
    Actor, Widget, file IO, or World access. Runtime projection and persistence
    are handled by separate services.
]]

local Migrations = require("Gameplay.UGC.UGCMigrations")
local PropertySchema = require("Gameplay.UGC.UGCPropertySchema")

local Document = {}
Document.__index = Document

Document.ENTITY_ID_SUFFIX = "-entity-"

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

local MAX_ENTITY_ID_LENGTH = 128

local function makeDocumentId()
    local timestamp = os.time and os.time() or 0
    local salt = math.random(0, 0x7fffffff)
    return string.format("ugc-%x-%08x", timestamp, salt)
end

--- T9：entityId 采用「派生字符串」而不是随机 GUID —— 由 documentId + sceneID 唯一决定，
--- 因此保存/加载/PCG/撤销重做后都稳定，且 golden 回归可逐字节比对（随机 GUID 会破坏这两点）。
--- 约束：documentId 在同一项目文件内唯一；sceneID 只增不复用（见 ValidateSnapshot 的 nextSceneID 检查）；
--- 显式传 entityId 的调用方（如 PCG / 外部导入）必须自己保证不重复，重复会在 InsertEntity 被拒绝。
function Document.MakeEntityId(documentId, sceneID)
    return string.format("%s%s%s", tostring(documentId), Document.ENTITY_ID_SUFFIX, tostring(sceneID))
end

local function validateEntityId(record)
    local entityId = record.entityId
    if type(entityId) ~= "string" or entityId == "" then
        return false, "entityId must be a non-empty string"
    end
    if #entityId > MAX_ENTITY_ID_LENGTH then
        return false, "entityId too long: " .. tostring(#entityId) .. " (limit " .. MAX_ENTITY_ID_LENGTH .. ")"
    end
    if entityId:find("%c") then
        return false, "entityId must not contain control characters: " .. entityId
    end
    return true
end

local function normalizeRecord(self, record)
    local sceneID = assert(tonumber(record.sceneID), "entity record requires sceneID")
    local entityId = record.entityId or Document.MakeEntityId(self.header.documentId, sceneID)
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
        parentId = tonumber(record.parentId),
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

    -- T9：entityId 唯一性。派生 id 由 documentId + sceneID 决定，天然不会撞；
    -- 只有显式传入 entityId 的调用方（PCG / 外部导入）可能重复，这里显式拒绝而不是留到加载期。
    local valid, entityError = validateEntityId(normalized)
    if not valid then return false, entityError end
    for _, existing in pairs(self.entities) do
        if existing.entityId == normalized.entityId then
            return false, "duplicate entityId: " .. normalized.entityId
        end
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

    -- T8：被删实体的子节点上移到它的父级，保持层级连通（不留悬空 parentId）
    for _, other in pairs(self.entities) do
        if tonumber(other.parentId) == sceneID then
            other.parentId = record.parentId
        end
    end

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

--============================================================
-- T8：实体属性（Typed Property Bag）
--   类型校验在 Document 与命令层各做一次：命令层负责给出稳定的错误码，
--   Document 负责保证"任何进入模型的属性都合法"（加载路径也走这里）。
--============================================================

function Document:GetProperty(sceneID, key)
    local record = self.entities[sceneID]
    if not record then return nil end
    return record.properties[key]
end

function Document:CountProperties(sceneID)
    local record = self.entities[sceneID]
    if not record then return 0 end
    local count = 0
    for _ in pairs(record.properties) do count = count + 1 end
    return count
end

--- @return boolean ok, value|string oldValueOrError, boolean|nil existed
function Document:SetProperty(sceneID, key, value)
    local record = self.entities[sceneID]
    if not record then return false, "实体不存在: " .. tostring(sceneID) end
    if type(key) ~= "string" or key == "" then return false, "属性键必须是非空字符串" end

    local valid, err = PropertySchema.Validate(key, value)
    if not valid then return false, err end

    local existed = record.properties[key] ~= nil
    if not existed and self:CountProperties(sceneID) >= PropertySchema.MAX_PROPERTIES then
        return false, string.format("实体属性数量已达上限 %d", PropertySchema.MAX_PROPERTIES)
    end

    local previous = record.properties[key]
    record.properties[key] = value
    return true, previous, existed
end

--- @return boolean ok, value|string oldValueOrError
function Document:RemoveProperty(sceneID, key)
    local record = self.entities[sceneID]
    if not record then return false, "实体不存在: " .. tostring(sceneID) end
    if record.properties[key] == nil then return false, "属性不存在: " .. tostring(key) end
    local previous = record.properties[key]
    record.properties[key] = nil
    return true, previous
end

--- 已设置的属性键（排序），供 UI / AI 查询
function Document:ListProperties(sceneID)
    local record = self.entities[sceneID]
    if not record then return {} end
    local keys = {}
    for key in pairs(record.properties) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

--============================================================
-- T8：层级（parentId 是唯一事实来源，children 由它推导）
--============================================================

function Document:GetParent(sceneID)
    local record = self.entities[sceneID]
    if not record then return nil end
    return record.parentId
end

--- 直接子节点（按 sceneID 排序）
function Document:GetChildren(sceneID)
    local children = {}
    for id, record in pairs(self.entities) do
        if tonumber(record.parentId) == sceneID then children[#children + 1] = id end
    end
    table.sort(children)
    return children
end

--- candidateSceneID 是否是 sceneID 的祖先（带步数上限，容忍已存在的环而不死循环）
function Document:IsAncestor(candidateSceneID, sceneID)
    local candidate = tonumber(candidateSceneID)
    local cursor = tonumber(sceneID)
    local limit = 0
    for _ in pairs(self.entities) do limit = limit + 1 end
    local steps = 0
    while cursor and steps <= limit do
        local record = self.entities[cursor]
        if not record then return false end
        local parentID = tonumber(record.parentId)
        if not parentID then return false end
        if parentID == candidate then return true end
        cursor = parentID
        steps = steps + 1
    end
    return false
end

--- @return boolean ok, number|nil previousParent|string error
function Document:SetParent(sceneID, parentSceneID)
    local record = self.entities[sceneID]
    if not record then return false, "实体不存在: " .. tostring(sceneID) end

    local parentID = tonumber(parentSceneID)
    if not parentID then return false, "父实体 ID 必须是数值" end
    if parentID == sceneID then return false, "实体不能以自己为父" end
    if not self.entities[parentID] then return false, "父实体不存在: " .. tostring(parentID) end
    if self:IsAncestor(sceneID, parentID) then
        return false, string.format("会形成层级环: %d 已经是 %d 的祖先", sceneID, parentID)
    end

    local previous = record.parentId
    record.parentId = parentID
    return true, previous
end

--- @return boolean ok, number|nil previousParent|string error
function Document:ClearParent(sceneID)
    local record = self.entities[sceneID]
    if not record then return false, "实体不存在: " .. tostring(sceneID) end
    local previous = record.parentId
    record.parentId = nil
    return true, previous
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

    local sceneIDs, entityIDs, recordsBySceneID = {}, {}, {}
    local maxSceneID = 0
    for _, record in ipairs(snapshot.entities or {}) do
        local sceneID = tonumber(record.sceneID)
        if not sceneID or sceneID < 1 or sceneID % 1 ~= 0 then return false, "invalid sceneID" end
        if sceneIDs[sceneID] then return false, "duplicate sceneID: " .. tostring(sceneID) end
        sceneIDs[sceneID] = true
        recordsBySceneID[sceneID] = record
        if sceneID > maxSceneID then maxSceneID = sceneID end
        if record.entityId then
            local validId, idError = validateEntityId(record)
            if not validId then return false, idError end
            local entityId = tostring(record.entityId)
            if entityIDs[entityId] then return false, "duplicate entityId: " .. entityId end
            entityIDs[entityId] = true
        end
        if type(record.transform or record.t) ~= "table" or #(record.transform or record.t) ~= 9 then
            return false, "entity transform must contain 9 values for sceneID " .. tostring(sceneID)
        end

        -- T8：属性容器、类型与数量上限（加载路径同样受 schema 约束）
        if record.properties ~= nil and type(record.properties) ~= "table" then
            return false, "entity properties must be a table for sceneID " .. tostring(sceneID)
        end
        local propertyCount = 0
        for key, value in pairs(record.properties or {}) do
            propertyCount = propertyCount + 1
            local validProperty, propertyError = PropertySchema.Validate(key, value)
            if not validProperty then
                return false, string.format("sceneID %d: %s", sceneID, tostring(propertyError))
            end
        end
        if propertyCount > PropertySchema.MAX_PROPERTIES then
            return false, string.format("sceneID %d has %d properties (limit %d)",
                sceneID, propertyCount, PropertySchema.MAX_PROPERTIES)
        end
        if record.parentId ~= nil and tonumber(record.parentId) == nil then
            return false, "entity parentId must be a number for sceneID " .. tostring(sceneID)
        end
    end

    -- T9：nextSceneID 必须严格大于最大 sceneID。否则下一个新实体会拿到已被用过的 sceneID，
    -- 从而让派生 entityId 复用（存档/PCG/网络里同一个 id 指两个实体）。
    local nextSceneID = tonumber(snapshot.nextSceneID)
    if nextSceneID ~= nil and nextSceneID <= maxSceneID then
        return false, string.format("nextSceneID (%s) must exceed the largest sceneID (%s) to keep entity IDs unique",
            tostring(snapshot.nextSceneID), tostring(maxSceneID))
    end
    -- T8：层级校验 —— 父必须存在、不能自引用、不能成环
    for _, record in ipairs(snapshot.entities or {}) do
        local sceneID = tonumber(record.sceneID)
        local parentID = tonumber(record.parentId)
        if parentID ~= nil then
            if parentID == sceneID then
                return false, "entity must not be its own parent: " .. tostring(sceneID)
            end
            if not sceneIDs[parentID] then
                return false, "entity parentId references a missing sceneID: " .. tostring(parentID)
            end
        end
    end
    for _, record in ipairs(snapshot.entities or {}) do
        local visited = {}
        local cursor = tonumber(record.sceneID)
        while cursor do
            if visited[cursor] then
                return false, "entity hierarchy contains a cycle at sceneID " .. tostring(cursor)
            end
            visited[cursor] = true
            local current = recordsBySceneID[cursor]
            cursor = current and tonumber(current.parentId) or nil
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
