local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

package.preload["Gameplay.UGC.UGCPrefabRegistry"] = function()
    return {
        IsValid = function(id) return id == "Box" end,
        GetPath = function(id) return id == "Box" and "/Game/Test/Box.Box_C" or nil end,
    }
end

UE = {
    FVector = function(x,y,z) return {X=x,Y=y,Z=z} end,
    FRotator = function(p,y,r) return {Pitch=p,Yaw=y,Roll=r} end,
    UKismetMathLibrary = {},
    UKismetSystemLibrary = {},
}
function UE.UKismetMathLibrary.MakeTransform(loc, rot, scale)
    return {loc=loc,rot=rot,scale=scale}
end
function UE.UKismetMathLibrary.BreakTransform(transform)
    return transform.loc, transform.rot, transform.scale
end
function UE.UKismetSystemLibrary.IsValid(actor) return actor and actor.valid ~= false end

local function actor()
    return {
        valid=true,
        SetProgramID=function(self,id) self.programId=id end,
        SetSourceEntityID=function(self,id) self.entityId=id end,
        SetDebugVisible=function(self,value) self.debugVisible=value end,
    }
end
local bridge = { actors={} }
function bridge:SpawnPlaceable(path, loc, rot)
    local value=actor(); value.path=path
    value.transform=UE.UKismetMathLibrary.MakeTransform(loc,rot,UE.FVector(1,1,1))
    self.actors[#self.actors+1]=value
    return value
end
function bridge:SetActorTransform(value, transform) value.transform=transform end
function bridge:TrySetActorTransform(value, transform) value.transform=transform; return true end
function bridge:GetActorTransform(value) return value.transform end
function bridge:DestroyActor(value) value.valid=false end
function bridge:TryDestroyActor(value) value.valid=false; return true end

local SceneData = require("Gameplay.UGC.UGCSceneData")
local total, passed=0,0
local function check(v,m) if not v then error(m or "check failed",2) end end
local function equal(a,b,m) if a~=b then error(string.format("%s: expected %s got %s",m or "not equal",tostring(b),tostring(a)),2) end end
local function test(name,fn)
    total=total+1; local ok,err=pcall(fn)
    if ok then passed=passed+1; print("PASS "..name) else io.stderr:write("FAIL "..name..": "..tostring(err).."\n") end
end
local function transform(x) return UE.UKismetMathLibrary.MakeTransform(UE.FVector(x,2,3),UE.FRotator(0,0,0),UE.FVector(1,1,1)) end

test("scene create transform delete undo redo", function()
    SceneData:Init(bridge)
    local id = SceneData:CreateActorWithTransform("Box", transform(1))
    equal(id,1); equal(SceneData:Count(),1)
    check(SceneData:ModifyActor(id,transform(9)))
    equal(SceneData:QueryActor(id).transform[1],9)
    check(SceneData:Undo()); equal(SceneData:QueryActor(id).transform[1],1)
    check(SceneData:Redo()); equal(SceneData:QueryActor(id).transform[1],9)
    check(SceneData:SetActorScript(id,{nodes={{id="n"}}}))
    check(SceneData:DeleteActor(id)); equal(SceneData:Count(),0); equal(SceneData:GetActorScript(id),nil)
    check(SceneData:Undo()); equal(SceneData:Count(),1); equal(SceneData:GetActorScript(id).nodes[1].id,"n")
    check(SceneData:Redo()); equal(SceneData:Count(),0)
end)

test("scene composite group is atomic and undoable", function()
    SceneData:Init(bridge)
    local batch=SceneData:AllocateBatchID()
    local result=SceneData:ExecuteComposite({
        {type="CreateEntity",prefabName="Box",transform={1,0,0,0,0,0,1,1,1},groups={batch}},
        {type="CreateEntity",prefabName="Box",transform={2,0,0,0,0,0,1,1,1},groups={batch}},
    },"batch")
    check(result.ok,result.message); equal(SceneData:Count(),2); equal(#SceneData:GetBatchActors(batch),2)
    equal(SceneData:GetRevision(),1,"composite should increment revision once")
    check(SceneData:Undo()); equal(SceneData:Count(),0); equal(SceneData:GetBatchActors(batch),nil)
    equal(SceneData:GetRevision(),2,"undo should increment revision once")
    check(SceneData:Redo()); equal(SceneData:Count(),2); equal(#SceneData:GetBatchActors(batch),2)
    equal(SceneData:GetRevision(),3,"redo should increment revision once")
end)

test("failed scene composite restores metadata and suppresses events", function()
    SceneData:Init(bridge)
    local eventCount=0
    SceneData:Subscribe("changed",function() eventCount=eventCount+1 end)
    local doc=SceneData:GetDocument()
    local beforeRevision=doc.header.revision
    local beforeNextScene=doc.nextSceneID
    local beforeNextBatch=doc.nextBatchID
    local batch=SceneData:AllocateBatchID()
    local result=SceneData:ExecuteComposite({
        {type="CreateEntity",prefabName="Box",transform={1,0,0,0,0,0,1,1,1},groups={batch}},
        {type="CreateEntity",prefabName="Missing",transform={2,0,0,0,0,0,1,1,1},groups={batch}},
    },"fail")
    check(not result.ok); equal(SceneData:Count(),0); equal(eventCount,0)
    equal(doc.header.revision,beforeRevision); equal(doc.nextSceneID,beforeNextScene); equal(doc.nextBatchID,beforeNextBatch)
    equal(SceneData:GetBatchActors(batch),nil)
end)

test("stale command revision is rejected", function()
    SceneData:Init(bridge)
    local revision=SceneData:GetRevision()
    check(SceneData:CreateActorWithTransform("Box", transform(1)))
    local result=SceneData:ExecuteCommand({type="CreateEntity",prefabName="Box",transform={2,0,0,0,0,0,1,1,1}}, {source="test",baseRevision=revision})
    check(not result.ok); equal(result.code,"revision_conflict"); equal(SceneData:Count(),1)
end)

test("world rules use commands, clamp projection, and undo", function()
    SceneData:Init(bridge)
    local rules={GravityScale=1}
    SceneData:RegisterWorldRuleAdapter(function(rule,value)
        rules[rule]=math.max(0.1,math.min(3,value)); return true
    end, function(rule) return rules[rule] or -1 end, function() rules={GravityScale=1} end)
    local result=SceneData:SetWorldRule("GravityScale",9,{source="test",approved=true})
    check(result.ok); equal(rules.GravityScale,3); equal(SceneData:GetWorldRule("GravityScale"),3)
    check(SceneData:Undo()); equal(rules.GravityScale,1); equal(SceneData:GetWorldRule("GravityScale"),1)
    check(SceneData:Redo()); equal(rules.GravityScale,3); equal(SceneData:GetWorldRule("GravityScale"),3)
end)

test("program updates participate in undo redo", function()
    SceneData:Init(bridge)
    check(SceneData:SetLevelScript({version=1}))
    equal(SceneData:GetLevelScript().version,1)
    check(SceneData:SetLevelScript({version=2}))
    equal(SceneData:GetLevelScript().version,2)
    check(SceneData:Undo()); equal(SceneData:GetLevelScript().version,1)
    check(SceneData:Redo()); equal(SceneData:GetLevelScript().version,2)
end)

test("external entity uses adapters and supports undo redo", function()
    SceneData:Init(bridge)
    local restored, destroyed = 0, 0
    SceneData:RegisterExternalAdapter("fake", function(record)
        restored = restored + 1
        SceneData:AttachExternalActor(record.sceneID, actor())
        return true
    end, function(value)
        destroyed = destroyed + 1
        value.valid = false
        return true
    end)
    local id, value = SceneData:CreateExternalEntity("External", {3,0,0,0,0,0,1,1,1}, {kind="fake",seed=7})
    equal(id,1); check(value); equal(restored,1); equal(SceneData:Count(),1)
    check(SceneData:Undo()); equal(destroyed,1); equal(SceneData:Count(),0)
    check(SceneData:Redo()); equal(restored,2); equal(SceneData:Count(),1)
end)

if passed~=total then error(string.format("%d/%d tests passed",passed,total)) end
print(string.format("ALL PASS %d/%d",passed,total))


