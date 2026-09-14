--[[
    UGCGraphCompiler.lua

    Pure graph validator/compiler. It accepts the existing serialized graph
    format and emits immutable runtime instructions for UGCProgramRunner.
]]

local Schema = require("Gameplay.UGC.UGCGraphSchema")

local Compiler = {}
Compiler.__index = Compiler

local VALID_OPERATORS = { [">"]=true, [">="]=true, ["<"]=true, ["<="]=true, ["=="]=true, ["!="]=true }

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for k, v in pairs(value) do result[copy(k, seen)] = copy(v, seen) end
    return result
end

local function normalizeNodes(raw)
    local result = {}
    if type(raw) ~= "table" then return result end
    if #raw > 0 then
        for _, node in ipairs(raw) do result[#result + 1] = node end
    else
        for id, node in pairs(raw) do
            local item = copy(node)
            item.id = item.id or id
            result[#result + 1] = item
        end
    end
    for _, node in ipairs(result) do
        if node.id ~= nil then node.id = tostring(node.id) end
    end
    table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return result
end

local function add(report, kind, message, nodeId, pin)
    report[kind][#report[kind] + 1] = { message=message, nodeId=nodeId, pin=pin }
end

local function validateParam(report, node, paramDef, nodeMap)
    local value = (node.params or {})[paramDef.name]
    if paramDef.required and (value == nil or tostring(value) == "") then
        add(report, "errors", "缺少必填参数: " .. paramDef.name, node.id)
        return
    end
    if value == nil or tostring(value) == "" then return end

    if paramDef.type == "number" then
        local number = tonumber(value)
        if not number then
            add(report, "errors", "参数不是数字: " .. paramDef.name, node.id)
        elseif paramDef.min and number < paramDef.min then
            add(report, "errors", string.format("参数 %s 小于最小值 %s", paramDef.name, paramDef.min), node.id)
        end
    elseif paramDef.type == "node_ref" then
        local target = nodeMap[tostring(value)]
        if not target then
            add(report, "errors", "引用的节点不存在: " .. tostring(value), node.id)
        else
            local targetDef = Schema.Definitions[target.type]
            if not targetDef or targetDef.kind ~= "condition" then
                add(report, "errors", "引用节点不是条件节点: " .. tostring(value), node.id)
            end
        end
    elseif paramDef.type == "operator" and not VALID_OPERATORS[tostring(value)] then
        add(report, "errors", "不支持的比较运算符: " .. tostring(value), node.id)
    end
    if paramDef.enum then
        local allowed = false
        for _, candidate in ipairs(paramDef.enum) do
            if value == candidate then allowed = true; break end
        end
        if not allowed then add(report, "errors", "参数不在允许列表: " .. paramDef.name, node.id) end
    end
end

function Compiler:Compile(graphData, options)
    options = options or {}
    local report = { ok=false, errors={}, warnings={}, program=nil }
    if type(graphData) ~= "table" then
        add(report, "errors", "图数据为空或格式错误")
        return report
    end

    local nodes = normalizeNodes(graphData.nodes)
    if #nodes == 0 then
        add(report, "errors", "图为空")
        return report
    end
    local nodeMap = {}
    for _, node in ipairs(nodes) do
        if not node.id or tostring(node.id) == "" then
            add(report, "errors", "节点缺少 id")
        elseif nodeMap[node.id] then
            add(report, "errors", "节点 id 重复: " .. tostring(node.id), node.id)
        else
            nodeMap[node.id] = node
        end
    end

    local instructions = {}
    local events = {}
    local intervals = {}
    for _, node in ipairs(nodes) do
        local def = Schema.Definitions[node.type]
        if not def then
            add(report, "errors", "未知节点类型: " .. tostring(node.type), node.id)
        else
            local declaredParams = {}
            for _, paramDef in ipairs(def.params or {}) do
                declaredParams[paramDef.name] = true
                validateParam(report, node, paramDef, nodeMap)
            end
            for paramName in pairs(node.params or {}) do
                if not declaredParams[paramName] then
                    add(report, "errors", "未知参数: " .. tostring(paramName), node.id)
                end
            end
            instructions[node.id] = {
                id=node.id, type=node.type, opcode=def.opcode,
                params=copy(node.params or {}), next={},
            }
            if def.kind == "event" then
                events[node.type] = events[node.type] or {}
                events[node.type][#events[node.type] + 1] = node.id
                if node.type == "Event_OnInterval" then
                    intervals[#intervals + 1] = {
                        nodeId=node.id,
                        interval=math.max(0.01, tonumber((node.params or {}).interval) or 5.0),
                    }
                end
            end
        end
    end

    local execEdges = {}
    local inboundExec = {}
    for _, connection in ipairs(graphData.connections or {}) do
        local fromId = tostring(connection.from_id or "")
        local toId = tostring(connection.to_id or "")
        local from = nodeMap[fromId]
        local to = nodeMap[toId]
        local fromDef = from and Schema.Definitions[from.type] or nil
        local toDef = to and Schema.Definitions[to.type] or nil
        if not from then
            add(report, "errors", "连线起点不存在: " .. tostring(connection.from_id))
        elseif not to then
            add(report, "errors", "连线终点不存在: " .. tostring(connection.to_id))
        elseif not fromDef or not fromDef.outputs or not fromDef.outputs[connection.from_pin] then
            add(report, "errors", "无效输出引脚: " .. tostring(connection.from_pin), from.id, connection.from_pin)
        elseif not toDef or not toDef.inputs or not toDef.inputs[connection.to_pin] then
            add(report, "errors", "无效输入引脚: " .. tostring(connection.to_pin), to.id, connection.to_pin)
        elseif fromDef.outputs[connection.from_pin] ~= toDef.inputs[connection.to_pin] then
            add(report, "errors", "引脚类型不匹配", from.id, connection.from_pin)
        elseif instructions[from.id].next[connection.from_pin] then
            add(report, "errors", "同一执行输出只能连接一个目标", from.id, connection.from_pin)
        elseif inboundExec[to.id] then
            add(report, "errors", "执行输入只能连接一个来源", to.id, connection.to_pin)
        else
            instructions[from.id].next[connection.from_pin] = to.id
            execEdges[from.id] = execEdges[from.id] or {}
            execEdges[from.id][#execEdges[from.id] + 1] = to.id
            inboundExec[to.id] = from.id
        end
    end

    local eventCount = 0
    for _, ids in pairs(events) do eventCount = eventCount + #ids end
    if eventCount == 0 and #nodes > 0 then add(report, "errors", "图缺少事件入口") end

    local visiting, cycleChecked = {}, {}
    local function visit(id)
        if visiting[id] then
            add(report, "errors", "执行流存在循环", id)
            return
        end
        if cycleChecked[id] then return end
        visiting[id] = true
        for _, nextId in ipairs(execEdges[id] or {}) do visit(nextId) end
        visiting[id] = nil
        cycleChecked[id] = true
    end
    for id in pairs(instructions) do visit(id) end

    local reachable = {}
    local function markReachable(id)
        if reachable[id] then return end
        reachable[id] = true
        for _, nextId in ipairs(execEdges[id] or {}) do markReachable(nextId) end
    end
    for _, ids in pairs(events) do for _, id in ipairs(ids) do markReachable(id) end end

    for _, node in ipairs(nodes) do
        local def = Schema.Definitions[node.type]
        if def and def.kind ~= "condition" and not reachable[node.id] then
            add(report, "warnings", "节点无法从任何事件入口到达", node.id)
        end
    end

    report.ok = #report.errors == 0
    if report.ok then
        report.program = {
            version=1,
            programID=options.programID or graphData.programID,
            instructions=instructions,
            events=events,
            intervals=intervals,
        }
    end
    return report
end

function Compiler:FormatReport(report)
    if report.ok then
        if #report.warnings == 0 then return "验证成功" end
        return string.format("验证通过，%d 个警告：%s", #report.warnings, report.warnings[1].message)
    end
    return string.format("验证失败，%d 个错误：%s", #report.errors, report.errors[1] and report.errors[1].message or "未知错误")
end

return Compiler
