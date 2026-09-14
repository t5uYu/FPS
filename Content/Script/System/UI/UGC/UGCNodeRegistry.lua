--[[
    UGCNodeRegistry.lua
    UI adapter over the shared typed UGCGraphSchema.
]]

local Schema = require("Gameplay.UGC.UGCGraphSchema")
local R = { Definitions={}, Categories={} }

-- 颜色预设（与 UE 蓝图风格对齐）
local COLOR_EVENT  = {r=0.63, g=0.06, b=0.06}  -- 红
local COLOR_BRANCH = {r=0.06, g=0.44, b=0.19}  -- 绿
local COLOR_ACTION = {r=0.06, g=0.31, b=0.63}  -- 蓝

R.Definitions = {

    --============================================================
    -- 事件节点（入口，无 exec_in）
    --============================================================
    Event_OnEnter = {
        label    = "进入触发区",
        category = "事件",
        color    = COLOR_EVENT,
        exec_out = true,
        params   = {}
    },
    Event_OnExit = {
        label    = "离开触发区",
        category = "事件",
        color    = COLOR_EVENT,
        exec_out = true,
        params   = {}
    },
    Event_OnInterval = {
        label    = "定时触发",
        category = "事件",
        color    = COLOR_EVENT,
        exec_out = true,
        params   = {
            { name="interval", label="间隔(秒)", default="5" }
        }
    },
    Event_OnGameStart = {
        label    = "游戏开始",
        category = "事件",
        color    = COLOR_EVENT,
        exec_out = true,
        params   = {}
    },

    --============================================================
    -- 条件节点
    --============================================================
    Branch = {
        label         = "条件分支",
        category      = "条件",
        color         = COLOR_BRANCH,
        exec_in       = true,
        exec_out_true = true,
        exec_out_false= true,
        params        = {
            { name="condition_node", label="条件节点ID", default="" }
        }
    },
    Compare_Attribute = {
        label    = "比较属性",
        category = "条件",
        color    = COLOR_BRANCH,
        params   = {
            { name="attr",  label="属性名", default="Health" },
            { name="op",    label="运算符", default=">"      },
            { name="value", label="值",     default="0"      }
        }
    },
    Compare_GameRule = {
        label    = "比较规则",
        category = "条件",
        color    = COLOR_BRANCH,
        params   = {
            { name="rule",  label="规则名", default="RoundTime" },
            { name="op",    label="运算符", default=">"         },
            { name="value", label="值",     default="0"         }
        }
    },

    --============================================================
    -- 动作节点
    --============================================================
    Set_Attribute = {
        label    = "设置属性",
        category = "动作",
        color    = COLOR_ACTION,
        exec_in  = true,
        exec_out = true,
        params   = {
            { name="name",  label="属性名", default="Health" },
            { name="value", label="值",     default="100"    }
        }
    },
    Set_GameRule = {
        label    = "设置规则",
        category = "动作",
        color    = COLOR_ACTION,
        exec_in  = true,
        exec_out = true,
        params   = {
            { name="rule",  label="规则名", default="GravityScale" },
            { name="value", label="值",     default="1"            }
        }
    },
    Spawn_Weapon = {
        label    = "生成武器",
        category = "动作",
        visible  = false,
        color    = COLOR_ACTION,
        exec_in  = true,
        exec_out = true,
        params   = {
            { name="weapon_id", label="武器ID", default="AK47" },
            { name="x",         label="X",      default="0"    },
            { name="y",         label="Y",      default="0"    },
            { name="z",         label="Z",      default="100"  }
        }
    },
    Print_Message = {
        label    = "打印消息",
        category = "动作",
        color    = COLOR_ACTION,
        exec_in  = true,
        exec_out = true,
        params   = {
            { name="msg", label="消息", default="Hello!" }
        }
    },
    Delay = {
        label    = "延迟",
        category = "动作",
        color    = COLOR_ACTION,
        exec_in  = true,
        exec_out = true,
        params   = {
            { name="seconds", label="秒数", default="1" }
        }
    },
    PCG_Generate = {
        label    = "PCG生成",
        category = "动作",
        color    = COLOR_ACTION,
        exec_in  = true,
        exec_out = true,
        params   = {
            { name="x",          label="X",            default="0"    },
            { name="y",          label="Y",            default="0"    },
            { name="z",          label="Z",            default="0"    },
            { name="radius",     label="半径",         default="1000" },
            { name="seed",       label="种子",         default="0"    },
            { name="graph_path", label="Graph路径(选填)", default=""     },
        }
    },
    PCG_Clear = {
        label    = "PCG清除全部",
        category = "动作",
        color    = COLOR_ACTION,
        exec_in  = true,
        exec_out = true,
        params   = {}
    },
}

-- 按 category 分组，供侧边栏展示
R.Categories = {}
local _catMap = {}
for typeName, def in pairs(R.Definitions) do
    if def.visible ~= false then
        local cat = def.category
        if not _catMap[cat] then
            _catMap[cat] = { name = cat, items = {} }
            table.insert(R.Categories, _catMap[cat])
        end
        table.insert(_catMap[cat].items, { type = typeName, label = def.label })
    end
end

return R
