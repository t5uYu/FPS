--[[
    UGCProgramRunner.lua

    Executes compiled UGC graph programs. Graph validation/normalization lives
    in UGCGraphCompiler; this module owns runtime tasks and real-time scheduling.
]]

local Registry = require("Gameplay.UGC.UGCFunctionRegistry")
local SceneData = require("Gameplay.UGC.UGCSceneData")
local Compiler = require("Gameplay.UGC.UGCGraphCompiler")
local UGCLog = require("Gameplay.UGC.UGCLog")

local Runner = {}
Runner.__index = Runner

local _pc = nil
local _initialized = false
local _compiled = {}
local _intervals = {}
local _delayedTasks = {}
local _nextTaskId = 1

local MAX_STEPS_PER_RUN = 128
local MAX_TASKS_PER_TICK = 64
-- 运行期日志统一走 UGCLog（program 字段是排障主键，见 logProgram）
local _activeProgram = nil

local function logProgram(fields)
    local payload = fields or {}
    payload.program = payload.program or _activeProgram
    return payload
end
local function commandContext(programID, nodeID)
    return { source="script", approved=true, programId=programID, nodeId=nodeID }
end

function Runner:Init(playerController)
    _pc = playerController
    _initialized = true
    _compiled = {}
    _intervals = {}
    _delayedTasks = {}
    _nextTaskId = 1
    SceneData:Subscribe("changed", function(event)
        if event and event.kind == "program_changed" then
            Runner:InvalidateProgram(event.programId)
        elseif event and (event.kind == "document_loaded" or event.kind == "document_cleared") then
            _compiled = {}
            _intervals = {}
            _delayedTasks = {}
        end
    end)
    UGCLog.Info("runner_initialized", { maxStepsPerRun = MAX_STEPS_PER_RUN, maxTasksPerTick = MAX_TASKS_PER_TICK })
end

function Runner:InvalidateProgram(programID)
    _compiled[programID] = nil
    for i = #_intervals, 1, -1 do
        if _intervals[i].programID == programID then table.remove(_intervals, i) end
    end
    for i = #_delayedTasks, 1, -1 do
        if _delayedTasks[i].metadata.programID == programID then
            table.remove(_delayedTasks, i)
        end
    end
end

function Runner:CompileProgram(programID)
    local graphData = SceneData:GetScript(programID)
    if not graphData then return false, "程序不存在: " .. tostring(programID) end
    local report = Compiler:Compile(graphData, { programID = programID })
    if not report.ok then
        return false, Compiler:FormatReport(report), report
    end
    _compiled[programID] = {
        revision = SceneData:GetRevision(),
        program = report.program,
        report = report,
    }
    self:RegisterIntervals(programID, report.program)
    return true, Compiler:FormatReport(report), report
end

function Runner:GetCompiledProgram(programID)
    local cached = _compiled[programID]
    if cached then return cached.program end
    local ok = self:CompileProgram(programID)
    return ok and _compiled[programID].program or nil
end

function Runner:ValidateProgram(programID)
    local graphData = SceneData:GetScript(programID)
    if not graphData then return { ok=false, errors={{message="程序不存在"}}, warnings={} } end
    return Compiler:Compile(graphData, { programID = programID })
end

function Runner:RunProgram(programID, eventType, context)
    if not _initialized then UGCLog.Error("not_initialized", "ProgramRunner 未初始化"); return false end
    local program = self:GetCompiledProgram(programID)
    if not program then UGCLog.Error("compilation_failed", "图程序编译失败", { program = programID }); return false end
    local entries = program.events[eventType] or {}
    for _, eventNodeId in ipairs(entries) do
        self:_executeFrom(programID, program, eventNodeId, "exec_out", context or {}, 0)
    end
    return #entries > 0
end

function Runner:TriggerGameStart()
    self:CompileAllPrograms()
    self:RunProgram("level_main", "Event_OnGameStart")
end

function Runner:CompileAllPrograms()
    _intervals = {}
    for programID in pairs(SceneData:GetAllScripts()) do self:CompileProgram(programID) end
end

function Runner:RegisterIntervals(programID, program)
    for i = #_intervals, 1, -1 do
        if _intervals[i].programID == programID then table.remove(_intervals, i) end
    end
    program = program or self:GetCompiledProgram(programID)
    if not program then return end
    for _, interval in ipairs(program.intervals or {}) do
        _intervals[#_intervals + 1] = {
            programID=programID,
            nodeID=interval.nodeId,
            interval=interval.interval,
            accumulated=0,
        }
    end
end

function Runner:ClearIntervals() _intervals = {} end
function Runner:CancelAllTasks() _delayedTasks = {}; _intervals = {} end

function Runner:_schedule(seconds, callback, metadata)
    local id = _nextTaskId
    _nextTaskId = _nextTaskId + 1
    _delayedTasks[#_delayedTasks + 1] = {
        id=id, remaining=math.max(0, tonumber(seconds) or 0),
        callback=callback, metadata=metadata or {}, cancelled=false,
    }
    return id
end

function Runner:CancelTask(taskId)
    for _, task in ipairs(_delayedTasks) do
        if task.id == taskId then task.cancelled = true; return true end
    end
    return false
end

function Runner:Tick(deltaTime)
    if not _initialized then return end
    local executed = 0
    for _, interval in ipairs(_intervals) do
        interval.accumulated = interval.accumulated + deltaTime
        while interval.accumulated >= interval.interval and executed < MAX_TASKS_PER_TICK do
            interval.accumulated = interval.accumulated - interval.interval
            local program = self:GetCompiledProgram(interval.programID)
            if program then
                self:_executeFrom(interval.programID, program, interval.nodeID, "exec_out", {}, 0)
                executed = executed + 1
            else
                break
            end
        end
    end

    for i = #_delayedTasks, 1, -1 do
        local task = _delayedTasks[i]
        task.remaining = task.remaining - deltaTime
        if task.cancelled then
            table.remove(_delayedTasks, i)
        elseif task.remaining <= 0 and executed < MAX_TASKS_PER_TICK then
            table.remove(_delayedTasks, i)
            executed = executed + 1
            local ok, err = pcall(task.callback)
            if not ok then UGCLog.Error("exception", err, logProgram({ task = task.nodeID, program = task.programID })) end
        end
    end
end

function Runner:_executeFrom(programID, program, fromID, fromPin, context, steps)
    _activeProgram = programID
    if steps >= MAX_STEPS_PER_RUN then
        UGCLog.Error("budget_exhausted", "单帧执行步数超预算", logProgram({ steps = MAX_STEPS_PER_RUN })); return
    end
    local instruction = program.instructions[fromID]
    local nextID = instruction and instruction.next[fromPin]
    if nextID then self:_executeInstruction(programID, program, nextID, context, steps + 1) end
end

function Runner:_executeInstruction(programID, program, nodeID, context, steps)
    _activeProgram = programID
    local instruction = program.instructions[nodeID]
    if not instruction then UGCLog.Error("unknown_instruction", "指令节点不存在", logProgram({ node = nodeID })); return end
    local p = instruction.params or {}
    local opcode = instruction.opcode
    local ctx = commandContext(programID, nodeID)
    local function callAndContinue(name, params)
        local ok, result = Registry:Call(name, params, ctx)
        if not ok then
            UGCLog.Error("node_failed", result, logProgram({ node = nodeID, func = name }))
            return false
        end
        self:_executeFrom(programID, program, nodeID, "exec_out", context, steps)
        return true
    end

    if opcode == "SET_ATTRIBUTE" then
        callAndContinue("set_attribute", {attribute=tostring(p.name or ""), value=tonumber(p.value) or 0})
    elseif opcode == "SET_RULE" then
        callAndContinue("set_rule", {rule=tostring(p.rule or ""), value=tonumber(p.value) or 0})
    elseif opcode == "SPAWN_WEAPON" then
        callAndContinue("spawn_weapon", {weapon_id=tostring(p.weapon_id or ""), x=tonumber(p.x) or 0, y=tonumber(p.y) or 0, z=tonumber(p.z) or 100})
    elseif opcode == "PCG_GENERATE" then
        callAndContinue("pcg_generate", {x=tonumber(p.x) or 0, y=tonumber(p.y) or 0, z=tonumber(p.z) or 0, radius=tonumber(p.radius) or 1000, seed=tonumber(p.seed) or 0})
    elseif opcode == "PCG_CLEAR" then
        callAndContinue("pcg_clear", {})
    elseif opcode == "PRINT" then
        local message = tostring(p.msg or "")
        UGCLog.Info("program_print", logProgram({ node = nodeID, message = message }))
        if _pc then pcall(UE.UKismetSystemLibrary.PrintString, _pc, message, true, true, UE.FLinearColor(0.1, 0.9, 1.0, 1.0), 5.0) end
        self:_executeFrom(programID, program, nodeID, "exec_out", context, steps)
    elseif opcode == "BRANCH" then
        local result = self:_evalCondition(program, tostring(p.condition_node or ""), ctx)
        self:_executeFrom(programID, program, nodeID, result and "exec_out_true" or "exec_out_false", context, steps)
    elseif opcode == "DELAY" then
        local seconds = math.max(0, tonumber(p.seconds) or 0)
        self:_schedule(seconds, function()
            self:_executeFrom(programID, program, nodeID, "exec_out", context, steps)
        end, {programID=programID, nodeID=nodeID})
    else
        UGCLog.Error("unsupported_opcode", "不支持的 opcode", logProgram({ opcode = tostring(opcode) }))
    end
end

function Runner:_evalCondition(program, nodeID, context)
    local instruction = program.instructions[nodeID]
    if not instruction then return false end
    local p = instruction.params or {}
    local lhs, ok
    if instruction.opcode == "COMPARE_ATTRIBUTE" then
        ok, lhs = Registry:Call("get_attribute", {attribute=tostring(p.attr or "")}, context)
    elseif instruction.opcode == "COMPARE_RULE" then
        ok, lhs = Registry:Call("get_rule", {rule=tostring(p.rule or "")}, context)
    else
        return false
    end
    if not ok then return false end
    local rhs = tonumber(p.value) or 0
    lhs = tonumber(lhs) or 0
    local op = tostring(p.op or ">")
    if op == ">" then return lhs > rhs end
    if op == ">=" then return lhs >= rhs end
    if op == "<" then return lhs < rhs end
    if op == "<=" then return lhs <= rhs end
    if op == "==" then return lhs == rhs end
    if op == "!=" then return lhs ~= rhs end
    return false
end

return Runner
