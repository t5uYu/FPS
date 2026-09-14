--[[
    WBP_FabLogin.lua
    Fab 登录 / 注册面板 Lua VM（路线 B 唯一的 UMG 登录入口）

    零 BP 节点方案：
    - 提交按钮：Lua 直接调 bridge:LoginSimple / RegisterSimple（C++ 端 fire-and-forget）
    - 完成回调：订阅 bridge.OnLoginCompleted / OnRegisterCompleted 多播
    - 登录成功 → Lua 侧 CreateWidget WBP_FabPanel 并 AddToViewport，自己 RemoveFromParent

    BP 图可以完全空白；UnLua Module 字段填 `System.UI.Fab.WBP_FabLogin`。

    控件命名（必须 Is Variable 勾选，和 w_ 前缀规范一致）：
    ┌──────────────────────────────────────┐
    │ [w_tab_Login]      Button            │  ← 切 Login tab
    │ [w_tab_Register]   Button            │  ← 切 Register tab
    │ [w_input_Account]  EditableTextBox   │
    │ [w_input_Password] EditableTextBox   │  IsPassword=true
    │ [w_input_Name]     EditableTextBox   │  注册时才显示
    │ [w_btn_Submit]     Button            │
    │ [w_btn_Cancel]     Button            │
    │ [w_text_Status]    TextBlock         │
    └──────────────────────────────────────┘
]]

local FabClient = require("Gameplay.Fab.FabClient")

local M = UnLua.Class()

local LOG_TAG = "[System.UI.Fab.WBP_FabLogin]"
local function Log(s)  print(LOG_TAG .. " " .. tostring(s)) end
local function Warn(s) print(LOG_TAG .. "[Warn] " .. tostring(s)) end

local TAB_LOGIN    = "login"
local TAB_REGISTER = "register"

local function TextToString(text)
    if text == nil then return "" end
    if type(text) == "string" then return text end
    if type(text) == "number" or type(text) == "boolean" then return tostring(text) end
    if text.ToString then
        local ok, result = pcall(function() return text:ToString() end)
        if ok and result ~= nil then return tostring(result) end
    end
    return tostring(text)
end

local function SetWidgetText(widget, text)
    if widget and widget.SetText then
        pcall(function() widget:SetText(tostring(text or "")) end)
    end
end

local function bindButton(self, name, handler)
    local w = self[name]
    if not w or not w.OnClicked then
        Warn("缺少按钮或未暴露为变量: " .. name)
        return false
    end
    w.OnClicked:Add(self, handler)
    return true
end

--============================================================
-- 生命周期
--============================================================

function M:Construct()
    self.current_tab = TAB_LOGIN
    self.pending_account  = ""
    self.pending_password = ""
    self.pending_name     = ""
    self.busy = false

    bindButton(self, "w_tab_Login",    M.OnClickTabLogin)
    bindButton(self, "w_tab_Register", M.OnClickTabRegister)
    bindButton(self, "w_btn_Submit",   M.OnClickSubmit)
    bindButton(self, "w_btn_Cancel",   M.OnClickCancel)

    if self.w_input_Account and self.w_input_Account.OnTextChanged then
        self.w_input_Account.OnTextChanged:Add(self, M.OnTextAccountChanged)
    end
    if self.w_input_Password and self.w_input_Password.OnTextChanged then
        self.w_input_Password.OnTextChanged:Add(self, M.OnTextPasswordChanged)
    end
    if self.w_input_Name and self.w_input_Name.OnTextChanged then
        self.w_input_Name.OnTextChanged:Add(self, M.OnTextNameChanged)
    end

    -- 先 Init FabClient，拿到 PC 上挂的 Bridge
    local pc = UE.UGameplayStatics.GetPlayerController(self, 0)
    if pc then FabClient:Init(pc) end

    local bridge = FabClient:GetBridge()
    if not bridge then
        Warn("FabClient 未初始化或 Bridge 未挂载在 PC 上")
        self:SetStatus("内部错误：未找到 FabClientBridge 组件")
    else
        self.Bridge = bridge
        -- 订阅 Bridge 多播
        if bridge.OnLoginCompleted then
            bridge.OnLoginCompleted:Add(self, M.OnLoginCompleted)
        end
        if bridge.OnRegisterCompleted then
            bridge.OnRegisterCompleted:Add(self, M.OnRegisterCompleted)
        end
        if bridge.OnAuthChanged then
            bridge.OnAuthChanged:Add(self, M.OnAuthChanged)
        end
        if bridge.OnGlobalError then
            bridge.OnGlobalError:Add(self, M.OnGlobalError)
        end

        -- 已登录（token.dat 已恢复）：直接打开 FabPanel
        if bridge:IsLoggedIn() then
            Log("检测到已登录态，直接打开 FabPanel")
            self:OpenFabPanel()
            return
        end
    end

    self:ApplyTab(TAB_LOGIN)
    self:SetStatus("")
    Log("构建完成")
end

function M:Destruct()
    if self.Bridge then
        pcall(function() self.Bridge.OnLoginCompleted:Remove(self, M.OnLoginCompleted) end)
        pcall(function() self.Bridge.OnRegisterCompleted:Remove(self, M.OnRegisterCompleted) end)
        pcall(function() self.Bridge.OnAuthChanged:Remove(self, M.OnAuthChanged) end)
        pcall(function() self.Bridge.OnGlobalError:Remove(self, M.OnGlobalError) end)
    end
end

--============================================================
-- Tab 切换
--============================================================

function M:ApplyTab(tab)
    self.current_tab = tab
    local isRegister = (tab == TAB_REGISTER)
    if self.w_input_Name then
        self.w_input_Name:SetVisibility(
            isRegister and UE.ESlateVisibility.Visible or UE.ESlateVisibility.Collapsed)
    end
    if self.w_btn_Submit then
        local label = isRegister and "注册" or "登录"
        pcall(function()
            local textChild = self.w_btn_Submit.GetChildAt and self.w_btn_Submit:GetChildAt(0)
            if textChild and textChild.SetText then
                SetWidgetText(textChild, label)
            end
        end)
    end
    self:SetStatus("")
end

function M:OnClickTabLogin()    self:ApplyTab(TAB_LOGIN) end
function M:OnClickTabRegister() self:ApplyTab(TAB_REGISTER) end

--============================================================
-- 输入捕获
--============================================================

function M:OnTextAccountChanged(text)  self.pending_account  = TextToString(text) end
function M:OnTextPasswordChanged(text) self.pending_password = TextToString(text) end
function M:OnTextNameChanged(text)     self.pending_name     = TextToString(text) end

--============================================================
-- 提交 / 取消
--============================================================

function M:OnClickSubmit()
    if self.busy then return end
    if not self.Bridge then
        self:SetStatus("Bridge 未就绪")
        return
    end
    if self.pending_account == "" or self.pending_password == "" then
        self:SetStatus("账号和密码不能为空")
        return
    end
    if self.current_tab == TAB_REGISTER and #self.pending_password < 8 then
        self:SetStatus("密码长度至少 8 位")
        return
    end

    self.busy = true
    self:SetSubmitEnabled(false)

    if self.current_tab == TAB_REGISTER then
        self:SetStatus("注册中…")
        self.Bridge:RegisterSimple(self.pending_account, self.pending_password, self.pending_name or "")
    else
        self:SetStatus("登录中…")
        self.Bridge:LoginSimple(self.pending_account, self.pending_password)
    end
end

function M:OnClickCancel()
    if self.busy then return end
    self.pending_account  = ""
    self.pending_password = ""
    self.pending_name     = ""
    SetWidgetText(self.w_input_Account, "")
    SetWidgetText(self.w_input_Password, "")
    SetWidgetText(self.w_input_Name, "")
    self:SetStatus("")
    self:SetSubmitEnabled(true)
    -- 直接关闭登录面板（UGCEditor 里点 "Fab" 会重开）
    pcall(function() self:RemoveFromParent() end)
end

--============================================================
-- Bridge 多播回调
--============================================================

function M:OnLoginCompleted(err, result)
    self.busy = false
    self:SetSubmitEnabled(true)
    if err and err.BizCode and err.BizCode ~= 0 then
        self:SetStatus(string.format("登录失败(%d): %s", err.BizCode, err.Message or ""))
        return
    end
    if err and err.HttpCode and err.HttpCode ~= 0 and (err.HttpCode < 200 or err.HttpCode >= 300) then
        self:SetStatus(string.format("登录失败(http=%d): %s", err.HttpCode, err.Message or ""))
        return
    end
    self:SetStatus("登录成功，正在打开 Fab 面板…")
    self:OpenFabPanel()
end

function M:OnRegisterCompleted(err, result)
    self.busy = false
    self:SetSubmitEnabled(true)
    if err and err.BizCode and err.BizCode ~= 0 then
        self:SetStatus(string.format("注册失败(%d): %s", err.BizCode, err.Message or ""))
        return
    end
    if err and err.HttpCode and err.HttpCode ~= 0 and (err.HttpCode < 200 or err.HttpCode >= 300) then
        self:SetStatus(string.format("注册失败(http=%d): %s", err.HttpCode, err.Message or ""))
        return
    end
    self:SetStatus("注册成功，已自动登录，正在打开 Fab 面板…")
    self:OpenFabPanel()
end

function M:OnAuthChanged(user)
    if user and user.Id and user.Id > 0 then
        Log(string.format("用户登录: id=%d account=%s", user.Id, user.UserAccount or ""))
    else
        Log("用户已登出")
    end
end

function M:OnGlobalError(err)
    if not err then return end
    -- 全局错误只做日志，不打断登录页 status（本地校验优先）
    Log(string.format("全局错误(biz=%d http=%d): %s",
        err.BizCode or -1, err.HttpCode or 0, err.Message or ""))
end

--============================================================
-- 打开 FabPanel
--============================================================

--- 创建 WBP_FabPanel 并 AddToViewport；自身 RemoveFromParent。
--- 资产路径硬编码 /Game/_UGC/UI/WBP_FabPanel.WBP_FabPanel_C；
--- 工程改动资产位置时同步更新此处即可。
function M:OpenFabPanel()
    local PanelClassPath = "/Game/_UGC/UI/WBP_FabPanel.WBP_FabPanel_C"
    local PanelClass = UE.UClass.Load(PanelClassPath)
    if not PanelClass then
        Warn("加载 WBP_FabPanel 类失败: " .. PanelClassPath)
        self:SetStatus("打开 Fab 面板失败：资源未找到")
        return
    end

    local pc = UE.UGameplayStatics.GetPlayerController(self, 0)
    if not pc then
        Warn("未找到 PlayerController")
        return
    end

    local panel = UE.UWidgetBlueprintLibrary.Create(self, PanelClass, pc)
    if not panel then
        Warn("CreateWidget 失败")
        return
    end
    panel:AddToViewport(10)
    self:RemoveFromParent()
end

--============================================================
-- 内部辅助
--============================================================

function M:SetStatus(msg)
    SetWidgetText(self.w_text_Status, msg or "")
end

function M:SetSubmitEnabled(enabled)
    if self.w_btn_Submit then
        self.w_btn_Submit:SetIsEnabled(enabled)
    end
end

return M
