--[[
    run_logging.lua

    T13 结构化日志回归。覆盖：
      1. 单行格式：关键字段扁平可 grep，其余进 fields JSON，且键序无关（可 diff）
      2. 命令事件带 session / command / entity / program / code，失败降级为 error 级别
      3. ErrorCode 稳定性：源码里出现的每个字面量 code 都必须在 UGCLog.Codes 中登记
      4. 未登记 code 不会被静默写入日志（标记为 unregistered_code 并保留原值）
      5. 历史环形缓冲 / 订阅者 / 级别计数
      6. UGC 服务层不再有裸 print（唯一出口是 UGCLog）
]]

local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

local json = require("Util.json")
local Log = require("Gameplay.UGC.UGCLog")

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

local lines = {}
local function capture()
    lines = {}
    Log.SetSink(function(severity, event, fieldsJson, line)
        lines[#lines + 1] = {
            severity = severity, event = event, fieldsJson = fieldsJson,
            line = line, fields = json.decode(fieldsJson),
        }
    end)
end
local function last() return lines[#lines] end

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local content = handle:read("a")
    handle:close()
    return content
end

test("log line keeps flat fields and deterministic fields JSON", function()
    Log.Reset()
    local line = Log.FormatLine("info", "command", {
        command = "cmd_1", type = "CreateEntity", ok = true, code = "ok",
        nested = { b = 1, a = 2 },
    })
    check(line:find("event=command", 1, true), "event must be first: " .. line)
    check(line:find("severity=info", 1, true), "severity missing")
    check(line:find("command=cmd_1", 1, true), "commandId must stay flat")
    check(line:find("type=CreateEntity", 1, true), "command type must stay flat")
    check(line:find("code=ok", 1, true), "code must stay flat")
    check(line:find('fields={"nested"', 1, true), "extra fields must go to fields JSON: " .. line)
    check(not line:find('fields={"command"', 1, true), "flat keys must not be duplicated in fields JSON")

    -- 字段插入顺序不影响输出（存档/日志都可复现）
    local a = Log.FormatLine("info", "x", { p = 1, q = 2 })
    local b = Log.FormatLine("info", "x", { q = 2, p = 1 })
    equal(a, b, "field order must not change the line")
end)

test("command events carry session, command, entity, program and code", function()
    Log.Reset()
    capture()
    Log.SetContext({ document = "doc-1" })
    local session = Log.NewSession("test")
    check(session and session ~= "", "session id required")

    Log.Command(
        { type = "SetTransform", sceneID = 7, programId = "actor_prog_7" },
        { commandId = "cmd_9", source = "local" },
        { ok = true, code = "ok", message = "Transform 已更新" })

    local entry = last()
    equal(entry.event, "command", "event name")
    equal(entry.severity, "info", "success must log at info")
    equal(entry.fields.session, session, "SessionId")
    equal(entry.fields.document, "doc-1", "document context")
    equal(entry.fields.command, "cmd_9", "CommandId")
    equal(entry.fields.entity, 7, "EntityId")
    equal(entry.fields.program, "actor_prog_7", "ProgramId")
    equal(entry.fields.code, "ok", "code")
    check(entry.line:find("session=" .. session, 1, true), "session must be greppable: " .. entry.line)
    check(entry.line:find("entity=7", 1, true), "entity must be greppable")
end)

test("failed commands log with their stable error code at error level", function()
    Log.Reset()
    capture()
    Log.NewSession("test")
    Log.Command(
        { type = "DeleteEntity", sceneID = 3 },
        { commandId = "cmd_1", source = "ai" },
        { ok = false, code = "revision_conflict", message = "文档版本冲突" })

    local entry = last()
    equal(entry.severity, "error", "failures must log at error level")
    equal(entry.fields.code, "revision_conflict", "stable error code")
    equal(entry.fields.ok, false, "ok flag")
    equal(entry.fields.type, "DeleteEntity", "command type")
end)

test("unregistered error codes are flagged instead of silently logged", function()
    Log.Reset()
    capture()
    Log.Error("definitely_not_registered", "boom")
    local flagged = last()
    equal(flagged.fields.code, "unregistered_code", "unknown codes must be flagged")
    equal(flagged.fields.unregisteredCode, "definitely_not_registered", "raw value must survive")
    equal(flagged.severity, "error", "still an error line")

    Log.Reset()
    capture()
    Log.Error("save_failed", "disk full", { path = "Saved/UGC/a.ugc.json" })
    local known = last()
    equal(known.fields.code, "save_failed", "registered code passes through")
    equal(known.fields.path, "Saved/UGC/a.ugc.json", "extra fields survive")
end)

test("every literal error code in Content/Script is registered", function()
    local files = {}
    local handle = io.popen('dir /b /s "' .. root .. '\\Content\\Script\\*.lua" 2>nul')
    if handle then
        for path in handle:lines() do files[#files + 1] = path end
        handle:close()
    end
    check(#files > 0, "no Lua sources enumerated")

    local patterns = {
        "[Ff]ailure%s*%(%s*\"([a-z_]+)\"",
        "code%s*=%s*\"([a-z_]+)\"",
        "UGCLog%.Error%(%s*\"([a-z_]+)\"",
    }
    local missing, seen = {}, {}
    for _, path in ipairs(files) do
        local content = readFile(path)
        if content then
            for _, pattern in ipairs(patterns) do
                for code in content:gmatch(pattern) do
                    seen[code] = path
                    if not Log.Codes[code] then missing[code] = path end
                end
            end
        end
    end
    check(next(seen) ~= nil, "code scan found nothing, patterns are stale")
    check(next(missing) == nil,
        "unregistered codes: " .. json.encode(missing))
    -- 关键错误码必须仍然存在，否则说明错误路径被改坏
    for _, code in ipairs({ "revision_conflict", "rollback_failed", "spawn_failed", "save_failed", "load_failed" }) do
        check(Log.Codes[code], "code table is missing " .. code)
    end
end)

test("history, subscribers and severity counters", function()
    Log.Reset()
    capture()
    local observed = 0
    Log.Subscribe(function() observed = observed + 1 end)
    Log.Info("a")
    Log.Warn("b")
    Log.Error("action_failed", "c")
    equal(observed, 3, "subscriber sees every line")

    local history = Log.History(2)
    equal(#history, 2, "history size")
    check(history[2]:find("event=error", 1, true), "history is chronological: " .. tostring(history[2]))

    local counts = Log.Counts()
    equal(counts.info, 1, "info count")
    equal(counts.warning, 1, "warning count")
    equal(counts.error, 1, "error count")

    local big = Log.History(1e6)
    check(#big <= Log.MAX_HISTORY, "history must stay bounded")
end)

test("UGC service layer has no bare print left", function()
    local files = {
        "UGCCommandBus.lua", "UGCSceneData.lua", "UGCPersistence.lua", "UGCFunctionRegistry.lua",
        "LLMGateway.lua", "UGCEditorCore.lua", "UGCProgramRunner.lua", "UGCPrefabRegistry.lua",
        "UGCPlayerController.lua", "Generators/Init.lua",
    }
    for _, name in ipairs(files) do
        local path = root .. "/Content/Script/Gameplay/UGC/" .. name
        local content = readFile(path)
        check(content, "missing source: " .. name)
        local found = content:match("[^%w_.:]print%s*%(")
        check(found == nil, name .. " still calls print(); route it through UGCLog")
    end
end)

Log.Reset()

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))