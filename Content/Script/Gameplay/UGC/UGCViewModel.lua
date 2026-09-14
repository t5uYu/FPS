--[[
    UGCViewModel.lua（T10）

    编辑器 UI 的共享 ViewModel：把「文档事件」翻译成「界面刷新通道」，让界面刷新的触发源
    从 Tick 轮询变成事件驱动，并保证界面关闭之后不会被回调继续引用。

    设计要点：
      * 通道（channel）而不是单个 dirty 标记：一个 ViewModel 服务多个界面（蓝图编辑器 /
        编辑面板 / 大纲），各自只消费自己关心的通道（wires / inspector / outline / toolbar）。
      * 弱引用持有视图：BindView 只记弱引用，视图被 UE 回收后 GetView() 返回 nil；订阅如果
        是在"有视图"的情况下建立的，则与那个视图同生命周期 —— 即使 Destruct 因为异常没有
        被调用，订阅也会在下次广播时被剪掉，不会把死掉的 UObject 一直留在 Lua 侧。
      * 订阅一定可以解绑：Destruct 做 Unsubscribe + UnbindView + DetachSceneData，不留单向引用。
      * 订阅回调一律 pcall 包裹：一个界面的刷新异常不能阻断其它界面的刷新。

    SceneData "changed" 的 kind → 通道映射见 EVENT_CHANNELS；未登记的 kind 保守地刷新所有通道
    （宁可多刷一次，也不要界面停在旧状态）。
]]

local Log = require("Gameplay.UGC.UGCLog")

local ViewModel = {}
ViewModel.__index = ViewModel

ViewModel.CHANNELS = { "wires", "inspector", "outline", "toolbar" }

ViewModel.EVENT_CHANNELS = {
    entity_created          = { "outline", "wires" },
    entity_deleted          = { "outline", "wires", "inspector" },
    entity_restored         = { "outline", "wires" },
    external_created        = { "outline", "wires" },
    transform_changed       = { "wires", "inspector" },
    entity_parent_changed   = { "outline", "wires" },
    entity_property_changed = { "outline", "inspector" },
    program_changed         = { "wires" },
    world_rule_changed      = { "inspector" },
    document_loaded         = { "wires", "inspector", "outline", "toolbar" },
    document_cleared        = { "wires", "inspector", "outline", "toolbar" },
}

function ViewModel.New(name)
    return setmetatable({
        name             = name or "viewmodel",
        subscribers      = {},
        nextSubscriberID = 0,
        dirty            = {},
        viewToken        = setmetatable({}, { __mode = "v" }),   -- 弱引用持有视图
        destroyed        = false,
        sceneData        = nil,
        sceneListener    = nil,
        sceneEventCount  = 0,
    }, ViewModel)
end

--============================================================
-- 视图绑定（弱引用）
--============================================================

function ViewModel:BindView(view)
    if self.destroyed then return false end
    self.viewToken[1] = view
    return true
end

--- 视图还活着就返回它，已经被回收就返回 nil
function ViewModel:GetView()
    return self.viewToken[1]
end

function ViewModel:UnbindView()
    self.viewToken[1] = nil
    return true
end

--============================================================
-- 订阅
--============================================================

--- @return table|nil handle 传给 Unsubscribe 的句柄
function ViewModel:Subscribe(fn)
    if self.destroyed or type(fn) ~= "function" then return nil end
    self.nextSubscriberID = self.nextSubscriberID + 1

    -- 订阅时如果已经绑定了视图，就把订阅跟这个视图绑定（弱引用）
    local current = self.viewToken[1]
    local token
    if current ~= nil then
        token = setmetatable({}, { __mode = "v" })
        token[1] = current
    end

    local handle = { id = self.nextSubscriberID, fn = fn, viewToken = token }
    self.subscribers[#self.subscribers + 1] = handle
    return handle
end

function ViewModel:Unsubscribe(handle)
    if not handle then return false end
    for i = #self.subscribers, 1, -1 do
        if self.subscribers[i] == handle or self.subscribers[i].id == handle.id then
            table.remove(self.subscribers, i)
            return true
        end
    end
    return false
end

--- 剪掉视图已被回收的订阅（Destruct 没被调用时的兜底）
--- @return number removed
function ViewModel:PruneSubscribers()
    local removed = 0
    for i = #self.subscribers, 1, -1 do
        local handle = self.subscribers[i]
        if handle.viewToken and handle.viewToken[1] == nil then
            table.remove(self.subscribers, i)
            removed = removed + 1
        end
    end
    return removed
end

function ViewModel:SubscriberCount()
    return #self.subscribers
end

--============================================================
-- 脏通道
--============================================================

function ViewModel:MarkDirty(channel, payload)
    if self.destroyed then return false end
    channel = channel or "all"
    self:PruneSubscribers()

    local channels
    if channel == "all" then
        self.dirty.all = true
        channels = ViewModel.CHANNELS
    else
        self.dirty[channel] = true
        channels = { channel }
    end

    for _, name in ipairs(channels) do
        -- 复制一份再广播：回调里订阅/退订不应该影响本次遍历
        local snapshot = {}
        for _, handle in ipairs(self.subscribers) do snapshot[#snapshot + 1] = handle end
        for _, handle in ipairs(snapshot) do
            local ok, err = pcall(handle.fn, name, payload)
            if not ok then
                Log.Error("view_refresh_failed", err, { channel = name, viewModel = self.name })
            end
        end
    end
    return true
end

function ViewModel:IsDirty(channel)
    if self.dirty.all then return true end
    return self.dirty[channel] == true
end

--- 取出并清除某个通道的脏标记
function ViewModel:ConsumeDirty(channel)
    if not self:IsDirty(channel) then return false end
    self.dirty[channel] = nil
    return true
end

function ViewModel:ClearDirty(channel)
    if channel then
        self.dirty[channel] = nil
        return true
    end
    self.dirty = {}
    return true
end

function ViewModel:DirtyChannels()
    local channels = {}
    if self.dirty.all then
        for _, name in ipairs(ViewModel.CHANNELS) do channels[#channels + 1] = name end
        return channels
    end
    for _, name in ipairs(ViewModel.CHANNELS) do
        if self.dirty[name] then channels[#channels + 1] = name end
    end
    return channels
end

--============================================================
-- 绑定文档事件
--============================================================

function ViewModel:AttachSceneData(sceneData)
    if not sceneData or self.destroyed then return false end
    self:DetachSceneData()
    self.sceneData = sceneData
    -- 注意：SceneData 的监听是以 listener(payload) 调用的（不带事件名），这里兼容
    -- (eventName, payload) 与 (payload) 两种形态，避免上游改签名时静默失效。
    self.sceneListener = function(first, second)
        local payload = second or first
        if type(payload) ~= "table" or payload.kind == nil then return end
        self:ApplySceneEvent(payload.kind, payload)
    end
    sceneData:Subscribe("changed", self.sceneListener)
    return true
end

function ViewModel:DetachSceneData()
    if self.sceneData and self.sceneListener and type(self.sceneData.Unsubscribe) == "function" then
        self.sceneData:Unsubscribe("changed", self.sceneListener)
    end
    self.sceneData, self.sceneListener = nil, nil
    return true
end

--- 把一次文档事件映射成刷新通道（未知 kind 保守刷新全部）
--- @return table channels
function ViewModel:ApplySceneEvent(kind, payload)
    local channels = ViewModel.EVENT_CHANNELS[kind] or ViewModel.CHANNELS
    self.sceneEventCount = self.sceneEventCount + 1
    for _, channel in ipairs(channels) do
        self:MarkDirty(channel, payload)
    end
    return channels
end

--============================================================
-- 销毁
--============================================================

function ViewModel:Destruct()
    if self.destroyed then return false end
    self:DetachSceneData()
    self.subscribers = {}
    self.dirty = {}
    self:UnbindView()
    self.destroyed = true
    return true
end

function ViewModel:IsDestroyed()
    return self.destroyed
end

return ViewModel
