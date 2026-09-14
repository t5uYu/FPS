--[[
    UGCCommandBus.lua

    Unified mutation boundary for UGC. Commands are plain Lua tables and may be
    submitted by UI, AI, graph scripts, or a future network transport.
]]

local Bus = {}
Bus.__index = Bus

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for k, v in pairs(value) do
        result[copy(k, seen)] = copy(v, seen)
    end
    return result
end

local function failure(code, message, data)
    return { ok = false, code = code or "command_failed", message = message or "命令执行失败", data = data }
end

local function success(message, data, inverse)
    return { ok = true, code = "ok", message = message or "ok", data = data, inverse = inverse }
end

function Bus.New(options)
    options = options or {}
    return setmetatable({
        handlers = {},
        undoStack = {},
        redoStack = {},
        listeners = {},
        historyLimit = tonumber(options.historyLimit) or 64,
        sequence = 0,
    }, Bus)
end

function Bus:Register(commandType, handler)
    assert(type(commandType) == "string" and commandType ~= "", "command type required")
    assert(type(handler) == "table" and type(handler.execute) == "function", "handler.execute required")
    self.handlers[commandType] = handler
end

function Bus:Subscribe(listener)
    if type(listener) == "function" then self.listeners[#self.listeners + 1] = listener end
end

function Bus:_emit(event)
    for _, listener in ipairs(self.listeners) do
        local ok, err = pcall(listener, event)
        if not ok then print("[UGCCommandBus] listener error: " .. tostring(err)) end
    end
end

function Bus:_pushUndo(entry)
    self.undoStack[#self.undoStack + 1] = entry
    while #self.undoStack > self.historyLimit do table.remove(self.undoStack, 1) end
    self.redoStack = {}
end

function Bus:_executeOne(command, context, options)
    local handler = self.handlers[command.type]
    if not handler then return failure("unknown_command", "未知命令: " .. tostring(command.type)) end

    if handler.validate then
        local valid, err = handler.validate(command, context)
        if not valid then return failure("validation_failed", err or "命令校验失败") end
    end

    local ok, result = pcall(handler.execute, command, context)
    if not ok then return failure("exception", tostring(result)) end
    if type(result) ~= "table" then return failure("invalid_result", "命令处理器返回格式错误") end
    if result.ok == nil then result.ok = false end

    if result.ok and options.recordHistory ~= false and result.inverse then
        self:_pushUndo({ forward = copy(command), inverse = copy(result.inverse) })
    end
    return result
end

function Bus:_executeComposite(command, context, options)
    local results = {}
    local inverses = {}
    for index, child in ipairs(command.commands or {}) do
        local result = self:Execute(child, context, { recordHistory = false, emit = false })
        results[#results + 1] = result
        if not result.ok then
            local rollbackErrors = {}
            for i = #inverses, 1, -1 do
                local rollbackResult = self:Execute(inverses[i], context, { recordHistory = false, emit = false })
                if not rollbackResult.ok then
                    rollbackErrors[#rollbackErrors + 1] = rollbackResult
                end
            end
            if #rollbackErrors > 0 then
                return failure(
                    "rollback_failed",
                    string.format("组合命令第 %d 步失败，且有 %d 个回滚步骤失败", index, #rollbackErrors),
                    { results = results, rollbackErrors = rollbackErrors })
            end
            return failure("composite_failed", string.format("组合命令第 %d 步失败: %s", index, result.message), results)
        end
        if result.inverse then inverses[#inverses + 1] = result.inverse end
    end

    local inverseCommands = {}
    for i = #inverses, 1, -1 do inverseCommands[#inverseCommands + 1] = inverses[i] end
    local result = success(command.label or "组合命令完成", results, {
        type = "Composite",
        label = "Undo " .. tostring(command.label or "Composite"),
        commands = inverseCommands,
    })
    if options.recordHistory ~= false and #inverseCommands > 0 then
        self:_pushUndo({ forward = copy(command), inverse = copy(result.inverse) })
    end
    return result
end

function Bus:Execute(command, context, options)
    context = copy(context or { source = "local" })
    options = options or {}
    if type(command) ~= "table" or type(command.type) ~= "string" then
        return failure("invalid_command", "命令必须是带 type 的 table")
    end

    self.sequence = self.sequence + 1
    context.commandSequence = self.sequence
    context.commandId = context.commandId or ("cmd_" .. tostring(self.sequence))
    local result
    if command.type == "Composite" then
        result = self:_executeComposite(command, context, options)
    else
        result = self:_executeOne(command, context, options)
    end

    if options.emit ~= false then
        print(string.format(
            "[UGCCommand] id=%s source=%s type=%s ok=%s code=%s",
            tostring(context.commandId), tostring(context.source), tostring(command.type),
            tostring(result.ok), tostring(result.code)))
        self:_emit({ command = command, context = context, result = result })
    end
    return result
end

function Bus:Undo(context)
    local entry = table.remove(self.undoStack)
    if not entry then return failure("nothing_to_undo", "没有可撤销操作") end
    local result = self:Execute(entry.inverse, context or { source = "undo", approved = true }, { recordHistory = false })
    if result.ok then
        self.redoStack[#self.redoStack + 1] = {
            forward = copy(result.inverse or entry.forward),
            inverse = copy(entry.inverse),
        }
    else
        self.undoStack[#self.undoStack + 1] = entry
    end
    return result
end

function Bus:Redo(context)
    local entry = table.remove(self.redoStack)
    if not entry then return failure("nothing_to_redo", "没有可重做操作") end
    local result = self:Execute(entry.forward, context or { source = "redo", approved = true }, { recordHistory = false })
    if result.ok then
        self.undoStack[#self.undoStack + 1] = {
            forward = copy(entry.forward),
            inverse = copy(result.inverse or entry.inverse),
        }
    else
        self.redoStack[#self.redoStack + 1] = entry
    end
    return result
end

function Bus:CanUndo() return #self.undoStack > 0 end
function Bus:CanRedo() return #self.redoStack > 0 end
function Bus:ClearHistory() self.undoStack = {}; self.redoStack = {} end
function Bus.Success(message, data, inverse) return success(message, data, inverse) end
function Bus.Failure(code, message, data) return failure(code, message, data) end

return Bus
