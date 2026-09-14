--[[
    run_viewmodel.lua

    T10：UI ViewModel 化 + 事件驱动刷新的回归测试。

    覆盖点：
      1. 通道语义：MarkDirty / IsDirty / ConsumeDirty / ClearDirty / DirtyChannels 相互隔离
      2. 订阅通知：按通道广播并带 payload；单个订阅抛异常不影响其它订阅
      3. 文档事件 → 通道映射：真实 SceneData 的 changed 事件驱动 wires / outline / inspector
      4. 视图弱引用：视图被回收后 GetView() 返回 nil，绑定它的订阅在下次广播时被剪掉
      5. Destruct：解掉 SceneData 监听、清空订阅、再调用返回 false，之后 MarkDirty 是空操作
      6. Unsubscribe：只摘掉指定订阅
      7. 接线守卫（源码级）：UE Widget 无法在纯 Lua 里实例化，所以用静态断言锁住
         「Tick 只在需要时重绘」「两个界面都有 Destruct 解绑」「EditorCore 通道标脏」这几条验收线

    说明：第 7 组是源码断言，不是运行时断言 —— 验收标准"Tick 只保留必要的输入采样"只能这样锁。
]]

local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

package.preload["Gameplay.UGC.UGCPrefabRegistry"] = function()
    return {
        IsValid = function(id) return id == "Box" end,
        GetPath = function(id) return id == "Box" and "/Game/Test/Box.Box_C" or nil end,
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

local ViewModel = require("Gameplay.UGC.UGCViewModel")
local SceneData = require("Gameplay.UGC.UGCSceneData")

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
local function readSource(relative)
    local handle = io.open(root .. "/" .. relative, "rb")
    if not handle then return nil end
    local content = handle:read("*a")
    handle:close()
    return content
end
local function mustContain(source, needle, what)
    check(source, "读不到源码: " .. tostring(what))
    check(source:find(needle, 1, true), (what or "") .. " 应当包含: " .. needle)
end
local function mustNotContain(source, needle, what)
    check(source, "读不到源码: " .. tostring(what))
    check(not source:find(needle, 1, true), (what or "") .. " 不应再包含: " .. needle)
end

--============================================================
-- 1-2. 通道语义与订阅
--============================================================

test("dirty channels are isolated and consumable", function()
    local vm = ViewModel.New("channels")
    check(not vm:IsDirty("wires"))

    vm:MarkDirty("wires")
    check(vm:IsDirty("wires"), "wires 应当为脏")
    check(not vm:IsDirty("inspector"), "未标脏的通道不应为脏")

    check(vm:ConsumeDirty("wires"), "取一次应当返回 true")
    check(not vm:ConsumeDirty("wires"), "取过之后应当为空")
    check(not vm:IsDirty("wires"))

    vm:MarkDirty("all")
    check(vm:IsDirty("wires") and vm:IsDirty("toolbar"), "all 应当覆盖所有通道")
    local channels = vm:DirtyChannels()
    equal(#channels, #ViewModel.CHANNELS, "all 展开后应当覆盖全部通道")
    vm:ClearDirty()
    check(not vm:IsDirty("wires"))
end)

test("subscribers are notified per channel and one failure cannot block others", function()
    local vm = ViewModel.New("subscribers")
    local calls = {}
    vm:Subscribe(function(channel, payload) calls[#calls + 1] = channel .. ":" .. tostring(payload and payload.kind) end)
    vm:Subscribe(function() error("订阅内部异常") end)          -- 必须被 pcall 吃掉
    local second = 0
    vm:Subscribe(function(channel) if channel == "inspector" then second = second + 1 end end)

    vm:MarkDirty("inspector", { kind = "entity_deleted" })
    equal(#calls, 1, "第一个订阅应当收到一次")
    equal(calls[1], "inspector:entity_deleted", "payload 应当透传")
    equal(second, 1, "异常订阅之后的订阅仍应被调用")

    local handle = vm:Subscribe(function() second = second + 100 end)
    vm:MarkDirty("inspector")
    equal(second, 102, "新订阅应当被调用")
    check(vm:Unsubscribe(handle))
    vm:MarkDirty("inspector")
    equal(second, 103, "解绑后的订阅不应再被调用（只加 1）")
    equal(vm:Unsubscribe(handle), false, "重复解绑返回 false")
end)

--============================================================
-- 3. 文档事件 → 通道
--============================================================

test("scene document events drive viewmodel channels", function()
    SceneData:Init(bridge)
    local vm = ViewModel.New("document_link")
    local before = SceneData:ListenerCount("changed")
    check(vm:AttachSceneData(SceneData), "AttachSceneData 应当成功")

    local received = {}
    vm:Subscribe(function(channel, payload) received[#received + 1] = channel end)

    local id = SceneData:CreateActorWithTransform("Box", transform(1))
    check(vm:IsDirty("wires"), "entity_created 应当标脏 wires")
    check(vm:IsDirty("outline"), "entity_created 应当标脏 outline")
    check(not vm:IsDirty("toolbar"), "entity_created 不应标脏 toolbar")
    check(#received >= 2, "订阅者应当收到 wires 与 outline")

    vm:ClearDirty()
    SceneData:ModifyActor(id, transform(5))
    check(vm:IsDirty("wires"), "transform_changed 应当标脏 wires")
    check(vm:IsDirty("inspector"), "transform_changed 应当标脏 inspector")

    vm:ClearDirty()
    check(SceneData:SetProperty(id, "mass", 3).ok)
    check(vm:IsDirty("inspector"), "entity_property_changed 应当标脏 inspector")

    vm:ClearDirty()
    SceneData:Undo()   -- 撤销属性写入 / Transform 都会走命令 → changed 事件
    check(vm:IsDirty("wires") or vm:IsDirty("inspector"), "撤销后界面也要被标脏")

    check(vm:Destruct())
    equal(SceneData:ListenerCount("changed"), before, "Destruct 必须解掉 SceneData 监听")
end)

test("destroyed viewmodel stops reacting to document events", function()
    SceneData:Init(bridge)
    local vm = ViewModel.New("destroyed")
    vm:AttachSceneData(SceneData)
    local calls = 0
    vm:Subscribe(function() calls = calls + 1 end)
    vm:Destruct()

    SceneData:CreateActorWithTransform("Box", transform(1))
    equal(calls, 0, "销毁后的 ViewModel 不应再回调")
    check(not vm:Destruct(), "重复 Destruct 返回 false")
    check(not vm:MarkDirty("wires"), "销毁后 MarkDirty 是空操作")
end)

--============================================================
-- 4-5. 弱引用与解绑
--============================================================

test("view references are weak and expired subscriptions are pruned", function()
    local vm = ViewModel.New("weak")
    local view = { name = "fake_widget" }
    vm:BindView(view)
    local calls = 0
    vm:Subscribe(function() calls = calls + 1 end)   -- 与 view 同生命周期的订阅
    equal(vm:SubscriberCount(), 1)

    vm:MarkDirty("wires")
    equal(calls, 1, "视图活着时订阅应当生效")
    check(vm:GetView() == view)

    view = nil
    collectgarbage("collect")
    collectgarbage("collect")
    check(vm:GetView() == nil, "视图被回收后 GetView 应当返回 nil")

    vm:ClearDirty()
    vm:MarkDirty("wires")
    equal(calls, 1, "视图被回收后订阅不应再被调用（即使 Destruct 没被调用）")
    equal(vm:SubscriberCount(), 0, "过期的订阅应当被剪掉")
end)

test("detach scene data unsubscribes without destroying the viewmodel", function()
    SceneData:Init(bridge)
    local vm = ViewModel.New("detach")
    vm:AttachSceneData(SceneData)
    local before = SceneData:ListenerCount("changed")
    check(vm:DetachSceneData())

    local after = SceneData:ListenerCount("changed")
    equal(after, before - 1, "DetachSceneData 应当摘掉一个监听")
    check(not vm:IsDestroyed(), "只是解绑，不应该销毁")

    SceneData:CreateActorWithTransform("Box", transform(1))
    check(not vm:IsDirty("wires"), "解绑后不再收文档事件")

    -- 再绑一次应当恢复
    vm:AttachSceneData(SceneData)
    SceneData:CreateActorWithTransform("Box", transform(2))
    check(vm:IsDirty("wires"), "重新绑定后应当恢复接收")
    vm:Destruct()
end)

--============================================================
-- 7. 接线守卫（源码级）
--============================================================

test("player controller tick only redraws wires when the view asks for it", function()
    local pc = readSource("Content/Script/Gameplay/UGC/UGCPlayerController.lua")
    mustContain(pc, "_bpEditor:NeedsWireRefresh()", "PC Tick")
    mustContain(pc, "_bpEditor:UpdateWires(x, y)", "PC Tick")
    mustContain(pc, "EditorCore:ReleaseViewModel()", "PC EndPlay")

    -- UpdateWires 只允许出现一次，且必须在 NeedsWireRefresh 守卫之后
    local firstCall = pc:find("_bpEditor:UpdateWires", 1, true)
    local secondCall = pc:find("_bpEditor:UpdateWires", firstCall + 1, true)
    check(firstCall and not secondCall, "Tick 里 UpdateWires 只应有一处调用点")
    local guard = pc:find("_bpEditor:NeedsWireRefresh", 1, true)
    check(guard and guard < firstCall, "UpdateWires 必须在 NeedsWireRefresh 之后")
    mustNotContain(pc, "EditorCore:OnSelectionChanged", "PC 注释/代码不应再依赖单槽回调")
end)

test("viewmodels are created by EditorCore and marked dirty on selection and state", function()
    local core = readSource("Content/Script/Gameplay/UGC/UGCEditorCore.lua")
    mustContain(core, "function EditorCore:GetViewModel()", "EditorCore")
    mustContain(core, "function EditorCore:ReleaseViewModel()", "EditorCore")
    mustContain(core, '_viewModel:MarkDirty("inspector"', "EditorCore")
    mustContain(core, '_viewModel:MarkDirty("toolbar"', "EditorCore")
    mustContain(core, "_viewModel:AttachSceneData(SceneData)", "EditorCore")
    mustContain(core, 'Log.Error("bridge_unavailable"', "EditorCore（原有错误码应保持）")
end)

test("both editor widgets bind the viewmodel in Construct and unbind in Destruct", function()
    local graph = readSource("Content/Script/System/UI/UGC/WBP_UGCBlueprintEditor.lua")
    mustContain(graph, "self:BindViewModel()", "蓝图编辑器 Construct")
    mustContain(graph, "function M:NeedsWireRefresh()", "蓝图编辑器")
    mustContain(graph, "function M:Destruct()", "蓝图编辑器")
    mustContain(graph, "_viewModel:Unsubscribe(_viewSubscription)", "蓝图编辑器 Destruct")
    mustContain(graph, "_viewModel:UnbindView()", "蓝图编辑器 Destruct")

    local panel = readSource("Content/Script/System/UI/UGC/WBP_UGCEditor.lua")
    mustContain(panel, "self:BindViewModel()", "编辑面板 Construct")
    mustContain(panel, "function M:Destruct()", "编辑面板")
    mustContain(panel, "_viewModel:Unsubscribe(_viewSubscription)", "编辑面板 Destruct")
    mustContain(panel, "_viewModel:UnbindView()", "编辑面板 Destruct")
    mustNotContain(panel, "EditorCore:OnSelectionChanged(", "编辑面板（改用 ViewModel 通道）")
    mustNotContain(panel, "EditorCore:OnStateChanged(", "编辑面板（改用 ViewModel 通道）")
end)

test("scene data exposes subscription teardown", function()
    SceneData:Init(bridge)
    local before = SceneData:ListenerCount("changed")
    local calls = 0
    local listener = function() calls = calls + 1 end
    SceneData:Subscribe("changed", listener)
    SceneData:Subscribe("changed", listener)   -- 同一函数注册两次
    equal(SceneData:ListenerCount("changed"), before + 2)

    check(SceneData:Unsubscribe("changed", listener))
    equal(SceneData:ListenerCount("changed"), before + 1, "Unsubscribe 一次只摘一个")
    equal(SceneData:UnsubscribeAll(listener), 1, "UnsubscribeAll 摘掉剩余引用")
    equal(SceneData:ListenerCount("changed"), before)
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
