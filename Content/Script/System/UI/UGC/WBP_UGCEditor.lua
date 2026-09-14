--[[
    WBP_UGCEditor.lua
    游戏内关卡编辑器 UI

    蓝图绑定：WBP_UGCEditor → GetModuleName = "System.UI.UGC.WBP_UGCEditor"

    Widget 结构（在 UE 编辑器里创建）：
    ┌─────────────────────────────────────────────────────┐
    │  [w_panel_Prefabs]  左栏预制体列表（ScrollBox）       │
    │  [w_panel_Props]    右栏属性面板（Transform 输入）    │
    │  [w_panel_Bottom]   底栏操作按钮                     │
    │    w_btn_Play       试玩/返回编辑                    │
    │    w_btn_Save       保存场景                         │
    │    w_btn_Load       加载场景                         │
    │    w_btn_Clear      清空场景                         │
    │    w_btn_Delete     删除选中                         │
    │    w_btn_Undo       撤销                             │
    │    w_text_Status    状态文字                         │
    │  [w_input_X/Y/Z]    位置输入框                       │
    │  [w_input_P/Yaw/R]  旋转输入框                       │
    │  [w_input_SX/SY/SZ] 缩放输入框                       │
    └─────────────────────────────────────────────────────┘
]]

local EditorCore      = require("Gameplay.UGC.UGCEditorCore")
local Persistence     = require("Gameplay.UGC.UGCPersistence")
local _ok, PrefabRegistry = pcall(require, "Gameplay.UGC.UGCPrefabRegistry")
if not _ok then
    print("[WBP_UGCEditor] 警告: 顶层 require UGCPrefabRegistry 失败: " .. tostring(PrefabRegistry))
    PrefabRegistry = nil
end

local M = UnLua.Class()

local LOG_TAG = "[System.UI.UGC.WBP_UGCEditor]"

local function Log(msg)
    print(LOG_TAG .. " " .. tostring(msg))
end

local function Warn(msg)
    print(LOG_TAG .. "[Warn] " .. tostring(msg))
end

local Colors = {
    HeaderBg = UE.FLinearColor(0.08, 0.12, 0.18, 1.0),
    ItemBg = UE.FLinearColor(0.12, 0.20, 0.30, 1.0),
    ImportBg = UE.FLinearColor(0.00, 0.55, 0.46, 1.0),
}

local function callWidgetMethod(widget, methodName, ...)
    if widget and widget[methodName] then
        pcall(widget[methodName], widget, ...)
    end
end

local function setupPrefabLabel(label, text, wrapAt)
    if not label then return end

    label:SetText(tostring(text or ""))
    callWidgetMethod(label, "SetJustification", UE.ETextJustify.Center)
    callWidgetMethod(label, "SetMinDesiredWidth", 150.0)
    callWidgetMethod(label, "SetAutoWrapText", true)
    callWidgetMethod(label, "SetWrapTextAt", wrapAt or 128.0)
    callWidgetMethod(label, "SetRenderOpacity", 1.0)

    if UE.ETextWrappingPolicy and UE.ETextWrappingPolicy.AllowPerCharacterWrapping then
        callWidgetMethod(label, "SetWrappingPolicy", UE.ETextWrappingPolicy.AllowPerCharacterWrapping)
    end
end

local function setupPrefabButton(button, bgColor)
    if not button then return end

    callWidgetMethod(button, "SetRenderOpacity", 1.0)
    if bgColor then
        callWidgetMethod(button, "SetBackgroundColor", bgColor)
    end
end

local function setupPrefabButtonSlot(slot)
    if not slot then return end

    callWidgetMethod(slot, "SetHorizontalAlignment", UE.EHorizontalAlignment.HAlign_Fill)
    callWidgetMethod(slot, "SetVerticalAlignment", UE.EVerticalAlignment.VAlign_Center)
    if UE.FMargin then
        callWidgetMethod(slot, "SetPadding", UE.FMargin(8.0, 3.0, 8.0, 3.0))
    end
end

local function bindButton(self, widgetName, handler)
    local widget = self[widgetName]
    if not widget then
        Warn("缺少按钮控件: " .. widgetName .. "（请检查蓝图命名和 Is Variable）")
        return false
    end
    if not widget.OnClicked then
        Warn("按钮控件没有 OnClicked: " .. widgetName)
        return false
    end
    widget.OnClicked:Add(self, handler)
    return true
end

local function bindAnyButton(self, widgetNames, handler)
    for _, widgetName in ipairs(widgetNames) do
        local widget = self[widgetName]
        if widget and widget.OnClicked then
            widget.OnClicked:Add(self, handler)
            Log("绑定按钮: " .. widgetName)
            return true
        end
    end
    Warn("缺少按钮控件: " .. table.concat(widgetNames, " / ") .. "（请检查蓝图命名和 Is Variable）")
    return false
end

local function bindTextCommit(self, widgetName)
    local widget = self[widgetName]
    if not widget then
        Warn("缺少输入框控件: " .. widgetName .. "（请检查蓝图命名和 Is Variable）")
        return false
    end
    if not widget.OnTextCommitted then
        Warn("输入框控件没有 OnTextCommitted: " .. widgetName)
        return false
    end
    widget.OnTextCommitted:Add(self, M.OnTransformCommit)
    return true
end

--============================================================
-- 生命周期
--============================================================

function M:Construct()
    local missingCount = 0

    for _, pair in ipairs({
        { "w_btn_Play",      M.OnClickPlay },
        { "w_btn_Save",      M.OnClickSave },
        { "w_btn_Load",      M.OnClickLoad },
        { "w_btn_Clear",     M.OnClickClear },
        { "w_btn_Delete",    M.OnClickDelete },
        { "w_btn_Undo",      M.OnClickUndo },
        { "w_btn_Blueprint",       M.OnClickBlueprint },
        { "w_btn_Blueprint_Actor", M.OnClickActorBlueprint },
        { "w_btn_aichat",          M.OnClickChat },
    }) do
        if not bindButton(self, pair[1], pair[2]) then
            missingCount = missingCount + 1
        end
    end

    if not bindAnyButton(self, { "w_btn_Fab", "btn_fab" }, M.OnClickFab) then
        missingCount = missingCount + 1
    end

    for _, widgetName in ipairs({
        "w_input_X", "w_input_Y", "w_input_Z",
        "w_input_P", "w_input_Yaw", "w_input_R",
        "w_input_SX", "w_input_SY", "w_input_SZ",
    }) do
        if not bindTextCommit(self, widgetName) then
            missingCount = missingCount + 1
        end
    end

    if missingCount > 0 then
        Warn("Construct: 共发现 " .. tostring(missingCount) .. " 个控件未正确绑定")
    end

    self:BuildPrefabList()

    -- 监听状态变化（刷新试玩按钮文字）
    EditorCore:OnStateChanged(function(state)
        self:RefreshPlayButton(state)
    end)

    -- 监听选中变化（刷新 Transform 面板 + Actor 蓝图按钮可见性）
    EditorCore:OnSelectionChanged(function(sceneID)
        if sceneID then
            self:RefreshTransformInputs()
        else
            self:ClearTransformInputs()
        end
        self:RefreshActorBlueprintBtn(sceneID)
    end)

    -- Actor 蓝图按钮初始隐藏（无选中时不显示）
    self:RefreshActorBlueprintBtn(nil)

    self:SetStatus("就绪 — 点击预制体开始放置")

    -- 初始化网格对齐 UI（控件可选，不存在时只打 Warn 不报错）
    self:BuildSnapUI()


    Log("UI 构建完成")
end

--============================================================
-- 预制体列表（动态生成按钮）
--============================================================

--- 重建预制体列表（AddCustomPrefab 后调用刷新 UI）
function M:RebuildPrefabList()
    if not self.w_panel_Prefabs then
        Warn("RebuildPrefabList: 找不到 w_panel_Prefabs")
        return
    end
    self.w_panel_Prefabs:ClearChildren()
    self:BuildPrefabList()
end

local BTN_CLASS_PATH = "/Game/_UGC/UI/WBP_UGCPrefabBtn.WBP_UGCPrefabBtn_C"
local _btnClass = nil

local function getBtnClass()
    if not _btnClass then
        _btnClass = UE.UClass.Load(BTN_CLASS_PATH)
        if not _btnClass then
            Warn("找不到 WBP_UGCPrefabBtn，路径: " .. BTN_CLASS_PATH)
        end
    end
    return _btnClass
end

function M:BuildPrefabList()
    if not self.w_panel_Prefabs then
        Warn("BuildPrefabList: 找不到 w_panel_Prefabs，请检查蓝图是否勾选 Is Variable")
        self:SetStatus("预制体面板未绑定")
        return
    end

    -- 懒加载：模块顶层 require 在 Widget 加载时可能失败，这里兜底
    local PrefabReg = PrefabRegistry
    if not PrefabReg then
        local ok, reg = pcall(require, "Gameplay.UGC.UGCPrefabRegistry")
        if ok and reg then
            PrefabReg = reg
        else
            Warn("BuildPrefabList: 无法加载 UGCPrefabRegistry: " .. tostring(reg))
            self:SetStatus("预制体注册表加载失败")
            return
        end
    end

    local cats = PrefabReg.Categories or {}
    Log(string.format("BuildPrefabList: %d 个分类", #cats))

    if #cats == 0 then
        Warn("当前没有可用预制体，请检查 Placeables 目录、manifest 或注册表日志")
        self:SetStatus("未找到预制体")
        return
    end

    local pc = self:GetOwningPlayer()
    if not pc then
        Warn("BuildPrefabList: GetOwningPlayer 返回 nil")
        self:SetStatus("无法获取 OwningPlayer")
        return
    end

    local btnClass = getBtnClass()
    if not btnClass then
        self:SetStatus("列表项蓝图丢失")
        return
    end

    local addedCount = 0

    -- AnimAgent：在所有分类前插入"+ 资产包"按钮
    self:_BuildImportPackageButton(pc, btnClass)

    for _, category in ipairs(cats) do
        local header = UE.UWidgetBlueprintLibrary.Create(pc, btnClass, pc)
        if header then
            if header.w_label then
                setupPrefabLabel(header.w_label, category.name, 128.0)
            else
                Warn("分类按钮缺少 w_label: " .. tostring(category.name))
            end
            if header.w_btn then
                setupPrefabButton(header.w_btn, Colors.HeaderBg)
            else
                Warn("分类按钮缺少 w_btn: " .. tostring(category.name))
            end
            setupPrefabButtonSlot(self.w_panel_Prefabs:AddChild(header))
        else
            Warn("创建分类标题失败: " .. tostring(category.name))
        end

        for _, item in ipairs(category.items or {}) do
            local btn = UE.UWidgetBlueprintLibrary.Create(pc, btnClass, pc)
            if btn then
                if btn.w_label then
                    setupPrefabLabel(btn.w_label, item.label, 128.0)
                else
                    Warn("预制体按钮缺少 w_label: " .. tostring(item.id))
                end
                setupPrefabButton(btn.w_btn, Colors.ItemBg)

                local prefabID = item.id
                if btn.w_btn and btn.w_btn.OnPressed then
                    btn.w_btn.OnPressed:Add(self, function()
                        self:OnClickPrefab(prefabID)
                    end)
                else
                    Warn("预制体按钮缺少 w_btn 或 OnPressed: " .. tostring(item.id))
                end

                setupPrefabButtonSlot(self.w_panel_Prefabs:AddChild(btn))
                addedCount = addedCount + 1
                Log("添加: " .. tostring(item.id))
            else
                Warn("创建预制体按钮失败: " .. tostring(item.id))
            end
        end
    end

    Log(string.format("BuildPrefabList 完成，共添加 %d 个预制体按钮", addedCount))
end

--============================================================
-- AnimAgent：本地 UGC Runtime Package 导入入口
--============================================================

local _animAgentReady = false

local function _ensureAnimAgent(pc)
    if _animAgentReady then return true end
    local ok, Core = pcall(require, "Gameplay.AnimAgent.AnimAgentCore")
    if not ok or not Core then
        Warn("AnimAgentCore 加载失败: " .. tostring(Core))
        return false
    end
    if not Core:IsReady() then
        if not Core:Init(pc) then
            Warn("AnimAgentCore:Init 失败 — 检查 PlayerController 是否挂了 UAnimGenClient")
            return false
        end
    end
    _animAgentReady = true
    return true
end

function M:_BuildImportPackageButton(pc, btnClass)
    local btn = UE.UWidgetBlueprintLibrary.Create(pc, btnClass, pc)
    if not btn then
        Warn("_BuildImportPackageButton: Create 失败")
        return
    end
    if btn.w_label then
        setupPrefabLabel(btn.w_label, "+ 资产包", 128.0)
    end
    setupPrefabButton(btn.w_btn, Colors.ImportBg)
    if btn.w_btn and btn.w_btn.OnPressed then
        btn.w_btn.OnPressed:Add(self, function() self:OnClickImportPackage() end)
    end
    setupPrefabButtonSlot(self.w_panel_Prefabs:AddChild(btn))
end

function M:OnClickImportPackage()
    local pc = self:GetOwningPlayer()
    if not pc then return end
    if not _ensureAnimAgent(pc) then
        self:SetStatus("AnimAgent 未就绪")
        return
    end

    local files = UE.UAnimGenClient.OpenFileDialog(
        "选择 UGC 资产包或模型", "", "UGC Asset (*.glb;*.gltf;*.zip;*.ugcpkg)|*.glb;*.gltf;*.zip;*.ugcpkg", false)
    if not files or files:Num() == 0 then
        self:SetStatus("已取消导入")
        return
    end

    local Core = require("Gameplay.AnimAgent.AnimAgentCore")
    local packageID = Core:ImportLocal(files:Get(1), "")  -- UnLua TArray:Get 是 1-based
    if packageID == "" then
        self:SetStatus("导入失败 — 检查日志")
        return
    end

    self:SetStatus(string.format("导入完成 [%s]，已加入预制体列表", packageID:sub(1, 8)))
    -- 刷新 placeable 面板，新资产以 pkg:{package}:main 出现在 "UGC 资产" 分类下
    self:RebuildPrefabList()
end

--============================================================
-- 按钮事件
--============================================================

function M:OnClickPrefab(prefabName)
    EditorCore:SelectPrefab(prefabName)
    self:SetStatus("放置模式: " .. prefabName .. "  （点击场景放置，ESC 取消）")
end

function M:OnClickPlay()
    local state = EditorCore:GetState()
    if state == "Edit" then
        if EditorCore:EnterPlayMode() then
            self:SetStatus("试玩模式 — 按 F2 返回编辑")
        else
            self:SetStatus("无法进入试玩：请检查 Playtest Pawn 配置或 Authority")
        end
    else
        EditorCore:EnterEditMode()
    end
end

--- T14 自动保存需要随时取到 editorState：每次调用都重新解析蓝图编辑器窗口，
--- 避免把 Widget 实例长期缓存在持久服务里。
local function editorStateProvider()
    local ok, UIManager = pcall(require, "Gameplay.Core.UIManager")
    local bpInst = ok and UIManager and UIManager:GetWindow("WBP_UGCBlueprintEditor") or nil
    return {
        activeProgramId = bpInst and bpInst.GetActiveID and bpInst:GetActiveID() or "level_main",
    }
end

function M:OnClickSave()
    local bridge = EditorCore:GetBridge()
    if not bridge then self:SetStatus("保存失败：EditorBridge 不可用"); return end

    local UIManager = require("Gameplay.Core.UIManager")
    local bpInst = UIManager:GetWindow("WBP_UGCBlueprintEditor")
    if bpInst and bpInst.SaveCurrentGraphToSceneData then bpInst:SaveCurrentGraphToSceneData() end

    local defDir = UE.UKismetSystemLibrary.GetProjectDirectory() .. "Saved/UGC/"
    local picked
    if bridge:SupportsNativeFileDialogs() then
        picked = bridge:ShowSaveFileDialog(
            "保存 UGC 项目", defDir, "my_scene.ugc.json", "UGC 项目|*.ugc.json|JSON 文件|*.json")
        if not picked or picked == "" then self:SetStatus("保存已取消"); return end
    else
        picked = defDir .. "project.ugc.json"
    end

    local SceneData = require("Gameplay.UGC.UGCSceneData")
    local ok, result = Persistence:SaveProject(picked, SceneData, {
        activeProgramId = bpInst and bpInst.GetActiveID and bpInst:GetActiveID() or "level_main",
    })
    if ok then
        -- 绑定项目后自动保存才有目标路径（T14）；editorState 走惰性 provider，不缓存 Widget
        Persistence:AttachProject(result, SceneData, editorStateProvider)
        self:SetStatus("UGC 项目已原子保存 → " .. tostring(result))
        Log("保存成功: " .. tostring(result))
    else
        self:SetStatus("保存失败: " .. tostring(result))
        Warn("保存失败: " .. tostring(result))
    end
end

function M:OnClickLoad()
    local bridge = EditorCore:GetBridge()
    if not bridge then self:SetStatus("加载失败：EditorBridge 不可用"); return end

    local defDir = UE.UKismetSystemLibrary.GetProjectDirectory() .. "Saved/UGC/"
    local path
    if bridge:SupportsNativeFileDialogs() then
        path = bridge:ShowOpenFileDialog(
            "加载 UGC 项目", defDir, "UGC 项目|*.ugc.json|旧版场景|scene.json|JSON 文件|*.json")
        if not path or path == "" then self:SetStatus("加载已取消"); return end
    else
        path = defDir .. "project.ugc.json"
    end

    self:ShowLoading("场景加载中…")
    self:ClearTransformInputs()

    local SceneData = require("Gameplay.UGC.UGCSceneData")
    local ok, result, loadInfo = Persistence:LoadProject(path, SceneData)
    if not ok then
        self:HideLoading()
        self:SetStatus("加载失败: " .. tostring(result))
        Warn("加载失败: " .. tostring(result))
        return
    end

    -- 绑定项目（T14）：此后 Tick 驱动的自动保存会写回同一路径
    Persistence:AttachProject(result, SceneData, editorStateProvider)

    local doneMsg = "UGC 项目已加载 ← " .. tostring(result)
    if loadInfo and loadInfo.recovered then
        -- 崩溃恢复：主文件不可用，已回退到备份世代，必须让玩家看见这件事
        doneMsg = doneMsg .. "（主文件不可用，已从备份恢复: " .. tostring(loadInfo.from) .. "）"
        Warn("已从备份恢复: " .. tostring(loadInfo.from))
    end
    local pc = self:GetOwningPlayer()
    if pc and pc.ScheduleCallback then
        pc:ScheduleCallback(function()
            self:HideLoading()
            self:SetStatus(doneMsg)
        end, 3)
    else
        self:HideLoading()
        self:SetStatus(doneMsg)
    end
end

function M:OnClickClear()
    EditorCore:ClearScene()
    self:SetStatus("场景已清空")
    self:ClearTransformInputs()
end

function M:OnClickDelete()
    EditorCore:DeleteSelected()
    self:SetStatus("已删除选中物体")
    self:ClearTransformInputs()
end

function M:OnClickUndo()
    EditorCore:Undo()
    self:SetStatus("撤销完成")
    self:RefreshTransformInputs()
end

function M:OnClickBlueprint()
    -- ★ 延迟 1 帧执行：避免在 OnClicked delegate 回调链内部调用 UWidgetBlueprintLibrary.Create，
    --   否则 Lua GC 可能在 C++ 内存分配时触发，__gc(RemoveObject) 与 TryBind(AddObject)
    --   并发修改 UnLua 对象图，导致 0xffffffffffffffff 崩溃。
    local pc = self:GetOwningPlayer()
    if not pc then return end
    local SceneData = require("Gameplay.UGC.UGCSceneData")
    local scriptData = SceneData:GetLevelScript()
    pc:ScheduleCallback(function()
        local UIManager = require("Gameplay.Core.UIManager")
        local name = "WBP_UGCBlueprintEditor"
        local inst = UIManager:GetWindow(name) or UIManager:OpenWindow(name)
        if not inst then self:SetStatus("打开蓝图编辑器失败"); return end
        inst:OpenGraph("level_main", "关卡蓝图 — 全局逻辑", scriptData)
        if pc.SetBlueprintEditor then pc:SetBlueprintEditor(inst) end
        self:SetStatus("关卡蓝图编辑器已打开")
    end, 1)
    self:SetStatus("正在打开关卡蓝图…")
end

--- 选中 Actor 后点击「配置逻辑」，打开该 Actor 专属的蓝图图
function M:OnClickActorBlueprint()
    local sceneID = EditorCore:GetSelectedID()
    if not sceneID then
        self:SetStatus("请先选中一个 Actor")
        return
    end

    local pc = self:GetOwningPlayer()
    if not pc then return end

    -- ★ 延迟 1 帧执行：同 OnClickBlueprint，避免 delegate 回调链内部 Create → TryBind 崩溃
    local SceneData = require("Gameplay.UGC.UGCSceneData")
    local entry     = SceneData:QueryActor(sceneID)
    local programID = (entry and entry.programId) or ("actor_prog_" .. sceneID)
    local scriptData = SceneData:GetScript(programID)
    local title      = "Actor #" .. tostring(sceneID) .. " 蓝图"

    pc:ScheduleCallback(function()
        local UIManager = require("Gameplay.Core.UIManager")
        local name = "WBP_UGCBlueprintEditor"
        local inst = UIManager:GetWindow(name) or UIManager:OpenWindow(name)
        if not inst then self:SetStatus("打开蓝图编辑器失败"); return end
        inst:OpenGraph(programID, title, scriptData)
        if pc.SetBlueprintEditor then pc:SetBlueprintEditor(inst) end
        self:SetStatus(title .. " 已打开")
    end, 1)
    self:SetStatus("正在打开 " .. title .. "…")
end

--- 打开 AI 聊天窗口
function M:OnClickChat()
    local pc = self:GetOwningPlayer()
    if not pc then return end
    pc:ScheduleCallback(function()
        local UIManager = require("Gameplay.Core.UIManager")
        UIManager:ToggleWindow("WBP_UGCChat")
    end, 1)
end

--- 打开 Fab 资产平台面板。
function M:OnClickFab()
    local pc = self:GetOwningPlayer()
    if not pc then
        self:SetStatus("打开 Fab 失败：未找到 PlayerController")
        return
    end

    pc:ScheduleCallback(function()
        local PanelClassPath = "/Game/_UGC/UI/WBP_FabPanel.WBP_FabPanel_C"
        local PanelClass = UE.UClass.Load(PanelClassPath)
        if not PanelClass then
            Warn("加载 WBP_FabPanel 类失败: " .. PanelClassPath)
            self:SetStatus("打开 Fab 面板失败：资源未找到")
            return
        end

        local widget = UE.UWidgetBlueprintLibrary.Create(self, PanelClass, pc)
        if not widget then
            self:SetStatus("打开 Fab 面板失败：CreateWidget 失败")
            return
        end

        widget:AddToViewport(20)
        self:SetStatus("已打开 Fab 资产平台")
    end, 1)
end

--- 根据是否有选中 Actor 控制「配置逻辑」按钮可见性
function M:RefreshActorBlueprintBtn(sceneID)
    if not self.w_btn_Blueprint_Actor then return end
    local vis = sceneID and UE.ESlateVisibility.Visible or UE.ESlateVisibility.Collapsed
    self.w_btn_Blueprint_Actor:SetVisibility(vis)
end

--============================================================
-- Transform 输入框
--============================================================

function M:OnTransformCommit(text, commitType)
    local function readFloat(widget)
        if not widget then return 0 end
        local t = widget:GetText()
        return tonumber(tostring(t)) or 0
    end

    local x   = readFloat(self.w_input_X)
    local y   = readFloat(self.w_input_Y)
    local z   = readFloat(self.w_input_Z)
    local p   = readFloat(self.w_input_P)
    local yaw = readFloat(self.w_input_Yaw)
    local r   = readFloat(self.w_input_R)
    local sx  = readFloat(self.w_input_SX)
    local sy  = readFloat(self.w_input_SY)
    local sz  = readFloat(self.w_input_SZ)

    EditorCore:SetSelectedTransform(x, y, z, p, yaw, r, sx, sy, sz)
end

function M:RefreshTransformInputs()
    local x,y,z, p,yaw,r, sx,sy,sz = EditorCore:GetSelectedTransformValues()
    local function setVal(widget, v, widgetName)
        if widget then
            widget:SetText(string.format("%.1f", v))
        elseif widgetName then
            Warn("RefreshTransformInputs: 缺少控件 " .. widgetName)
        end
    end
    setVal(self.w_input_X,   x,   "w_input_X")
    setVal(self.w_input_Y,   y,   "w_input_Y")
    setVal(self.w_input_Z,   z,   "w_input_Z")
    setVal(self.w_input_P,   p,   "w_input_P")
    setVal(self.w_input_Yaw, yaw, "w_input_Yaw")
    setVal(self.w_input_R,   r,   "w_input_R")
    setVal(self.w_input_SX,  sx,  "w_input_SX")
    setVal(self.w_input_SY,  sy,  "w_input_SY")
    setVal(self.w_input_SZ,  sz,  "w_input_SZ")
end

function M:ClearTransformInputs()
    for _, name in ipairs({"w_input_X","w_input_Y","w_input_Z","w_input_P","w_input_Yaw","w_input_R","w_input_SX","w_input_SY","w_input_SZ"}) do
        if self[name] then
            self[name]:SetText("")
        end
    end
end

--============================================================
-- 视口点击转发（WBP 的 OnMouseButtonDown 事件绑定到这里）
-- 注意：点击逻辑已由 IA_EditorClick → UGCPlayerController:EditorClick() 统一处理，
--       此处仅返回 Handled 消费掉 Slate 事件，不重复调用 OnViewportClick，
--       避免双重触发（InputAction + Widget 各一次）。
--============================================================

function M:OnViewportMouseDown(geometry, pointerEvent)
    return UE.UWidgetBlueprintLibrary.Handled()
end

--============================================================
-- 工具
--============================================================

local _sceneData = nil
local function getSceneData()
    if not _sceneData then
        local ok, sd = pcall(require, "Gameplay.UGC.UGCSceneData")
        if ok then _sceneData = sd end
    end
    return _sceneData
end

function M:SetStatus(msg)
    if self.w_text_Status then
        local sd = getSceneData()
        local dirty = sd and sd:IsDirty()
        self.w_text_Status:SetText(dirty and (msg .. "  ●未保存") or msg)
    else
        Warn("缺少状态文本控件 w_text_Status，消息: " .. tostring(msg))
    end
end

--============================================================
-- 加载遮罩（w_panel_Loading 控件可选，不存在时只禁用交互）
-- WBP_UGCEditor 蓝图结构参考：
--   在根 Overlay 的最顶层加一个 w_panel_Loading（Border 或 Overlay），
--   填满父级，颜色 #CC000000（半透明黑），默认 Visibility = Collapsed；
--   里面放一个居中的 TextBlock 写"加载中…"即可。
--============================================================

function M:ShowLoading(msg)
    -- 显示遮罩
    if self.w_panel_Loading then
        self.w_panel_Loading:SetVisibility(UE.ESlateVisibility.Visible)
        -- 把加载提示写到遮罩内部文本（w_text_Loading 可选）
        if self.w_text_Loading then
            self.w_text_Loading:SetText(msg or "加载中…")
        end
    end
    -- 禁用底部操作栏，防止加载期间误操作（loading 遮罩也能阻挡，双保险）
    if self.w_panel_Bottom then self.w_panel_Bottom:SetIsEnabled(false) end
    self:SetStatus(msg or "加载中…")
end

function M:HideLoading()
    if self.w_panel_Loading then
        self.w_panel_Loading:SetVisibility(UE.ESlateVisibility.Collapsed)
    end
    if self.w_panel_Bottom then self.w_panel_Bottom:SetIsEnabled(true) end
end

--============================================================
-- 网格对齐 UI（控件可选：w_btn_SnapToggle / w_combo_SnapSize）
--============================================================

function M:BuildSnapUI()
    -- Snap 开关按钮
    local btnSnap = self.w_btn_SnapToggle
    if btnSnap then
        -- 设置初始文字
        local textBlock = btnSnap:GetChildAt(0)
        if textBlock then
            textBlock:SetText("Snap: ON")
        end
        -- 绑定点击事件
        bindButton(self, "w_btn_SnapToggle", function()
            local enabled = not EditorCore:GetSnapEnabled()
            EditorCore:SetSnapEnabled(enabled)
            -- 刷新按钮文字
            local tb = self.w_btn_SnapToggle:GetChildAt(0)
            if tb then
                tb:SetText(enabled and "Snap: ON" or "Snap: OFF")
            end
        end)
    else
        Warn("BuildSnapUI: 未找到 w_btn_SnapToggle（可在蓝图中添加以启用 Snap 切换按钮）")
    end

    -- 网格尺度下拉框
    local combo = self.w_combo_SnapSize
    if combo then
        -- 添加尺度选项
        for _, v in ipairs({ "5", "25", "50", "100", "200" }) do
            combo:AddOption(v)
        end
        -- 默认选中 50
        combo:SetSelectedOption("50")
        -- 绑定选项变化事件
        combo.OnSelectionChanged:Add(self, function(val, selType)
            local size = tonumber(val)
            if size then
                EditorCore:SetSnapSize(size)
                Log("网格尺度设置为: " .. tostring(size))
            end
        end)
    else
        Warn("BuildSnapUI: 未找到 w_combo_SnapSize（可在蓝图中添加以启用尺度选择下拉框）")
    end
end


function M:RefreshPlayButton(state)
    if self.w_btn_Play then
        local label = (state == "Edit") and "▶ 试玩" or "✎ 返回编辑"
        local textBlock = self.w_btn_Play:GetChildAt(0)
        if textBlock then
            textBlock:SetText(label)
        else
            Warn("试玩按钮缺少子文本控件")
        end
    end
end

return M
