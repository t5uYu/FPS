--[[
    run_properties.lua

    T8：实体属性（Typed Property Bag）与层级（parentId / children）的回归测试。

    覆盖点：
      1. SetProperty 命令写入 + Undo/Redo（首次设置的反操作是移除）
      2. 覆盖写与 RemoveProperty 的撤销语义
      3. schema 白名单与类型校验（数值/字符串/布尔/枚举/长度）→ 稳定错误码
      4. reference 类型：目标实体必须存在（reference_not_found）
      5. 属性数量上限守卫（property_limit_reached）
      6. 层级：SetParent / GetChildren / ClearParent 与撤销
      7. 层级拒绝：自引用、父不存在、成环
      8. 删除父实体后子节点上移到祖父；撤销删除会恢复层级
      9. 存档往返保留 properties / parentId
     10. 存档校验拒绝悬空父级、自引用、环与非法属性值
     11. LLM 注册表暴露 set_property / get_property / set_parent / list_children 并带风险分类
]]

local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

package.preload["Gameplay.UGC.UGCPrefabRegistry"] = function()
    return {
        IsValid = function(id) return id == "Box" end,
        GetPath = function(id) return id == "Box" and "/Game/Test/Box.Box_C" or nil end,
        ListIDs = function() return { "Box" } end,
        GetSemanticDesc = function() return "Box（测试用方块）" end,
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
function UE.UKismetSystemLibrary.IsValid(actor) return actor and actor.valid ~= false end

local function actor()
    return {
        valid = true,
        SetProgramID = function(self, id) self.programId = id end,
        SetSourceEntityID = function(self, id) self.entityId = id end,
        SetDebugVisible = function(self, value) self.debugVisible = value end,
    }
end

local bridge = { actors = {} }
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
function bridge:DestroyActor(value) value.valid = false end
function bridge:TryDestroyActor(value) value.valid = false; return true end
function bridge:SetGameRule(rule, value) self.rules = self.rules or {}; self.rules[rule] = value; return true end
function bridge:GetGameRule(rule) return (self.rules or {})[rule] or -1 end

local SceneData = require("Gameplay.UGC.UGCSceneData")
local Document = require("Gameplay.UGC.UGCDocument")
local PropertySchema = require("Gameplay.UGC.UGCPropertySchema")
local Registry = require("Gameplay.UGC.UGCFunctionRegistry")
local json = require("Util.json")

-- 注意：这里**不能**给 UGCLog 之类补全局变量。
-- 之前本测试为了跑通 RegisterAll 手动 `UGCLog = require(...)`，
-- 结果掩盖了 Generators/Init.lua 真的没有 require UGCLog 的运行时缺陷
-- （2026-09-15 编辑器实跑时 RegisterAll 抛异常、LLM 工具注册表起不来）。
-- 现在那个文件已修正，测试也不再补全局；run_tests.ps1 里加了对应的静态守卫。

local total, passed = 0, 0
local function check(value, message) if not value then error(message or "check failed", 2) end end
local function equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s got %s", message or "not equal", tostring(expected), tostring(actual)), 2)
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
local function transform(x) return UE.UKismetMathLibrary.MakeTransform(UE.FVector(x, 2, 3), UE.FRotator(0, 0, 0), UE.FVector(1, 1, 1)) end
local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = deepCopy(v) end
    return copy
end

--============================================================
-- 1-2. 命令与撤销
--============================================================

test("set property via command and undo removes it", function()
    SceneData:Init(bridge)
    local id = SceneData:CreateActorWithTransform("Box", transform(1))
    local result = SceneData:SetProperty(id, "mass", 42)
    check(result.ok, result.message)
    equal(SceneData:GetProperty(id, "mass"), 42)
    equal(#SceneData:ListProperties(id), 1)

    check(SceneData:Undo(), "undo 应该成功")
    equal(SceneData:GetProperty(id, "mass"), nil, "首次设置的反操作是移除属性")
    check(SceneData:Redo())
    equal(SceneData:GetProperty(id, "mass"), 42, "redo 恢复属性")
    equal(#SceneData:ListProperties(id), 1)
end)

test("overwriting and removing a property is undoable", function()
    SceneData:Init(bridge)
    local id = SceneData:CreateActorWithTransform("Box", transform(1))
    check(SceneData:SetProperty(id, "material", "Metal").ok)
    check(SceneData:SetProperty(id, "material", "Wood").ok)
    equal(SceneData:GetProperty(id, "material"), "Wood")
    check(SceneData:Undo())
    equal(SceneData:GetProperty(id, "material"), "Metal", "撤销回到上一个值")
    check(SceneData:Redo())
    equal(SceneData:GetProperty(id, "material"), "Wood")

    local removed = SceneData:RemoveProperty(id, "material")
    check(removed.ok, removed.message)
    equal(SceneData:GetProperty(id, "material"), nil)
    check(SceneData:Undo())
    equal(SceneData:GetProperty(id, "material"), "Wood", "撤销移除会写回原值")

    local missing = SceneData:RemoveProperty(id, "note")
    check(not missing.ok, "未设置的属性不能被移除")
    equal(missing.code, "missing_property")
end)

--============================================================
-- 3-5. schema
--============================================================

test("schema rejects unknown keys and bad values with stable codes", function()
    SceneData:Init(bridge)
    local id = SceneData:CreateActorWithTransform("Box", transform(1))
    local cases = {
        { key = "mass",     value = "heavy",              code = "invalid_property_value", what = "数值类型" },
        { key = "mass",     value = 99999,                code = "invalid_property_value", what = "数值上界" },
        { key = "material", value = "metel",              code = "invalid_property_value", what = "枚举值" },
        { key = "lit",      value = "maybe",              code = "invalid_property_value", what = "布尔值" },
        { key = "note",     value = string.rep("x", 200),  code = "invalid_property_value", what = "字符串长度" },
        { key = "masss",    value = 1,                    code = "unknown_property",       what = "键名拼错" },
    }
    for _, case in ipairs(cases) do
        local result = SceneData:SetProperty(id, case.key, case.value)
        check(not result.ok, case.what .. " 应该被拒绝")
        equal(result.code, case.code, case.what .. " 的错误码")
    end
    equal(#SceneData:ListProperties(id), 0, "被拒绝的属性不得写入文档")

    local ghost = SceneData:SetProperty(999, "mass", 1)
    check(not ghost.ok)
    equal(ghost.code, "entity_not_found")
end)

test("reference properties must point at an existing entity", function()
    SceneData:Init(bridge)
    local a = SceneData:CreateActorWithTransform("Box", transform(1))
    local b = SceneData:CreateActorWithTransform("Box", transform(2))
    local ok = SceneData:SetProperty(a, "link", b)
    check(ok.ok, ok.message)
    equal(SceneData:GetProperty(a, "link"), b)

    local dangling = SceneData:SetProperty(a, "link", 999)
    check(not dangling.ok, "引用不存在的实体必须被拒绝")
    equal(dangling.code, "reference_not_found")

    local notANumber = SceneData:SetProperty(a, "link", "abc")
    check(not notANumber.ok)
    equal(notANumber.code, "invalid_property_value")
    equal(SceneData:GetProperty(a, "link"), b, "被拒绝的写入不得改动原值")
end)

test("property count ceiling is enforced", function()
    SceneData:Init(bridge)
    local id = SceneData:CreateActorWithTransform("Box", transform(1))
    local original = PropertySchema.MAX_PROPERTIES
    PropertySchema.MAX_PROPERTIES = 2
    local okFirst = SceneData:SetProperty(id, "mass", 1)
    local okSecond = SceneData:SetProperty(id, "note", "a")
    local blocked = SceneData:SetProperty(id, "lit", true)
    PropertySchema.MAX_PROPERTIES = original
    check(okFirst.ok and okSecond.ok, "上限内的写入应当成功")
    check(not blocked.ok, "超过上限必须被拒绝")
    equal(blocked.code, "property_limit_reached")
    check(SceneData:SetProperty(id, "lit", true).ok, "恢复上限后可以继续写")
end)

--============================================================
-- 6-8. 层级
--============================================================

test("hierarchy commands set parent and undo to the previous parent", function()
    SceneData:Init(bridge)
    local a = SceneData:CreateActorWithTransform("Box", transform(1))
    local b = SceneData:CreateActorWithTransform("Box", transform(2))
    local c = SceneData:CreateActorWithTransform("Box", transform(3))

    check(SceneData:SetParent(b, a).ok)
    equal(SceneData:GetParent(b), a)
    equal(SceneData:GetChildren(a)[1], b)
    equal(#SceneData:GetChildren(a), 1)

    check(SceneData:SetParent(c, a).ok)
    check(SceneData:SetParent(b, c).ok)
    equal(SceneData:GetParent(b), c)
    equal(SceneData:GetChildren(c)[1], b)
    equal(#SceneData:GetChildren(a), 1, "a 只剩 c 一个直接子节点")

    check(SceneData:Undo())
    equal(SceneData:GetParent(b), a, "撤销回到之前的父级")
    check(SceneData:Redo())
    equal(SceneData:GetParent(b), c)

    check(SceneData:ClearParent(b).ok)
    equal(SceneData:GetParent(b), nil)
    check(SceneData:Undo())
    equal(SceneData:GetParent(b), c, "清除父级可以撤销")
end)

test("hierarchy rejects self parenting, missing parents and cycles", function()
    SceneData:Init(bridge)
    local a = SceneData:CreateActorWithTransform("Box", transform(1))
    local b = SceneData:CreateActorWithTransform("Box", transform(2))
    local c = SceneData:CreateActorWithTransform("Box", transform(3))

    local selfParent = SceneData:SetParent(a, a)
    check(not selfParent.ok, "自引用必须被拒绝")
    equal(selfParent.code, "invalid_parent")

    local missing = SceneData:SetParent(a, 999)
    check(not missing.ok, "父不存在必须被拒绝")
    equal(missing.code, "invalid_parent")

    local ghost = SceneData:SetParent(999, a)
    check(not ghost.ok)
    equal(ghost.code, "entity_not_found")

    check(SceneData:SetParent(b, a).ok)
    check(SceneData:SetParent(c, b).ok)
    local cycle = SceneData:SetParent(a, c)
    check(not cycle.ok, "成环必须被拒绝（a 已经是 c 的祖先）")
    equal(cycle.code, "hierarchy_cycle")
    equal(SceneData:GetParent(a), nil, "被拒绝的操作不得改变层级")

    local root = SceneData:ClearParent(a)
    check(not root.ok, "根节点没有父级可清除")
    equal(root.code, "invalid_parent")
end)

test("deleting a parent reparents children and undo restores the hierarchy", function()
    SceneData:Init(bridge)
    local a = SceneData:CreateActorWithTransform("Box", transform(1))
    local b = SceneData:CreateActorWithTransform("Box", transform(2))
    local c = SceneData:CreateActorWithTransform("Box", transform(3))
    check(SceneData:SetParent(b, a).ok)
    check(SceneData:SetParent(c, b).ok)

    check(SceneData:DeleteActor(b))
    equal(SceneData:GetParent(c), a, "孙子被上移到祖父，不留悬空 parentId")
    equal(SceneData:GetChildren(a)[1], c)

    check(SceneData:Undo(), "撤销删除")
    equal(SceneData:GetParent(c), b, "撤销删除要恢复原来的层级")
    equal(SceneData:GetChildren(b)[1], c)
end)

--============================================================
-- 9-10. 存档
--============================================================

test("properties and hierarchy survive a save and load round trip", function()
    SceneData:Init(bridge)
    local a = SceneData:CreateActorWithTransform("Box", transform(1))
    local b = SceneData:CreateActorWithTransform("Box", transform(2))
    check(SceneData:SetParent(b, a).ok)
    check(SceneData:SetProperty(b, "mass", 12.5).ok)
    check(SceneData:SetProperty(b, "link", a).ok)

    local encoded = json.encode(SceneData:SerializePackageTable())
    SceneData:Init(bridge)
    local loaded, loadMessage = SceneData:DeserializePackageTable(json.decode(encoded))
    check(loaded, "反序列化应当成功: " .. tostring(loadMessage))

    local entry = SceneData:QueryActor(b)
    check(entry, "实体应当存在")
    equal(entry.properties.mass, 12.5)
    equal(entry.properties.link, a)
    equal(entry.parentId, a)
    equal(SceneData:GetChildren(a)[1], b)
end)

test("snapshot validation rejects dangling parents, cycles and bad property values", function()
    SceneData:Init(bridge)
    local a = SceneData:CreateActorWithTransform("Box", transform(1))
    local b = SceneData:CreateActorWithTransform("Box", transform(2))
    check(SceneData:SetParent(b, a).ok)

    local snapshot = SceneData:SerializePackageTable().document
    local valid, validError = Document.ValidateSnapshot(deepCopy(snapshot))
    check(valid, "合法快照应当通过: " .. tostring(validError))

    local dangling = deepCopy(snapshot)
    dangling.entities[2].parentId = 999
    local okDangling, errDangling = Document.ValidateSnapshot(dangling)
    check(not okDangling, "悬空父级必须被拒绝")
    check(tostring(errDangling):find("missing sceneID", 1, true), "错误信息应当说明父级缺失: " .. tostring(errDangling))

    local selfParent = deepCopy(snapshot)
    selfParent.entities[2].parentId = selfParent.entities[2].sceneID
    local okSelf, errSelf = Document.ValidateSnapshot(selfParent)
    check(not okSelf, "自引用必须被拒绝")
    check(tostring(errSelf):find("own parent", 1, true), tostring(errSelf))

    local cycle = deepCopy(snapshot)
    cycle.entities[1].parentId = b
    local okCycle, errCycle = Document.ValidateSnapshot(cycle)
    check(not okCycle, "环必须被拒绝")
    check(tostring(errCycle):find("cycle", 1, true), tostring(errCycle))

    local badProperty = deepCopy(snapshot)
    badProperty.entities[2].properties = { mass = "heavy" }
    local okProperty, errProperty = Document.ValidateSnapshot(badProperty)
    check(not okProperty, "非法属性值必须被拒绝")
    check(tostring(errProperty):find("必须是数值", 1, true), tostring(errProperty))

    local unknownKey = deepCopy(snapshot)
    unknownKey.entities[2].properties = { masss = 1 }
    local okUnknown, errUnknown = Document.ValidateSnapshot(unknownKey)
    check(not okUnknown, "未登记的属性键必须被拒绝")
    check(tostring(errUnknown):find("未知属性键", 1, true), tostring(errUnknown))
end)

--============================================================
-- 11. LLM 注册表
--============================================================

test("registry exposes property and hierarchy tools with policy risk", function()
    SceneData:Init(bridge)
    local id = SceneData:CreateActorWithTransform("Box", transform(1))
    Registry:Init({ GetUGCBridge = function() return bridge end })

    -- GetSchemas 返回的是给 LLM 的 JSON 数组（不是 Lua 表）
    local schemas = json.decode(Registry:GetSchemas())
    check(type(schemas) == "table", "GetSchemas 应当返回 JSON 数组")
    local byName = {}
    for _, schema in ipairs(schemas) do
        local wrapper = schema["function"] or schema
        byName[wrapper.name] = wrapper
    end
    for _, name in ipairs({ "set_property", "get_property", "set_parent", "list_children" }) do
        check(byName[name], "注册表缺少工具 " .. name)
    end

    local keyEnum = byName.set_property.parameters.properties.key.enum
    local hasMass = false
    for _, key in ipairs(keyEnum or {}) do if key == "mass" then hasMass = true end end
    check(hasMass, "key 参数应当暴露 schema 白名单作为 enum")

    local deniedOk, deniedMessage = Registry:Call("set_property", { scene_id = id, key = "mass", value = "42" },
        { source = "ai", approved = false })
    check(not deniedOk, "未审批的 AI 写操作必须被拒绝")
    check(tostring(deniedMessage):find("审批", 1, true) or tostring(deniedMessage):find("approv", 1, true),
        "拒绝原因应当说明需要审批: " .. tostring(deniedMessage))

    local callOk, callMessage = Registry:Call("set_property", { scene_id = id, key = "mass", value = "42" },
        { source = "ai", approved = true })
    check(callOk, "审批后的写入应当成功: " .. tostring(callMessage))
    equal(SceneData:GetProperty(id, "mass"), 42, "字符串入参按 schema 转成数值")

    local readOk, readMessage = Registry:Call("get_property", { scene_id = id, key = "mass" }, { source = "ai" })
    check(readOk)
    check(tostring(readMessage):find("42", 1, true), "读回的值应当包含 42: " .. tostring(readMessage))

    local childOk = Registry:Call("set_parent", { scene_id = id, parent_scene_id = id }, { source = "local", approved = true })
    check(not childOk, "自引用在注册表路径上同样被拒绝")
    local listOk = Registry:Call("list_children", { scene_id = id }, { source = "ai" })
    check(listOk, "list_children 应当可读")
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
