--[[
    WBP_UGCChat.lua
    绑定：WBP_UGCChat → UnLuaInterface → GetModuleName = "System.UI.UGC.WBP_UGCChat"

    聊天记录缓存：
    - 显示消息（{text, isUser} 列表）持久化到 Saved/UGC/chat_display.json
    - LLM 多轮历史持久化在 LLMGateway（Saved/UGC/chat_history.json）
    - 最多保留 MAX_DISPLAY 条显示消息，避免文件过大
]]

local json = require("Gameplay.UGC.json")

local M = UnLua.Class()

local MAX_DISPLAY = 40   -- 最多保留 40 条显示消息

--============================================================
-- 路径工具
--============================================================

local function getSavedDir()
    return UE.UKismetSystemLibrary.GetProjectDirectory() .. "Saved/UGC/"
end

local function getDisplayPath()
    return getSavedDir() .. "chat_display.json"
end

local function ensureDir()
    pcall(function() UE.UKismetSystemLibrary.MakeDirectory(getSavedDir()) end)
end

--============================================================
-- 生命周期
--============================================================

function M:Construct()
    if self.w_btn_send then
        self.w_btn_send.OnPressed:Add(self, self.OnClickSend)
    end
    if self.w_btn_close then
        self.w_btn_close.OnPressed:Add(self, self.OnClickClose)
    end
    if self.w_btn_clear then
        self.w_btn_clear.OnPressed:Add(self, self.OnClickClear)
    end
    if self.w_editablebox_input then
        self.w_editablebox_input.OnTextCommitted:Add(self, self.OnInputCommitted)
    end
    if self.w_text_thinking then
        self.w_text_thinking:SetVisibility(UE.ESlateVisibility.Hidden)
    end

    self._displayMsgs = {}

    -- 尝试恢复历史气泡；无历史则显示欢迎消息
    if not self:LoadDisplayHistory() then
        self:_AddBubble("你好！我是 AI 助手，可以帮你修改场景、属性、规则等。试试说：「在0,0,100放一个方块」", false)
    end
end

--============================================================
-- 发送逻辑
--============================================================

function M:OnClickSend()
    if not self.w_editablebox_input then return end
    local text = tostring(self.w_editablebox_input:GetText())
    if not text or text == "" then return end

    self:AddMessage(text, true)
    self.w_editablebox_input:SetText("")

    if self.w_text_thinking then
        self.w_text_thinking:SetText("AI 正在思考...")
        self.w_text_thinking:SetVisibility(UE.ESlateVisibility.SelfHitTestInvisible)
    end

    local pc = self:GetOwningPlayer()
    if pc and pc.SendToLLM then
        pc:SendToLLM(text, function(success, msg)
            self:OnLLMResult(success, msg)
        end)
    else
        self:OnLLMResult(false, "PlayerController 未绑定 SendToLLM")
    end
end

function M:OnInputCommitted(text, commitMethod)
    if commitMethod == UE.ETextCommit.OnEnter then
        self:OnClickSend()
    end
end

function M:OnLLMResult(success, msg)
    if self.w_text_thinking then
        self.w_text_thinking:SetVisibility(UE.ESlateVisibility.Hidden)
    end
    local prefix = success and "✓ " or "✗ "
    self:AddMessage(prefix .. tostring(msg), false)
end

function M:OnClickClose()
    local UIManager = require("Gameplay.Core.UIManager")
    UIManager:CloseWindow("WBP_UGCChat")
end

function M:OnClickClear()
    -- 清空 UI
    if self.w_scrollbox_messages then
        self.w_scrollbox_messages:ClearChildren()
    end
    self._displayMsgs = {}
    self:SaveDisplayHistory()

    -- 同步清空 LLM 历史
    local ok, Gateway = pcall(require, "Gameplay.UGC.LLMGateway")
    if ok and Gateway and Gateway.ClearHistory then
        Gateway:ClearHistory()
    end

    -- 显示欢迎消息（不入历史）
    self:_AddBubble("聊天记录已清空。", false)
end

--============================================================
-- 消息气泡（内部）
-- _AddBubble: 只创建 Widget，不修改 _displayMsgs（用于恢复重放）
-- AddMessage:  追加到 _displayMsgs 并持久化，再创建 Widget
--============================================================

function M:_AddBubble(text, isUser)
    if not self.w_scrollbox_messages then return end

    local cls = UE.UClass.Load("/Game/_UGC/UI/WBP_UGCChatMsg.WBP_UGCChatMsg_C")
    if cls then
        local pc  = self:GetOwningPlayer()
        local row = UE.UWidgetBlueprintLibrary.Create(self, cls, pc)
        if row then
            if row.Init then row:Init(text, isUser) end
            local slot = self.w_scrollbox_messages:AddChild(row)
            if slot then
                slot:SetHorizontalAlignment(
                    isUser and UE.EHorizontalAlignment.HAlign_Right
                            or UE.EHorizontalAlignment.HAlign_Left)
            end
        end
    else
        -- fallback: 纯文本
        if not self._fallbackLines then self._fallbackLines = {} end
        table.insert(self._fallbackLines, (isUser and "[你] " or "[AI] ") .. text)
        if self.w_text_fallback then
            self.w_text_fallback:SetText(table.concat(self._fallbackLines, "\n"))
        end
    end

    self.w_scrollbox_messages:ScrollToEnd()
end

function M:AddMessage(text, isUser)
    if not self._displayMsgs then self._displayMsgs = {} end
    table.insert(self._displayMsgs, { text = text, isUser = isUser })
    -- 超出上限时从头裁掉
    while #self._displayMsgs > MAX_DISPLAY do
        table.remove(self._displayMsgs, 1)
    end
    self:SaveDisplayHistory()
    self:_AddBubble(text, isUser)
end

--============================================================
-- 持久化
--============================================================

function M:SaveDisplayHistory()
    ensureDir()
    local pc = self:GetOwningPlayer()
    local storage = pc and pc:GetUGCStorageBridge() or nil
    if storage then
        storage:WriteTextFileAtomic(getDisplayPath(), json.encode(self._displayMsgs or {}))
    end
end

--- 读取并重放历史气泡，返回 bool（是否有历史）
function M:LoadDisplayHistory()
    local pc = self:GetOwningPlayer()
    local storage = pc and pc:GetUGCStorageBridge() or nil
    local path = getDisplayPath()
    if not storage or not storage:FileExists(path) then return false end
    local msgs = json.decode(tostring(storage:ReadTextFile(path)))
    if type(msgs) ~= "table" or #msgs == 0 then return false end

    self._displayMsgs = msgs
    for _, m in ipairs(msgs) do
        self:_AddBubble(m.text, m.isUser == true)
    end
    return true
end

return M
