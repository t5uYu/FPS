--[[
    UIManager.lua
    全局 UI 窗口管理器（单例）

    用法:
        local UIManager = require("Gameplay.Core.UIManager")
        UIManager:Init(playerController)
        UIManager:OpenWindow("UI/Menu/WBP_PauseMenu")
        UIManager:CloseWindow("UI/Menu/WBP_PauseMenu")
        UIManager:ToggleWindow("UI/Menu/WBP_PauseMenu")
        UIManager:CloseAll()
        UIManager:IsOpen("UI/Menu/WBP_PauseMenu")

    新增窗口：在 WindowRegistry 里加一行即可，无需改 C++。
]]

local UIManager = {}
UIManager.__index = UIManager

--============================================================
-- 窗口注册表：逻辑名 → UE 资产路径
-- 新增窗口在这里加一行
--============================================================

local WindowRegistry = {
    ["UI/Menu/WBP_PauseMenu"]  = "/Game/_FPS/System/UI/Menu/WBP_PauseMenu",
    ["UI/Menu/WBP_Settings"]   = "/Game/_FPS/System/UI/Menu/WBP_Settings",
    ["UI/Menu/WBP_MainMenu"]   = "/Game/_FPS/System/UI/Menu/WBP_MainMenu",
    ["UI/Menu/WBP_MapSelect"]  = "/Game/_FPS/System/UI/Menu/WBP_MapSelect",
    ["UI/Menu/WBP_Loadout"]    = "/Game/_FPS/System/UI/Menu/WBP_Loadout",
    ["UI/WBP_InventoryGrid"]   = "/Game/_FPS/System/UI/WBP_InventoryGrid",
    ["UI/WBP_HUD"]             = "/Game/_FPS/System/UI/WBP_HUD",
    -- UGC 编辑器
    ["WBP_UGCEditor"]          = "/Game/_UGC/UI/WBP_UGCEditor",
    ["WBP_UGCChat"]            = "/Game/_UGC/UI/WBP_UGCChat",
    ["WBP_UGCBlueprintEditor"] = "/Game/_UGC/UI/WBP_UGCBlueprintEditor",
}

-- ZOrder 配置（值越大越靠前）
local WindowZOrder = {
    ["UI/WBP_HUD"]             = 0,
    ["UI/WBP_InventoryGrid"]   = 10,
    ["UI/Menu/WBP_PauseMenu"]  = 20,
    ["UI/Menu/WBP_Settings"]   = 30,
    ["UI/Menu/WBP_MainMenu"]   = 20,
    ["UI/Menu/WBP_MapSelect"]  = 30,
    ["UI/Menu/WBP_Loadout"]    = 30,
    ["WBP_UGCEditor"]          = 5,   -- HUD 之上，菜单之下
    ["WBP_UGCChat"]            = 15,
    ["WBP_UGCBlueprintEditor"] = 20,
}

-- HUD is always-on gameplay chrome. It should not enter the modal window stack
-- or switch input mode away from pure gameplay.
local NonInteractiveWindows = {
    ["UI/WBP_HUD"] = true,
}

-- 非全屏窗口尺寸配置（不填则全屏）
-- Size: 像素大小；Position: 左上角偏移（nil = 屏幕居中）
local WindowSize = {
    ["UI/WBP_InventoryGrid"] = { Size = UE.FVector2D(800, 600), Position = nil },
}

--============================================================
-- 内部状态
--============================================================

local _pc           = nil   -- PlayerController（world context）
local _openWindows  = {}    -- name → widget 实例
local _windowStack  = {}    -- 栈（有序，ESC 逐层关）

--============================================================
-- 初始化（在 PlayerController BeginPlay 里调用一次）
--============================================================

function UIManager:Init(playerController)
    _pc = playerController
    _openWindows = {}
    _windowStack = {}
end

--============================================================
-- 内部：加载 Widget 类并创建实例
--============================================================

local function CreateWidget(name)
    local assetPath = WindowRegistry[name]
    if not assetPath then
        print("[UIManager] 未注册的窗口: " .. tostring(name))
        return nil
    end

    -- 从路径解析资产名，构造 Blueprint 类路径（加 _C 后缀）
    local assetName = assetPath:match("([^/]+)$")
    local classPath = assetPath .. "." .. assetName .. "_C"

    local cls = UE.UClass.Load(classPath)
    if not cls then
        print("[UIManager] 加载类失败: " .. classPath)
        return nil
    end

    local widget = UE.UWidgetBlueprintLibrary.Create(_pc, cls, _pc)
    if not widget then
        print("[UIManager] 创建 Widget 失败: " .. name)
        return nil
    end

    return widget
end

--============================================================
-- 内部：输入模式切换
--============================================================

local function SetUIInputMode(enable)
    if not _pc then return end
    if enable then
        _pc:SetInputModeGameAndUI()
    else
        _pc:SetInputModeGameOnly()
    end
end

--============================================================
-- 公开接口
--============================================================

--- 打开窗口，已打开则直接返回已有实例
function UIManager:OpenWindow(name)
    if _openWindows[name] then
        return _openWindows[name]
    end

    local widget = CreateWidget(name)
    if not widget then return nil end

    local zOrder = WindowZOrder[name] or 10
    widget:AddToPlayerScreen(zOrder)

    -- FPSMenuWidgetBase 默认 Collapsed，需要手动调 ShowMenu
    if widget.ShowMenu then
        widget:ShowMenu()
    end

    _openWindows[name] = widget

    if not NonInteractiveWindows[name] then
        table.insert(_windowStack, name)

        -- 有任意交互窗口打开就切到 UI 输入模式
        SetUIInputMode(true)
    end

    return widget
end

--- 关闭指定窗口
function UIManager:CloseWindow(name)
    local widget = _openWindows[name]
    if not widget then return end

    widget:RemoveFromParent()
    _openWindows[name] = nil

    -- 从栈里移除（HUD 等非交互窗口不会在栈中）
    for i = #_windowStack, 1, -1 do
        if _windowStack[i] == name then
            table.remove(_windowStack, i)
            break
        end
    end

    -- 所有窗口关闭后恢复游戏输入
    if #_windowStack == 0 then
        SetUIInputMode(false)
    end
end

--- 打开/关闭切换
function UIManager:ToggleWindow(name)
    if self:IsOpen(name) then
        self:CloseWindow(name)
    else
        self:OpenWindow(name)
    end
end

--- 关闭栈顶窗口（ESC 逐层返回用）
function UIManager:CloseTop()
    if #_windowStack == 0 then return end
    local top = _windowStack[#_windowStack]
    self:CloseWindow(top)
end

--- 关闭所有窗口
function UIManager:CloseAll()
    for name, _ in pairs(_openWindows) do
        local widget = _openWindows[name]
        if widget then
            widget:RemoveFromParent()
        end
    end
    _openWindows = {}
    _windowStack = {}
    SetUIInputMode(false)
end

--- 查询窗口是否已打开
function UIManager:IsOpen(name)
    return _openWindows[name] ~= nil
end

--- 当前是否有任意窗口打开
function UIManager:IsAnyOpen()
    return #_windowStack > 0
end

--- 获取已打开的窗口实例（供外部操作 Widget 控件）
function UIManager:GetWindow(name)
    return _openWindows[name]
end

--- 关卡卸载时调用，清空所有内部状态
-- 不调用 RemoveFromParent（World 正在销毁，Widget 即将随之消亡）
-- 绑定到 PlayerController 的 ReceiveEndPlay，自动触发
function UIManager:Teardown()
    _pc          = nil
    _openWindows = {}
    _windowStack = {}
end

return UIManager
