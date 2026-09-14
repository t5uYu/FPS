--[[
    run_serialization.lua

    T1 序列化收敛的回归测试。

    覆盖点：
      1. 旧格式 scene.json (version<=3, actors[] 含 sceneID/id + prefab/prefabName + t)
         仍能被 SceneData:DeserializeFromJSON 读回，实体与 Transform 完整恢复
      2. 旧格式 programs.json ({version=2, programs={...}}) 仍能被 DeserializeProgramsJSON 读回
      3. SceneData:SerializeToJSON 输出可被唯一实现 Util.json 解码，字段与旧格式一致
      4. 旧格式 external actor (metadata.kind) 走 adapter 恢复
      5. Util.json 的 NaN / Inf 守卫与非有限数以外的定点输出
      6. 编码结果对键顺序不敏感（存档可 diff、可复现）
]]

local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

package.preload["Gameplay.UGC.UGCPrefabRegistry"] = function()
    return {
        IsValid = function(id) return id == "Box" or id == "External" end,
        GetPath = function(id)
            if id == "Box" then return "/Game/Test/Box.Box_C" end
            if id == "External" then return "/Game/Test/External.External_C" end
            return nil
        end,
    }
end

UE = {
    FVector = function(x, y, z) return { X = x, Y = y, Z = z } end,
    FRotator = function(p, y, r) return { Pitch = p, Yaw = y, Roll = r } end,
    UKismetMathLibrary = {},
    UKismetSystemLibrary = {},
}
function UE.UKismetMathLibrary.MakeTransform(loc, rot, scale)
    return { loc = loc, rot = rot, scale = scale }
end
function UE.UKismetMathLibrary.BreakTransform(transform)
    return transform.loc, transform.rot, transform.scale
end
function UE.UKismetSystemLibrary.IsValid(actor) return actor ~= nil and actor.valid ~= false end

local function actor()
    return {
        valid = true,
        SetProgramID = function(self, id) self.programId = id end,
        SetSourceEntityID = function(self, id) self.entityId = id end,
        SetDebugVisible = function(self, value) self.debugVisible = value end,
    }
end

local bridge = { actors = {}, destroyed = 0 }
function bridge:SpawnPlaceable(path, loc, rot)
    local value = actor()
    value.path = path
    value.transform = UE.UKismetMathLibrary.MakeTransform(loc, rot, UE.FVector(1, 1, 1))
    self.actors[#self.actors + 1] = value
    return value
end
function bridge:SetActorTransform(value, transform) value.transform = transform end
function bridge:TrySetActorTransform(value, transform) value.transform = transform; return true end
function bridge:GetActorTransform(value) return value.transform end
function bridge:DestroyActor(value) value.valid = false; self.destroyed = self.destroyed + 1 end
function bridge:TryDestroyActor(value) value.valid = false; self.destroyed = self.destroyed + 1; return true end

local json = require("Util.json")
local SceneData = require("Gameplay.UGC.UGCSceneData")
local Document = require("Gameplay.UGC.UGCDocument")

local total, passed = 0, 0
local function check(v, m) if not v then error(m or "check failed", 2) end end
local function equal(a, b, m)
    if a ~= b then
        error(string.format("%s: expected %s got %s", m or "not equal", tostring(b), tostring(a)), 2)
    end
end
local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
end

-- 旧格式存档样本（version 3，其中第二条用 v1 的 id/prefabName 写法）
local LEGACY_SCENE_JSON = [[
{
  "version": 3,
  "documentId": "legacy-doc",
  "revision": 12,
  "nextID": 3,
  "nextBatchID": 2,
  "actors": [
    {
      "sceneID": 1,
      "entityId": "legacy-doc-entity-1",
      "actorId": "actor_1",
      "programId": "actor_prog_1",
      "prefab": "Box",
      "t": [100, 0, 0, 0, 90, 0, 1, 1, 1]
    },
    {
      "id": 2,
      "prefabName": "Box",
      "t": [200, 0, 0, 0, 0, 0, 2, 2, 2]
    }
  ],
  "generatedGroups": { "batch_1": [1, 2] },
  "worldSettings": { "GravityScale": 1.5 }
}
]]

local LEGACY_PROGRAMS_JSON = [[
{
  "version": 2,
  "programs": {
    "level_main": { "nodes": [ { "id": "root" } ] },
    "actor_prog_1": { "nodes": [ { "id": "n1" }, { "id": "n2" } ] }
  }
}
]]

-- 世界规则适配器（旧存档带 worldSettings，恢复时必须能应用）
local worldRules = {}
local function registerWorldRules()
    worldRules = {}
    SceneData:RegisterWorldRuleAdapter(
        function(rule, value) worldRules[rule] = value; return true end,
        function(rule) return worldRules[rule] or -1 end,
        function() worldRules = {} end)
end

test("legacy scene.json restores entities transform groups and world settings", function()
    SceneData:Init(bridge)
    registerWorldRules()
    bridge.actors = {}

    local ok, err = SceneData:DeserializeFromJSON(LEGACY_SCENE_JSON)
    check(ok, tostring(err))

    equal(SceneData:Count(), 2, "entity count")
    local first = SceneData:QueryActor(1)
    check(first, "sceneID 1 must exist")
    equal(first.prefabName, "Box", "prefab recovered from 'prefab'")
    equal(first.transform[1], 100, "location X")
    equal(first.transform[5], 90, "yaw")
    equal(first.entityId, "legacy-doc-entity-1", "entityId preserved")
    equal(first.programId, "actor_prog_1", "programId preserved")

    local second = SceneData:QueryActor(2)
    check(second, "sceneID 2 must exist")
    equal(second.prefabName, "Box", "prefab recovered from 'prefabName'")
    equal(second.transform[1], 200, "location X")
    equal(second.transform[7], 2, "scale X")
    equal(second.entityId, "legacy-doc-entity-2", "entityId synthesized from documentId + sceneID")

    local batch = SceneData:GetBatchActors("batch_1")
    check(batch, "generatedGroups must survive legacy load")
    equal(#batch, 2, "batch member count")
    equal(SceneData:GetWorldRule("GravityScale"), 1.5, "world setting restored")
    equal(#bridge.actors, 2, "actors spawned through the bridge")
    equal(Document.CURRENT_SCHEMA_VERSION, 3, "current schema version")
end)

test("legacy scene.json with external actor uses registered adapter", function()
    SceneData:Init(bridge)
    registerWorldRules()
    bridge.actors = {}

    local restored = 0
    SceneData:RegisterExternalAdapter("fake", function(record)
        restored = restored + 1
        SceneData:AttachExternalActor(record.sceneID, actor())
        return true
    end, function(value) value.valid = false; return true end)

    local payload = json.encode({
        version = 3,
        documentId = "legacy-ext",
        revision = 1,
        nextID = 2,
        actors = {
            {
                sceneID = 1,
                prefab = "External",
                t = { 0, 0, 0, 0, 0, 0, 1, 1, 1 },
                external = true,
                metadata = { kind = "fake", seed = 7 },
            },
        },
    })

    local ok, err = SceneData:DeserializeFromJSON(payload)
    check(ok, tostring(err))
    equal(restored, 1, "external restorer invocations")
    equal(SceneData:Count(), 1, "external entity count")
    check(SceneData:QueryActor(1).external, "external flag preserved")
end)

test("legacy programs.json round trips", function()
    SceneData:Init(bridge)
    registerWorldRules()
    bridge.actors = {}

    check(SceneData:DeserializeProgramsJSON(LEGACY_PROGRAMS_JSON), "programs.json must load")
    equal(#SceneData:GetLevelScript().nodes, 1, "level_main nodes")
    equal(#SceneData:GetActorScript(1).nodes, 2, "actor_prog_1 nodes")

    local encoded = SceneData:SerializeProgramsJSON()
    local decoded = json.decode(encoded)
    equal(decoded.version, 2, "programs.json version")
    equal(#decoded.programs.level_main.nodes, 1, "re-encoded level_main nodes")

    check(not SceneData:DeserializeProgramsJSON("not json"), "garbage input must be rejected, not thrown")
    check(not SceneData:DeserializeProgramsJSON('{"version":2}'), "missing programs must be rejected")
end)

test("SerializeToJSON keeps legacy scene.json shape", function()
    SceneData:Init(bridge)
    registerWorldRules()
    bridge.actors = {}

    local sceneID = SceneData:CreateActorWithTransform("Box", UE.UKismetMathLibrary.MakeTransform(
        UE.FVector(7, 8, 9), UE.FRotator(0, 45, 0), UE.FVector(1, 1, 1)))
    equal(sceneID, 1, "created scene id")
    check(SceneData:DeserializeProgramsJSON(LEGACY_PROGRAMS_JSON), "seed programs")

    local encoded = SceneData:SerializeToJSON()
    local data = json.decode(encoded)
    check(data, "SerializeToJSON must produce decodable JSON")
    equal(data.version, 3, "scene.json version")
    equal(data.documentId, SceneData:GetDocument().header.documentId, "documentId")
    equal(data.nextID, 2, "nextID")
    equal(#data.actors, 1, "actor count")
    equal(data.actors[1].sceneID, 1, "actor sceneID")
    equal(data.actors[1].prefab, "Box", "actor prefab")
    equal(data.actors[1].t[1], 7, "actor transform X")
    equal(data.actors[1].t[5], 45, "actor transform Yaw")
    equal(data.actors[1].external, nil, "non-external actors omit the flag")

    -- 输出必须能被自己的读取路径读回
    local reload = require("Gameplay.UGC.UGCSceneData")
    reload:Init(bridge)
    registerWorldRules()
    bridge.actors = {}
    local ok, err = reload:DeserializeFromJSON(encoded)
    check(ok, tostring(err))
    equal(reload:Count(), 1, "reloaded entity count")
    equal(reload:QueryActor(1).transform[1], 7, "reloaded transform")
end)

test("json encodes non-finite numbers as null", function()
    local encoded = json.encode({ a = 0 / 0, b = math.huge, c = -math.huge, d = 1.5, e = 3 })
    check(not encoded:find("nan") and not encoded:find("inf"), "raw NaN/Inf leaked: " .. encoded)
    local data = json.decode(encoded)
    check(data, "output must stay decodable: " .. encoded)
    equal(data.a, nil, "NaN -> null")
    equal(data.b, nil, "Inf -> null")
    equal(data.c, nil, "-Inf -> null")
    equal(data.d, 1.5, "float preserved")
    equal(data.e, 3, "integer stays integral")
    equal(json.encode({ x = 2.0 }), '{"x":2}', "integral float prints without decimal point")
end)

test("json output is deterministic regardless of key order", function()
    local a = { alpha = 1, beta = { y = 2, x = 1 }, gamma = { 1, 2, 3 } }
    local b = { gamma = { 1, 2, 3 }, beta = { x = 1, y = 2 }, alpha = 1 }
    equal(json.encode(a), json.encode(b), "key order must not affect output")
    equal(json.encode({}), "[]", "empty table encodes as empty array")
    equal(json.decode('{"a":1}').a, 1, "decode baseline")
    equal(json.decode("not json"), nil, "invalid input returns nil instead of throwing")
end)

test("legacy serialization surface is load-first (T18)", function()
    SceneData:Init(bridge)
    registerWorldRules()
    bridge.actors = {}

    -- 旧存档读取路径必须保留（UGCPersistence 的迁移路径依赖它们）
    check(type(SceneData.DeserializeFromJSON) == "function", "DeserializeFromJSON must exist")
    check(type(SceneData.DeserializeProgramsJSON) == "function", "DeserializeProgramsJSON must exist")

    -- T18 删除的死入口不得回归
    check(SceneData.SerializeEditorJSON == nil, "SceneData:SerializeEditorJSON must stay deleted")
    check(SceneData.DeserializeEditorJSON == nil, "SceneData:DeserializeEditorJSON must stay deleted")

    -- EditorCore 不再暴露序列化透传（存档只走 UGCPersistence）
    package.preload["Gameplay.Core.UIManager"] = function()
        return { OpenWindow = function() end, CloseWindow = function() end }
    end
    local EditorCore = require("Gameplay.UGC.UGCEditorCore")
    check(EditorCore.SaveSceneJSON == nil, "EditorCore:SaveSceneJSON must stay deleted")
    check(EditorCore.LoadSceneJSON == nil, "EditorCore:LoadSceneJSON must stay deleted")
    check(type(EditorCore.ClearScene) == "function", "EditorCore:ClearScene must remain")

    -- 运行时写入路径只有 UGCPersistence
    local Persistence = require("Gameplay.UGC.UGCPersistence")
    check(Persistence.PROJECT_FILE ~= nil, "UGCPersistence is the single runtime write path")
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
