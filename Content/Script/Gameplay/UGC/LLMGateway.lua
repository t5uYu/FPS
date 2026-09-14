--[[
    LLMGateway.lua

    Provider-neutral orchestration for LLM tool calls. The model never executes
    world mutations directly: tool calls become a validated proposal first.
    Read-only proposals may run automatically; write/high-risk proposals require
    explicit user confirmation ("确认" / "取消").
]]

local Registry = require("Gameplay.UGC.UGCFunctionRegistry")
local json = require("Gameplay.UGC.json")

local Gateway = {}
Gateway.__index = Gateway

local _pc = nil
local _httpClient = nil
local _onResult = nil
local _history = {}
local _historyPath = nil
local _storage = nil
local _pendingProposal = nil
local _requestSequence = 0
local _toolRound = 0

local MAX_HISTORY_ROUNDS = 20
local MAX_TOOL_ROUNDS = 4

local function getSavedDir()
    return UE.UKismetSystemLibrary.GetProjectDirectory() .. "Saved/UGC/"
end

local function ensureDir()
    pcall(function() UE.UKismetSystemLibrary.MakeDirectory(getSavedDir()) end)
end

local function finish(success, message)
    local callback = _onResult
    _onResult = nil
    if callback then callback(success, message) end
end

local function normalizeUserCommand(message)
    return tostring(message or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

function Gateway:Init(playerController)
    _pc = playerController
    _httpClient = playerController:GetUGCHttpClient()
    _storage = playerController:GetUGCStorageBridge()
    _historyPath = getSavedDir() .. "chat_history.json"
    _pendingProposal = nil
    _toolRound = 0
    if not self:LoadHistory() then _history = {} end
    print("[LLMGateway] 初始化完成，历史条数: " .. #_history)
end

function Gateway:SaveHistory()
    if not _historyPath or not _storage then return false end
    ensureDir()
    return _storage:WriteTextFileAtomic(_historyPath, json.encode(_history))
end

function Gateway:LoadHistory()
    if not _historyPath or not _storage or not _storage:FileExists(_historyPath) then return false end
    local history = json.decode(tostring(_storage:ReadTextFile(_historyPath)))
    if type(history) ~= "table" then return false end
    _history = history
    return true
end

function Gateway:ClearHistory()
    _history = {}
    _pendingProposal = nil
    if _historyPath and _storage then
        ensureDir()
        _storage:WriteTextFileAtomic(_historyPath, "[]")
    end
end

function Gateway:_TrimHistory()
    local rounds = 0
    for _, message in ipairs(_history) do if message.role == "user" then rounds = rounds + 1 end end
    while rounds > MAX_HISTORY_ROUNDS do
        table.remove(_history, 1)
        while #_history > 0 and _history[1].role ~= "user" do table.remove(_history, 1) end
        rounds = rounds - 1
    end
end

function Gateway:_SendCurrentHistory()
    if not _httpClient then finish(false, "LLM HTTP 客户端未初始化"); return false end
    local messages = {}
    local systemPrompt = _httpClient.SystemPrompt
    if systemPrompt and systemPrompt ~= "" then messages[#messages + 1] = {role="system", content=systemPrompt} end
    self:_TrimHistory()
    for _, message in ipairs(_history) do messages[#messages + 1] = message end
    _httpClient:SendMessageWithHistory(json.encode(messages), Registry:GetSchemas())
    return true
end

function Gateway:Shutdown()
    if _httpClient and _httpClient:IsRequestInProgress() then _httpClient:CancelRequest() end
    _pc, _httpClient, _onResult, _pendingProposal = nil, nil, nil, nil
    _toolRound = 0
end

function Gateway:HasPendingProposal()
    return _pendingProposal ~= nil
end

function Gateway:Send(userMessage, onResult)
    local normalized = normalizeUserCommand(userMessage)
    if _pendingProposal then
        if normalized == "确认" or normalized == "confirm" or normalized == "yes" then
            return self:ApprovePendingProposal(onResult)
        elseif normalized == "取消" or normalized == "cancel" or normalized == "no" then
            return self:RejectPendingProposal(onResult)
        end
        if onResult then onResult(false, "存在待确认操作，请先输入“确认”或“取消”") end
        return false
    end

    if not _httpClient then
        if onResult then onResult(false, "网关未初始化") end
        return false
    end
    if _httpClient:IsRequestInProgress() then
        if onResult then onResult(false, "上一条消息还在处理中，请稍候") end
        return false
    end

    _requestSequence = _requestSequence + 1
    _toolRound = 0
    _onResult = onResult
    _history[#_history + 1] = {role="user", content=tostring(userMessage)}
    return self:_SendCurrentHistory()
end

local function appendToolResults(proposal, results, cancelled)
    for index, call in ipairs(proposal.calls or {}) do
        local result = results and results[index] or nil
        local content
        if cancelled then
            content = json.encode({ok=false, code="cancelled", message="用户取消操作"})
        else
            content = json.encode({
                ok=result and result.ok or false,
                result=result and result.result or "missing result",
            })
        end
        _history[#_history + 1] = {
            role="tool",
            tool_call_id=call.id or ("call_" .. tostring(call.name)),
            content=content,
        }
    end
end

function Gateway:_ExecuteProposalAndContinue(proposal)
    local allOk, results = Registry:ExecuteProposal(proposal)
    appendToolResults(proposal, results, false)
    _pendingProposal = nil
    _toolRound = _toolRound + 1
    self:SaveHistory()

    if _toolRound >= MAX_TOOL_ROUNDS then
        local summary = {}
        for _, result in ipairs(results) do
            summary[#summary + 1] = string.format("%s: %s", result.name, tostring(result.result))
        end
        finish(allOk, table.concat(summary, "\n"))
        return allOk
    end
    return self:_SendCurrentHistory()
end

function Gateway:ApprovePendingProposal(onResult)
    if not _pendingProposal then
        if onResult then onResult(false, "没有待确认操作") end
        return false
    end
    if _httpClient and _httpClient:IsRequestInProgress() then
        if onResult then onResult(false, "请求仍在处理中") end
        return false
    end
    _onResult = onResult
    return self:_ExecuteProposalAndContinue(_pendingProposal)
end

function Gateway:RejectPendingProposal(onResult)
    if not _pendingProposal then
        if onResult then onResult(false, "没有待确认操作") end
        return false
    end
    appendToolResults(_pendingProposal, nil, true)
    _history[#_history + 1] = {role="assistant", content="操作已由用户取消。"}
    _pendingProposal = nil
    self:SaveHistory()
    if onResult then onResult(true, "已取消待执行操作") end
    return true
end

function Gateway:OnResponse(responseJSON)
    local data = json.decode(responseJSON)
    local message = data and data.choices and data.choices[1] and data.choices[1].message or nil
    if not message then finish(false, "响应格式异常：缺少 choices[0].message"); return end

    local toolCalls = {}
    for _, toolCall in ipairs(message.tool_calls or {}) do
        if toolCall["function"] then
            local rawArguments = toolCall["function"].arguments or "{}"
            local params = type(rawArguments) == "string" and (json.decode(rawArguments) or {}) or rawArguments
            toolCalls[#toolCalls + 1] = {
                name=toolCall["function"].name,
                params=type(params) == "table" and params or {},
                id=toolCall.id,
            }
        end
    end

    if #toolCalls == 0 then
        local text = message.content
        if text and text ~= "" then
            _history[#_history + 1] = {role="assistant", content=text}
            self:SaveHistory()
            finish(true, text)
        else
            finish(false, "LLM 未返回有效内容")
        end
        return
    end

    local assistantMessage = {role="assistant", content=message.content or "", tool_calls={}}
    for _, call in ipairs(toolCalls) do
        assistantMessage.tool_calls[#assistantMessage.tool_calls + 1] = {
            id=call.id or ("call_" .. tostring(call.name)),
            type="function",
            ["function"]={name=call.name, arguments=json.encode(call.params)},
        }
    end
    _history[#_history + 1] = assistantMessage

    local valid, proposalOrError = Registry:BuildProposal(toolCalls)
    if not valid then
        table.remove(_history)
        self:SaveHistory()
        finish(false, proposalOrError)
        return
    end
    local proposal = proposalOrError
    proposal.requestId = "req_" .. tostring(_requestSequence)

    if proposal.highestRisk == "read" then
        self:_ExecuteProposalAndContinue(proposal)
        return
    end

    _pendingProposal = proposal
    self:SaveHistory()
    local summary = Registry:FormatProposal(proposal)
        .. "\n\n该提案尚未执行。请输入“确认”执行，或输入“取消”。"
    finish(true, summary)
end

function Gateway:OnError(errorMsg)
    self:SaveHistory()
    finish(false, "请求失败: " .. tostring(errorMsg))
end

return Gateway
