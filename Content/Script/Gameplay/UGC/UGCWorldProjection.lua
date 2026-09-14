--[[
    UGCWorldProjection.lua

    Maps pure document entities to Unreal actors. This is the only UGC Lua
    service that owns runtime Actor references for authored scene entities.
]]

local PrefabRegistry = require("Gameplay.UGC.UGCPrefabRegistry")

local Projection = {}
Projection.__index = Projection

function Projection.New(bridge)
    return setmetatable({ bridge = bridge, actors = {} }, Projection)
end

function Projection.ToData(transform)
    local loc, rot, scale = UE.UKismetMathLibrary.BreakTransform(transform)
    return { loc.X, loc.Y, loc.Z, rot.Pitch, rot.Yaw, rot.Roll, scale.X, scale.Y, scale.Z }
end

function Projection.ToTransform(data)
    data = data or {}
    return UE.UKismetMathLibrary.MakeTransform(
        UE.FVector(tonumber(data[1]) or 0, tonumber(data[2]) or 0, tonumber(data[3]) or 0),
        UE.FRotator(tonumber(data[4]) or 0, tonumber(data[5]) or 0, tonumber(data[6]) or 0),
        UE.FVector(tonumber(data[7]) or 1, tonumber(data[8]) or 1, tonumber(data[9]) or 1)
    )
end

function Projection:_applyOptionalHooks(record, actor)
    if not actor then return end
    pcall(function() actor:SetProgramID(record.programId) end)
    pcall(function() actor:SetSourceEntityID(record.entityId) end)
    pcall(function() actor:SetDebugVisible(true) end)
end

function Projection:Spawn(record)
    if not self.bridge then return nil, "EditorBridge 未初始化" end
    local path = PrefabRegistry.GetPath(record.prefabName)
    if not path then return nil, "预制体路径不存在: " .. tostring(record.prefabName) end
    local transform = Projection.ToTransform(record.transform)
    local loc, rot, _ = UE.UKismetMathLibrary.BreakTransform(transform)
    local actor = self.bridge:SpawnPlaceable(path, loc, rot)
    if not actor then return nil, "Spawn 失败: " .. tostring(record.prefabName) end
    if self.bridge:TrySetActorTransform(actor, transform) ~= true then
        self.bridge:DestroyActor(actor)
        return nil, "Spawn 后设置 Transform 失败"
    end
    self.actors[record.sceneID] = actor
    self:_applyOptionalHooks(record, actor)
    return actor
end

function Projection:AttachExternal(record, actor)
    if not record or not actor then return false end
    self.actors[record.sceneID] = actor
    self:_applyOptionalHooks(record, actor)
    return true
end

function Projection:GetActor(sceneID)
    local actor = self.actors[sceneID]
    if actor and UE.UKismetSystemLibrary.IsValid(actor) then return actor end
    self.actors[sceneID] = nil
    return nil
end

function Projection:GetTransformData(sceneID)
    local actor = self:GetActor(sceneID)
    if not actor or not self.bridge then return nil end
    return Projection.ToData(self.bridge:GetActorTransform(actor))
end

function Projection:SetTransform(sceneID, transformData)
    local actor = self:GetActor(sceneID)
    if not actor or not self.bridge then return false end
    return self.bridge:TrySetActorTransform(actor, Projection.ToTransform(transformData)) == true
end

function Projection:Destroy(sceneID, skipDestroy)
    local actor = self.actors[sceneID]
    if actor and not skipDestroy and self.bridge and UE.UKismetSystemLibrary.IsValid(actor) then
        if self.bridge:TryDestroyActor(actor) ~= true then return false end
    end
    self.actors[sceneID] = nil
    return true
end

function Projection:Clear()
    local ids = {}
    for sceneID in pairs(self.actors) do ids[#ids + 1] = sceneID end
    for _, sceneID in ipairs(ids) do self:Destroy(sceneID, false) end
end

return Projection
