--[[
    UGCGraphSchema.lua

    Shared typed node schema. Both the UI node palette and the runtime compiler
    consume this module so display metadata and execution rules cannot drift.
]]

local Policy = require("Gameplay.UGC.UGCCapabilityPolicy")
local S = {}

S.Definitions = {
    Event_OnEnter = {
        label="进入触发区", category="事件", kind="event", opcode="EVENT",
        outputs={ exec_out="exec" }, params={}
    },
    Event_OnExit = {
        label="离开触发区", category="事件", kind="event", opcode="EVENT",
        outputs={ exec_out="exec" }, params={}
    },
    Event_OnInterval = {
        label="定时触发", category="事件", kind="event", opcode="EVENT",
        outputs={ exec_out="exec" },
        params={ {name="interval", label="间隔(秒)", type="number", default="5", min=0.01, required=true} }
    },
    Event_OnGameStart = {
        label="游戏开始", category="事件", kind="event", opcode="EVENT",
        outputs={ exec_out="exec" }, params={}
    },
    Branch = {
        label="条件分支", category="条件", kind="control", opcode="BRANCH",
        inputs={ exec_in="exec" }, outputs={ exec_out_true="exec", exec_out_false="exec" },
        params={ {name="condition_node", label="条件节点ID", type="node_ref", default="", required=true} }
    },
    Compare_Attribute = {
        label="比较属性", category="条件", kind="condition", opcode="COMPARE_ATTRIBUTE",
        params={
            {name="attr", label="属性名", type="string", default="Health", enum=Policy.Attributes, required=true},
            {name="op", label="运算符", type="operator", default=">", required=true},
            {name="value", label="值", type="number", default="0", required=true},
        }
    },
    Compare_GameRule = {
        label="比较规则", category="条件", kind="condition", opcode="COMPARE_RULE",
        params={
            {name="rule", label="规则名", type="string", default="RoundTime", enum=Policy.Rules, required=true},
            {name="op", label="运算符", type="operator", default=">", required=true},
            {name="value", label="值", type="number", default="0", required=true},
        }
    },
    Set_Attribute = {
        label="设置属性", category="动作", kind="action", opcode="SET_ATTRIBUTE",
        inputs={exec_in="exec"}, outputs={exec_out="exec"},
        params={
            {name="name", label="属性名", type="string", default="Health", enum=Policy.Attributes, required=true},
            {name="value", label="值", type="number", default="100", required=true},
        }
    },
    Set_GameRule = {
        label="设置规则", category="动作", kind="action", opcode="SET_RULE",
        inputs={exec_in="exec"}, outputs={exec_out="exec"},
        params={
            {name="rule", label="规则名", type="string", default="GravityScale", enum=Policy.Rules, required=true},
            {name="value", label="值", type="number", default="1", required=true},
        }
    },
    Spawn_Weapon = {
        label="生成武器", category="动作", kind="action", opcode="SPAWN_WEAPON",
        inputs={exec_in="exec"}, outputs={exec_out="exec"},
        params={
            {name="weapon_id", label="武器ID", type="string", default="WPN_Rifle_AK47", enum=Policy.Weapons, required=true},
            {name="x", label="X", type="number", default="0", required=true},
            {name="y", label="Y", type="number", default="0", required=true},
            {name="z", label="Z", type="number", default="100", required=false},
        }
    },
    Print_Message = {
        label="打印消息", category="动作", kind="action", opcode="PRINT",
        inputs={exec_in="exec"}, outputs={exec_out="exec"},
        params={ {name="msg", label="消息", type="string", default="Hello!", required=true} }
    },
    Delay = {
        label="延迟", category="动作", kind="action", opcode="DELAY",
        inputs={exec_in="exec"}, outputs={exec_out="exec"},
        params={ {name="seconds", label="秒数", type="number", default="1", min=0, required=true} }
    },
    PCG_Generate = {
        label="PCG生成", category="动作", kind="action", opcode="PCG_GENERATE",
        inputs={exec_in="exec"}, outputs={exec_out="exec"},
        params={
            {name="x", label="X", type="number", default="0", required=true},
            {name="y", label="Y", type="number", default="0", required=true},
            {name="z", label="Z", type="number", default="0", required=false},
            {name="radius", label="半径", type="number", default="1000", min=0, required=false},
            {name="seed", label="种子", type="number", default="0", required=false},
            -- Legacy field retained for old graphs, but the only allowed value is empty.
            {name="graph_path", label="Graph路径(固定默认)", type="string", default="", enum=Policy.PCGGraphPaths, required=false},
        }
    },
    PCG_Clear = {
        label="PCG清除全部", category="动作", kind="action", opcode="PCG_CLEAR",
        inputs={exec_in="exec"}, outputs={exec_out="exec"}, params={}
    },
}

return S
