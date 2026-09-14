--[[
    WBP_UGCChatMsg.lua
    单条聊天消息气泡
    绑定：WBP_UGCChatMsg → GetModuleName = "System.UI.UGC.WBP_UGCChatMsg"

    蓝图控件：
        w_btn_bg   Border   气泡背景
        w_text_msg    TextBlock 消息内容（Auto Wrap）

    由 WBP_UGCChat:AddMessage 创建并初始化。
]]

local M = UnLua.Class()

function M:Construct()
    if self.w_btn_copy then
        self.w_btn_copy.OnPressed:Add(self, self.OnClickCopy)
    end
end

function M:OnClickCopy()
    local text = self._msgText or ""
    local pc = self:GetOwningPlayer()
    if pc and pc.CopyToClipboard then
        pc:CopyToClipboard(text)
        print("[ChatMsg] 已复制: " .. text)
    end
end

--- 由父 Widget 调用，设置内容和方向
--- @param text   string
--- @param isUser bool
function M:Init(text, isUser)
    self._msgText = tostring(text)  -- 实例变量，每条消息独立

    if self.w_text_msg then
        self.w_text_msg:SetText(tostring(text))
        pcall(function()
            self.w_text_msg:SetJustification(
                isUser and UE.ETextJustify.Right or UE.ETextJustify.Left)
        end)
    end

    -- w_btn_copy 的显示/隐藏由蓝图 OnHovered/OnUnhovered 控制，Lua 不干预
end

return M
