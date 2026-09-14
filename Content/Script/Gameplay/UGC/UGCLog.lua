--[[
    UGCLog.lua

    UGC 结构化日志：整个 UGC 服务层的唯一日志出口。

    约定：
    - 一条日志一行，关键字段扁平可 grep：`event=... severity=... session=... command=... code=...`
    - 其余字段进 `fields={...}`（经 Util.json 编码，键序稳定，可被日志工具直接解析）
    - 失败路径必须使用 Log.Codes 中已登记的稳定 ErrorCode；未登记的 code 会被标记为
      `code=unregistered_code` 并把原值放进 fields，避免日志出现"野生"错误码
    - Sink 可替换：UE 运行时优先走 UUGCLog（独立 LogFPSUGC category）；
      编辑器外/单测里退回 print（UnLua 会把 print 转发到 LogUnLua category）

    用法：
        local Log = require("Gameplay.UGC.UGCLog")
        Log.Info("scene_loaded", { document = docId, entities = 12 })
        Log.Error("save_failed", "UGCStorageBridge 原子写入失败", { path = path })
]]

local json = require("Util.json")

local Log = {}

--- 日志级别（唯一真源，sink 与测试都以此为准）
Log.Severity = { debug = "debug", info = "info", warning = "warning", error = "error" }

--- 稳定 ErrorCode 表：所有失败路径必须在此登记。
--- Tools/UGCTests/run_logging.lua 会扫描 Content/Script，出现未登记 code 直接失败。
Log.Codes = {
    ok                        = "成功",
    invalid_command           = "命令不是带 type 的 table",
    unknown_command           = "没有注册该命令类型的处理器",
    validation_failed         = "命令校验失败",
    invalid_result            = "命令处理器返回格式错误",
    exception                 = "命令处理器抛出异常",
    composite_failed          = "组合命令中途失败（已回滚）",
    rollback_failed           = "组合命令失败且回滚不完整",
    revision_conflict         = "提交命令的 baseRevision 已过期",
    not_initialized           = "UGC 服务未初始化",
    duplicate_entity          = "sceneID 冲突",
    spawn_failed              = "Actor 生成失败",
    restore_failed            = "实体恢复失败",
    projection_failed         = "Actor 投影操作失败",
    external_cleanup_failed   = "外部实体清理失败",
    invalid_rule              = "未知世界规则",
    rule_apply_failed         = "世界规则应用失败",
    nothing_to_undo           = "没有可撤销操作",
    nothing_to_redo           = "没有可重做操作",
    cancelled                 = "操作被取消",
    save_failed               = "存档写入失败",
    load_failed               = "存档读取失败",
    migration_failed          = "文档迁移链执行失败",
    recovery_failed           = "主文件与所有备份都不可用",
    storage_unavailable       = "存储桥未初始化",
    serialization_failed      = "序列化自检失败",
    legacy_load_failed        = "旧格式存档加载失败",
    unsupported_package       = "不支持的存档 packageVersion",
    invalid_project_file      = "所选文件不是有效的 UGC 项目文件",
    unknown_prefab            = "未知预制体",
    compilation_failed        = "图程序编译失败",
    budget_exhausted          = "图程序单帧执行步数超预算",
    unknown_instruction       = "图程序引用了不存在的指令节点",
    node_failed               = "图程序节点执行失败",
    unsupported_opcode        = "图程序出现不支持的 opcode",
    bridge_unavailable        = "UGC EditorBridge 不可用",
    playtest_unavailable      = "试玩 Pawn 未配置或当前实例无 Authority",
    listener_error            = "事件监听器抛出异常",
    registry_error            = "注册表执行失败",
    action_failed             = "动作执行失败",
    unregistered_code         = "出现未登记的 ErrorCode（见 UGCLog.Codes）",
}

-- 扁平输出的字段（顺序固定，便于 grep；其余进 fields JSON）
local FLAT_KEYS = { "session", "seq", "document", "command", "source", "type", "ok", "code", "program", "entity" }
local FLAT_SET = {}
for _, key in ipairs(FLAT_KEYS) do FLAT_SET[key] = true end

local MAX_HISTORY = 128

local _session = nil
local _sessionCounter = 0
local _context = {}
local _sink = nil
local _history = {}
local _historyCount = 0
local _subscribers = {}
local _sequence = 0
local _counts = { debug = 0, info = 0, warning = 0, error = 0 }
local _ueSink = nil
local _ueSinkProbed = false

--============================================================
-- 内部工具
--============================================================

local function osTime()
    return (os.time and os.time()) or 0
end

local function newSessionId()
    _sessionCounter = _sessionCounter + 1
    return string.format("ugc-%x-%04x", osTime(), _sessionCounter)
end

local function pushHistory(line)
    _historyCount = _historyCount + 1
    local slot = ((_historyCount - 1) % MAX_HISTORY) + 1
    _history[slot] = line
    if _historyCount > MAX_HISTORY then _history.first = (_historyCount - MAX_HISTORY) % MAX_HISTORY + 1 end
    return line
end

--- UE 侧 sink（UUGCLog → LogFPSUGC category）；不可用时返回 nil
local function ueSink()
    if _ueSink then return _ueSink end
    if _ueSinkProbed then return nil end
    _ueSinkProbed = true
    local ok, cls = pcall(function() return UE and UE.UUGCLog end)
    if not ok or type(cls) ~= "table" then return nil end
    local fn = cls.WriteLine
    if type(fn) ~= "function" then return nil end
    _ueSink = function(severity, event, fieldsJson) fn(severity, event, fieldsJson) end
    return _ueSink
end

local function defaultSink(severity, event, fieldsJson, line)
    local sink = ueSink()
    if sink then return sink(severity, event, fieldsJson) end
    print("[UGC] " .. line)
end

--============================================================
-- 格式化（纯函数，便于测试）
--============================================================

--- 把 severity/event/字段表格式化成单行日志
function Log.FormatLine(severity, event, fields)
    fields = fields or {}
    local parts = { "event=" .. tostring(event), "severity=" .. tostring(severity) }
    for _, key in ipairs(FLAT_KEYS) do
        local value = fields[key]
        if value ~= nil then parts[#parts + 1] = key .. "=" .. tostring(value) end
    end
    local rest = {}
    local restCount = 0
    for key, value in pairs(fields) do
        if not FLAT_SET[key] and value ~= nil then
            rest[key] = value
            restCount = restCount + 1
        end
    end
    if restCount > 0 then parts[#parts + 1] = "fields=" .. json.encode(rest) end
    return table.concat(parts, " ")
end

--- 登记校验：未登记的 code 会被替换为 unregistered_code，原值放入 fields
function Log.ResolveCode(code)
    local value = tostring(code or "ok")
    if Log.Codes[value] then return value, nil end
    return "unregistered_code", value
end

--============================================================
-- 输出
--============================================================

--- 写一条结构化日志，返回最终行文本
function Log.Emit(severity, event, fields)
    severity = Log.Severity[severity] or Log.Severity.info
    local merged = {}
    for key, value in pairs(_context) do merged[key] = value end
    if _session then merged.session = merged.session or _session end
    for key, value in pairs(fields or {}) do merged[key] = value end

    _sequence = _sequence + 1
    merged.seq = _sequence

    local line = Log.FormatLine(severity, tostring(event), merged)
    pushHistory(line)
    _counts[severity] = (_counts[severity] or 0) + 1

    for _, subscriber in ipairs(_subscribers) do
        pcall(subscriber, line, severity, event, merged)
    end

    local sink = _sink or defaultSink
    local ok, err = pcall(sink, severity, tostring(event), json.encode(merged), line)
    if not ok then print("[UGCLog] sink error: " .. tostring(err)) end
    return line
end

function Log.Debug(event, fields)   return Log.Emit(Log.Severity.debug, event, fields) end
function Log.Info(event, fields)    return Log.Emit(Log.Severity.info, event, fields) end
function Log.Warn(event, fields)    return Log.Emit(Log.Severity.warning, event, fields) end

--- 错误路径统一入口：code 必须来自 Log.Codes
function Log.Error(code, message, fields)
    local resolved, unknown = Log.ResolveCode(code)
    local payload = {}
    for key, value in pairs(fields or {}) do payload[key] = value end
    payload.code = resolved
    if unknown then payload.unregisteredCode = unknown end
    if message ~= nil then payload.message = tostring(message) end
    return Log.Emit(Log.Severity.error, "error", payload)
end

--- 命令事件（CommandBus 唯一出口）：带 command/source/type/ok/code 与实体、程序关联字段
function Log.Command(command, context, result, fields)
    command, context, result = command or {}, context or {}, result or {}
    local payload = {
        command = context.commandId,
        source = context.source,
        type = command.type,
        ok = result.ok and true or false,
        code = result.code or (result.ok and "ok" or "action_failed"),
        message = result.message,
    }
    if command.sceneID ~= nil then payload.entity = command.sceneID end
    if command.programId ~= nil then payload.program = command.programId end
    if command.record and command.record.sceneID ~= nil then payload.entity = command.record.sceneID end
    if command.commands then payload.steps = #command.commands end
    if command.label ~= nil then payload.label = command.label end
    for key, value in pairs(fields or {}) do payload[key] = value end
    local severity = result.ok and Log.Severity.info or Log.Severity.error
    return Log.Emit(severity, "command", payload)
end

--============================================================
-- 会话 / 上下文 / sink / 历史
--============================================================

--- 开启新的 UGC 文档会话（SceneData:Init 调用），返回新的 SessionId
function Log.NewSession(reason)
    _session = newSessionId()
    Log.Emit(Log.Severity.info, "session_begin", { reason = reason, startedAt = osTime() })
    return _session
end

function Log.GetSession() return _session end

--- 合并长期上下文字段（例如 document = documentId）
function Log.SetContext(values)
    for key, value in pairs(values or {}) do
        if value == nil then _context[key] = nil else _context[key] = value end
    end
    return _context
end

function Log.GetContext() return _context end

function Log.ClearContext()
    _context = {}
end

--- 替换 sink；fn(severity, event, fieldsJson, line)
function Log.SetSink(fn)
    if fn ~= nil and type(fn) ~= "function" then return false end
    _sink = fn
    return true
end

function Log.ResetSink()
    _sink = nil
    _ueSink = nil
    _ueSinkProbed = false
end

function Log.Subscribe(subscriber)
    if type(subscriber) ~= "function" then return false end
    _subscribers[#_subscribers + 1] = subscriber
    return true
end

--- 最近 n 条日志（环形缓冲，按时间顺序）
function Log.History(n)
    local size = math.min(n or MAX_HISTORY, math.min(#_history, MAX_HISTORY))
    local result = {}
    local total = _historyCount
    local start = total - size + 1
    for index = start, total do
        result[#result + 1] = _history[((index - 1) % MAX_HISTORY) + 1]
    end
    return result
end

function Log.Counts() return _counts end

function Log.Sequence() return _sequence end

--- 测试/重载用：清空会话、上下文、历史与订阅
function Log.Reset()
    _session = nil
    _sessionCounter = 0
    _context = {}
    _history = {}
    _historyCount = 0
    _subscribers = {}
    _sequence = 0
    _counts = { debug = 0, info = 0, warning = 0, error = 0 }
    _sink = nil
    _ueSink = nil
    _ueSinkProbed = false
end

Log.MAX_HISTORY = MAX_HISTORY

return Log