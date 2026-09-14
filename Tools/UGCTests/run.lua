local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

local total, passed = 0, 0
local function fail(message) error(message, 2) end
local function check(value, message) if not value then fail(message or "check failed") end end
local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s", message or "not equal", tostring(expected), tostring(actual)))
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

local Document = require("Gameplay.UGC.UGCDocument")
local Bus = require("Gameplay.UGC.UGCCommandBus")
local Compiler = require("Gameplay.UGC.UGCGraphCompiler")

test("batch IDs can be reserved without mutating document", function()
    local doc = Document.New({documentId="doc-batch"})
    equal(doc:PeekGroupID(), "batch_1")
    equal(doc:PeekGroupID(), "batch_1")
    equal(doc.nextBatchID, 1)
    equal(doc:CreateGroup(doc:PeekGroupID()), "batch_1")
    equal(doc.nextBatchID, 2)
end)


test("document snapshot is detached and IDs remain stable", function()
    local doc = Document.New({documentId="doc-test"})
    local record = doc:MakeEntityRecord("Box", {1,2,3,0,0,0,1,1,1})
    check(doc:InsertEntity(record))
    equal(record.sceneID, 1)
    equal(record.entityId, "doc-test-entity-1")
    doc:SetProgram(record.programId, {nodes={{id="node_1"}}})
    local group = doc:CreateGroup()
    equal(group, "batch_1")
    check(doc:AddToGroup(group, record.sceneID))
    check(doc:AddToGroup(group, record.sceneID))
    equal(#doc.generatedGroups[group], 1, "group membership must be idempotent")

    local snapshot = doc:Snapshot()
    snapshot.entities[1].prefabName = "Mutated"
    snapshot.programs[record.programId].nodes[1].id = "changed"
    equal(doc:GetEntity(1).prefabName, "Box")
    equal(doc:GetProgram(record.programId).nodes[1].id, "node_1")

    local restored = Document.FromSnapshot(doc:Snapshot())
    equal(restored:GetEntity(1).entityId, record.entityId)
    equal(restored:AllocateSceneID(), 2)
    equal(restored:AllocateGroupID(), "batch_2")
end)

test("command bus undo and redo use dynamic inverses", function()
    local state = { value = 0 }
    local bus = Bus.New()
    bus:Register("Set", {
        execute = function(command)
            local previous = state.value
            state.value = command.value
            return Bus.Success("set", nil, {type="Set", value=previous})
        end,
    })
    check(bus:Execute({type="Set", value=10}).ok)
    equal(state.value, 10)
    check(bus:Undo().ok)
    equal(state.value, 0)
    check(bus:Redo().ok)
    equal(state.value, 10)
    check(bus:Undo().ok)
    equal(state.value, 0)
end)

test("composite command rolls back atomically", function()
    local state = { value = 0 }
    local bus = Bus.New()
    bus:Register("Add", {
        execute = function(command)
            state.value = state.value + command.amount
            return Bus.Success("add", nil, {type="Add", amount=-command.amount})
        end,
    })
    bus:Register("Fail", { execute = function() return Bus.Failure("expected", "boom") end })
    local result = bus:Execute({type="Composite", commands={
        {type="Add", amount=3}, {type="Add", amount=4}, {type="Fail"},
    }})
    check(not result.ok)
    equal(result.code, "composite_failed")
    equal(state.value, 0)
    check(not bus:CanUndo(), "failed composite must not enter history")
end)

test("composite undo and redo preserve transaction", function()
    local state = { value = 0 }
    local bus = Bus.New()
    bus:Register("Add", {
        execute = function(command)
            state.value = state.value + command.amount
            return Bus.Success("add", nil, {type="Add", amount=-command.amount})
        end,
    })
    check(bus:Execute({type="Composite", commands={{type="Add",amount=2},{type="Add",amount=5}}}).ok)
    equal(state.value, 7)
    check(bus:Undo().ok)
    equal(state.value, 0)
    check(bus:Redo().ok)
    equal(state.value, 7)
end)

test("graph compiler emits typed IR", function()
    local report = Compiler:Compile({nodes={
        {id="node_1", type="Event_OnGameStart", params={}},
        {id="node_2", type="Delay", params={seconds="0.25"}},
        {id="node_3", type="Print_Message", params={msg="ok"}},
    }, connections={
        {from_id="node_1",from_pin="exec_out",to_id="node_2",to_pin="exec_in"},
        {from_id="node_2",from_pin="exec_out",to_id="node_3",to_pin="exec_in"},
    }}, {programID="level_main"})
    check(report.ok, Compiler:FormatReport(report))
    equal(report.program.programID, "level_main")
    equal(report.program.instructions.node_2.opcode, "DELAY")
    equal(report.program.instructions.node_2.next.exec_out, "node_3")
end)

test("graph compiler rejects cycles even when unreachable", function()
    local report = Compiler:Compile({nodes={
        {id="event", type="Event_OnGameStart", params={}},
        {id="a", type="Print_Message", params={msg="a"}},
        {id="b", type="Print_Message", params={msg="b"}},
    }, connections={
        {from_id="a",from_pin="exec_out",to_id="b",to_pin="exec_in"},
        {from_id="b",from_pin="exec_out",to_id="a",to_pin="exec_in"},
    }})
    check(not report.ok)
    check(#report.errors > 0)
end)

test("graph compiler validates parameters and pins", function()
    local badParam = Compiler:Compile({nodes={
        {id="event", type="Event_OnGameStart", params={}},
        {id="delay", type="Delay", params={seconds="not-a-number"}},
    }, connections={{from_id="event",from_pin="exec_out",to_id="delay",to_pin="exec_in"}}})
    check(not badParam.ok)

    local badPin = Compiler:Compile({nodes={
        {id="event", type="Event_OnGameStart", params={}},
        {id="print", type="Print_Message", params={msg="x"}},
    }, connections={{from_id="event",from_pin="bad",to_id="print",to_pin="exec_in"}}})
    check(not badPin.ok)

    local unknownParam = Compiler:Compile({nodes={
        {id="event", type="Event_OnGameStart", params={unexpected="path"}},
    }, connections={}})
    check(not unknownParam.ok)
end)

if passed ~= total then
    error(string.format("%d/%d tests passed", passed, total))
end
print(string.format("ALL PASS %d/%d", passed, total))
