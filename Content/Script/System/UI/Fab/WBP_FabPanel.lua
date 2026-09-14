--[[
    WBP_FabPanel.lua
    Fab 平台面板（路线 B 核心 UMG）

    控件树（必须"Is Variable"勾选，命名严格对齐；和 UGCEditor 一致的 w_ 前缀规范）：
      Root (Canvas Panel)
      └── Border        w_border_Root         -- 整张面板外壳
          └── Vertical Box
              ├── Horizontal Box  w_panel_Title
              │   ├── Text Block   w_text_Title       ("Fab 资产平台")
              │   └── Button       w_btn_Close        (子 Text "✕")
              ├── WebBrowser      w_browser_Web      -- 真正的 CEF 承载
              └── Horizontal Box  w_panel_Status
                  ├── Text Block   w_text_Status      -- 下载进度 / 错误提示
                  └── Progress Bar w_bar_Progress     -- Visibility 默认 Collapsed

    架构说明：
    - UnLua 对 UMG 的大部分反射都支持，所以 LoadURL / ExecuteJavascript / 多播订阅
      都直接在 Lua 里做，BP 图**不需要**画任何 Custom Event
    - 唯一例外：用户关掉面板想回到 UGC 编辑器这种"跨 Widget 容器"动作，可以直接
      `self:RemoveFromParent()` 或通过 BP 在 OnVisibilityChanged 里补操作
    - 下载完成事件通过 UFabClientBridge::OnDownloadCompleted 多播回来（动态 delegate 多播
      UnLua 友好）；UFabUrlDispatcher.Dispatch 是 fire-and-forget
]]

local WBP_FabPanel = UnLua.Class()

local LOG_TAG = "[System.UI.Fab.WBP_FabPanel]"
local function Log(s) print(LOG_TAG .. " " .. tostring(s)) end
local function Warn(s) print(LOG_TAG .. "[Warn] " .. tostring(s)) end

local function AppendPanelLog(action, detail)
    local line = string.format("[%s] %s %s\n",
        os.date("%Y-%m-%d %H:%M:%S"),
        tostring(action or ""),
        tostring(detail or ""))
    Log(line:gsub("\n$", ""))

    pcall(function()
        local dir = UE.UKismetSystemLibrary.GetProjectDirectory() .. "Saved/Fab/"
        UE.UKismetSystemLibrary.MakeDirectory(dir)
        local f = io.open(dir .. "panel_actions.log", "a")
        if f then
            f:write(line)
            f:close()
        end
    end)
end

local function TextToString(text)
    if text == nil then return "" end
    if type(text) == "string" then return text end
    if text.ToString then
        local ok, result = pcall(function() return text:ToString() end)
        if ok and result ~= nil then return tostring(result) end
    end
    return tostring(text)
end

local function WithUEClientFlag(url)
    local s = tostring(url or "")
    if s == "" or s:find("ue_client=1", 1, true) then return s end
    local sep = s:find("?", 1, true) and "&" or "?"
    return s .. sep .. "ue_client=1"
end

local function RefreshUGCEditorPrefabList()
    local ok, UIManager = pcall(require, "Gameplay.Core.UIManager")
    if not ok or not UIManager or not UIManager.GetWindow then
        AppendPanelLog("RefreshUGCEditorSkipped", "UIManager unavailable")
        return
    end

    local editor = UIManager:GetWindow("WBP_UGCEditor")
    if editor and editor.RebuildPrefabList then
        local okRefresh, err = pcall(function() editor:RebuildPrefabList() end)
        if okRefresh then
            AppendPanelLog("RefreshUGCEditorOK", "prefab list rebuilt")
        else
            AppendPanelLog("RefreshUGCEditorFailed", tostring(err))
        end
    else
        AppendPanelLog("RefreshUGCEditorSkipped", "WBP_UGCEditor not open")
    end
end

--============================================================
-- 生命周期
--============================================================

function WBP_FabPanel:Construct()
    self.BaseUrl   = "http://111.229.172.143:8765"
    self.LastGoodUrl = ""
    self.PendingDownloads = {}
    self.Initialized = false
    AppendPanelLog("Construct", "FabPanel opening")

    -- 1) 拿 FabClient（单例）
    local okMod, FabClient = pcall(function()
        return require("Gameplay.Fab.FabClient")
    end)
    if not okMod or not FabClient then
        self:SetStatus("加载 FabClient 失败", true)
        return
    end
    self.FabClient = FabClient

    -- 2) 拿 PlayerController
    local pc = nil
    pcall(function()
        pc = UE.UGameplayStatics.GetPlayerController(self, 0)
    end)
    if not pc then
        self:SetStatus("未找到 PlayerController", true)
        return
    end

    if not FabClient:Init(pc) then
        self:SetStatus("FabClient 初始化失败", true)
        return
    end
    self.Bridge = FabClient:GetBridge()
    if not self.Bridge then
        self:SetStatus("未找到 FabClientBridge 组件", true)
        return
    end

    -- 3) 读配置里的 BaseUrl
    pcall(function()
        local cfg = UE.UFabConfig.Get()
        if cfg and cfg.BaseUrl and cfg.BaseUrl ~= "" then
            self.BaseUrl = cfg.BaseUrl
        end
    end)

    -- 4) 关闭按钮
    if self.w_btn_Close and self.w_btn_Close.OnClicked then
        self.w_btn_Close.OnClicked:Add(self, WBP_FabPanel.OnClickClose)
    else
        Warn("w_btn_Close 没有暴露为变量 / 没有 OnClicked")
    end

    -- 5) WebBrowser 事件订阅（UnLua 支持 BP 多播 :Add）
    if self.w_browser_Web then
        if self.w_browser_Web.OnUrlChanged then
            self.w_browser_Web.OnUrlChanged:Add(self, WBP_FabPanel.OnWebUrlChanged)
        end
        if self.w_browser_Web.OnLoadCompleted then
            self.w_browser_Web.OnLoadCompleted:Add(self, WBP_FabPanel.OnWebLoadCompleted)
        end
    else
        Warn("w_browser_Web 控件缺失，请检查控件命名")
    end

    -- 6) Bridge 多播订阅
    if self.Bridge.OnDownloadProgress then
        self.Bridge.OnDownloadProgress:Add(self, WBP_FabPanel.OnDownloadProgress)
    end
    if self.Bridge.OnDownloadCompleted then
        self.Bridge.OnDownloadCompleted:Add(self, WBP_FabPanel.OnDownloadCompleted)
    end
    if self.Bridge.OnAuthExpired then
        self.Bridge.OnAuthExpired:Add(self, WBP_FabPanel.OnAuthExpired)
    end

    -- 7) 初始 UI 状态 + 导航
    self:SetStatus("加载中…", false)
    self:SetProgress(-1)

    if self.w_browser_Web and self.w_browser_Web.LoadURL then
        local entryUrl = WithUEClientFlag(self.BaseUrl)
        AppendPanelLog("LoadURL", entryUrl)
        self.w_browser_Web:LoadURL(entryUrl)
    end

    self.Initialized = true
    AppendPanelLog("ConstructDone", string.format("BaseUrl=%s", self.BaseUrl))
end

function WBP_FabPanel:Destruct()
    -- UnLua 会在 Widget 销毁时自动解绑，但显式 Remove 更稳
    if self.Bridge then
        pcall(function() self.Bridge.OnDownloadProgress:Remove(self, WBP_FabPanel.OnDownloadProgress) end)
        pcall(function() self.Bridge.OnDownloadCompleted:Remove(self, WBP_FabPanel.OnDownloadCompleted) end)
        pcall(function() self.Bridge.OnAuthExpired:Remove(self, WBP_FabPanel.OnAuthExpired) end)
    end
    self.PendingDownloads = nil
    AppendPanelLog("Destruct", "FabPanel closed")
end

--============================================================
-- WebBrowser 事件
--============================================================

--- 页面导航：成功或失败后 CEF 都会回调；签名 OnUrlChanged(Text NewURL)
--- UnLua 把 UE.FText 传过来，ToString 取 FString
function WBP_FabPanel:OnWebUrlChanged(NewUrl)
    if not self.Initialized then return end
    local url = TextToString(NewUrl)
    if url == "" then return end
    AppendPanelLog("UrlChanged", url)

    if self:_isFabScheme(url) then
        AppendPanelLog("FabScheme", url)

        -- 回退页面，避免 CEF 停在 "unsupported scheme" 错误页
        local back = (self.LastGoodUrl ~= "" and self.LastGoodUrl) or self.BaseUrl
        if self.w_browser_Web and self.w_browser_Web.LoadURL then
            AppendPanelLog("LoadURL.Back", back)
            self.w_browser_Web:LoadURL(back)
        end

        -- 派发（fire-and-forget，结果走 OnDownloadCompleted）
        local ok, err = UE.UFabUrlDispatcher.Dispatch(self.Bridge, url)
        if not ok then
            AppendPanelLog("DispatchFailed", err and tostring(err.Message) or "unknown")
            self:SetStatus("请求失败: " .. (err and tostring(err.Message) or "unknown"), true)
        else
            AppendPanelLog("DispatchOK", url)
            self:SetStatus("处理请求: " .. url, false)
        end
        return
    end

    -- 普通导航，记为 last good
    self.LastGoodUrl = url
end

--- 页面加载完成：注 cookie + 注 UE 客户端标识
--- 注意：签名 OnLoadCompleted() 无参数，URL 得现查 w_browser_Web:GetUrl()
function WBP_FabPanel:OnWebLoadCompleted()
    if not self.Initialized then return end
    local currentUrl = ""
    if self.w_browser_Web and self.w_browser_Web.GetUrl then
        pcall(function() currentUrl = tostring(self.w_browser_Web:GetUrl() or "") end)
    end
    AppendPanelLog("LoadCompleted", currentUrl)

    local access  = self.FabClient:GetAccessToken()  or ""
    local refresh = self.FabClient:GetRefreshToken() or ""
    local downloaded = {}
    pcall(function()
        downloaded = self.FabClient:GetDownloadedFabIds() or {}
    end)

    -- access_token 里可能含特殊字符（JWT 本身是 base64url，不会有 "，但保险起见 escape）
    local function esc(s) return (tostring(s):gsub('"', '\\"')) end
    local function idsToJson(ids)
        local out = {}
        for _, id in ipairs(ids or {}) do
            local n = tonumber(id)
            if n then
                table.insert(out, tostring(n))
            else
                table.insert(out, '"' .. esc(id) .. '"')
            end
        end
        return "[" .. table.concat(out, ",") .. "]"
    end

    local js = string.format([[
(function(){
  document.cookie = "access_token=%s; path=/; SameSite=Lax";
  document.cookie = "refresh_token=%s; path=/; SameSite=Lax";
  window.__FAB_UE_CLIENT__ = true;
  localStorage.setItem("fab.ue_client", "1");
  localStorage.setItem("fab.local_asset_ids", JSON.stringify(%s));
})();
]], esc(access), esc(refresh), idsToJson(downloaded))

    if self.w_browser_Web and self.w_browser_Web.ExecuteJavascript then
        self.w_browser_Web:ExecuteJavascript(js)
        AppendPanelLog("InjectState", string.format("has_access=%s downloaded_count=%d",
            access ~= "" and "yes" or "no", #downloaded))
    end

    -- 更新 LastGood（loaded 的页面肯定不是 scheme）
    if self.w_browser_Web and self.w_browser_Web.GetUrl then
        local okGet, u = pcall(function() return self.w_browser_Web:GetUrl() end)
        if okGet and u and u ~= "" then self.LastGoodUrl = u end
    end

    self:SetStatus("就绪", false)
end

--============================================================
-- Bridge 事件
--============================================================

--- 下载进度；签名 (AssetId, BytesReceived, TotalBytes, LocalFilePath)
function WBP_FabPanel:OnDownloadProgress(AssetId, BytesReceived, TotalBytes, LocalPath)
    self.PendingDownloads[AssetId] = true

    local pct = -1
    if TotalBytes and TotalBytes > 0 then
        pct = BytesReceived / TotalBytes
    end
    AppendPanelLog("DownloadProgress", string.format("asset=%s bytes=%s total=%s path=%s",
        tostring(AssetId), tostring(BytesReceived or 0), tostring(TotalBytes or 0), TextToString(LocalPath)))
    self:SetProgress(pct)
    self:SetStatus(string.format("下载中 #%d  %.1f KB",
        AssetId, (BytesReceived or 0) / 1024), false)
end

--- 下载完成（成功/失败都触发）；签名 (AssetId, FFabError, FFabDownloadResult)
function WBP_FabPanel:OnDownloadCompleted(AssetId, Err, Result)
    self:SetProgress(-1)
    self.PendingDownloads[AssetId] = nil

    local msg      = Err and Err.Message and tostring(Err.Message) or ""
    local httpCode = Err and Err.HttpCode or 0
    local bizCode  = Err and Err.BizCode or 0
    local ok = (httpCode == 0 or (httpCode >= 200 and httpCode < 300)) and bizCode == 0

    if not ok then
        AppendPanelLog("DownloadFailed", string.format("asset=%s http=%d biz=%d msg=%s",
            tostring(AssetId), httpCode, bizCode, msg ~= "" and msg or "unknown"))
        self:SetStatus(string.format("下载失败: %s (http=%d biz=%d)",
            msg ~= "" and msg or "unknown", httpCode, bizCode), true)
        return
    end

    local localPath = Result and Result.LocalFilePath and tostring(Result.LocalFilePath) or ""
    local localUuid = Result and Result.LocalUuid and tostring(Result.LocalUuid) or ""
    local sizeBytes = Result and Result.SizeBytes or 0
    AppendPanelLog("DownloadCompleted", string.format("asset=%s uuid=%s size=%s path=%s",
        tostring(AssetId), localUuid, tostring(sizeBytes), localPath))

    local uuid = self.FabClient:RegisterDownloadedAsset({
        AssetId       = AssetId,
        LocalFilePath = localPath,
        LocalUuid     = localUuid,
        SizeBytes     = sizeBytes,
    }, nil)

    if uuid and uuid ~= "" then
        AppendPanelLog("RegisterOK", string.format("asset=%s uuid=%s path=%s",
            tostring(AssetId), uuid, localPath))
        self:SetStatus(string.format("已添加到 Project: %s", uuid), false)
        RefreshUGCEditorPrefabList()
        if self.w_browser_Web and self.w_browser_Web.ExecuteJavascript then
            local js = string.format([[
(function(){
  var id = %d;
  var arr = [];
  try { arr = JSON.parse(localStorage.getItem("fab.local_asset_ids") || "[]"); } catch(e) {}
  if (arr.map(String).indexOf(String(id)) < 0) arr.push(id);
  localStorage.setItem("fab.local_asset_ids", JSON.stringify(arr));
  if (window.FabUE && window.FabUE.markAdded) window.FabUE.markAdded(id);
})();
]], AssetId)
            self.w_browser_Web:ExecuteJavascript(js)
        end
    else
        AppendPanelLog("RegisterFailed", string.format("asset=%s path=%s", tostring(AssetId), localPath))
        self:SetStatus("下载成功但入库失败", true)
    end
end

--- Token 两次都刷新失败 → 关闭面板回登录
function WBP_FabPanel:OnAuthExpired()
    AppendPanelLog("AuthExpired", "closing panel")
    self:SetStatus("登录已过期，请重新登录", true)
    self:Close()
end

--============================================================
-- 操作
--============================================================

function WBP_FabPanel:OnClickClose()
    self:Close()
end

function WBP_FabPanel:Close()
    pcall(function() self:RemoveFromParent() end)
end

--============================================================
-- 状态 UI
--============================================================

function WBP_FabPanel:SetStatus(text, isError)
    if self.w_text_Status then
        pcall(function() self.w_text_Status:SetText(tostring(text or "")) end)
    end
end

--- @param pct number|nil  0.0~1.0 显示；<0 或 nil 隐藏
function WBP_FabPanel:SetProgress(pct)
    if not self.w_bar_Progress then return end
    if not pct or pct < 0 then
        pcall(function() self.w_bar_Progress:SetVisibility(UE.ESlateVisibility.Collapsed) end)
    else
        pcall(function()
            self.w_bar_Progress:SetVisibility(UE.ESlateVisibility.SelfHitTestInvisible)
            self.w_bar_Progress:SetPercent(pct)
        end)
    end
end

--============================================================
-- 内部工具
--============================================================

function WBP_FabPanel:_isFabScheme(url)
    if not url then return false end
    return tostring(url):lower():sub(1, 8) == "uefab://"
end

return WBP_FabPanel
