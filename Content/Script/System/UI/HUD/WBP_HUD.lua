--[[
    WBP_HUD.lua
    Main FPS HUD logic.

    GAS values are owned by AFPSPlayerState and forwarded by UFPSHUDWidget.
    The Lua layer only renders data and exposes small extension points for UGC.
]]

local M = UnLua.Class()

local Config = {
    BarInterpSpeed = 7.0,
    LowHealthPulseSpeed = 2.0,
    DamageIndicatorDuration = 1.0,
    UGCSlotCount = 3,
}

local function Clamp01(value)
    if not value then return 0.0 end
    return math.max(0.0, math.min(1.0, value))
end

local function SafeSetText(widget, text)
    if widget then
        widget:SetText(tostring(text or ""))
    end
end

local function SafeSetVisibility(widget, visible)
    if widget then
        widget:SetVisibility(visible and UE.ESlateVisibility.Visible or UE.ESlateVisibility.Collapsed)
    end
end

local function SafeSetPercent(widget, percent)
    if widget then
        widget:SetPercent(Clamp01(percent))
    end
end

function M:Initialize(Initializer)
    self:ResetHUDState()
end

function M:Construct()
    self:ResetHUDState()
    self:CacheWidgetAliases()

    if self.InitializeHUDFromOwningPlayer then
        self:InitializeHUDFromOwningPlayer()
    end

    self:SetLowHealthOverlayAlpha(0.0)
    self:SetMinimapTitle("MINIMAP")
    for index = 1, Config.UGCSlotCount do
        self:SetUGCSlotVisible(index, false)
    end
end

function M:Destruct()
    self.UGCProviders = {}
end

function M:ResetHUDState()
    self.TargetHealthPercent = 1.0
    self.CurrentHealthPercent = 1.0
    self.TargetArmorPercent = 0.0
    self.CurrentArmorPercent = 0.0
    self.TargetStaminaPercent = 1.0
    self.CurrentStaminaPercent = 1.0
    self.LastSnapshot = {
        Health = 0,
        MaxHealth = 0,
        Stamina = 0,
        MaxStamina = 0,
        Magazine = 0,
        MagazineCapacity = 0,
        ReserveAmmo = 0,
    }
    self.DamageIndicators = {}
    self.StatusEffects = {}
    self.UGCProviders = self.UGCProviders or {}
    self.LowHealthWarning = false
    self.LowHealthPulseTimer = 0.0
end

function M:CacheWidgetAliases()
    self.HealthBar = self.HealthBar or self.w_bar_Health
    self.HealthText = self.HealthText or self.w_text_Health
    self.ArmorBar = self.ArmorBar or self.w_bar_Armor
    self.ArmorText = self.ArmorText or self.w_text_Armor
    self.ArmorBarContainer = self.ArmorBarContainer or self.w_panel_Armor or self.w_bar_Armor
    self.StaminaBar = self.StaminaBar or self.w_bar_Stamina
    self.StaminaText = self.StaminaText or self.w_text_Stamina
    self.AmmoText = self.AmmoText or self.w_text_Ammo
    self.ReserveAmmoText = self.ReserveAmmoText or self.w_text_ReserveAmmo
    self.LowHealthOverlay = self.LowHealthOverlay or self.w_image_LowHealth
    self.MinimapPanel = self.MinimapPanel or self.w_panel_Minimap
    self.MinimapTitleText = self.MinimapTitleText or self.w_text_MinimapTitle
    self.CrosshairText = self.CrosshairText or self.w_text_Crosshair
end

function M:Tick(MyGeometry, InDeltaTime)
    self.CurrentHealthPercent = UE.UKismetMathLibrary.FInterpTo(
        self.CurrentHealthPercent,
        self.TargetHealthPercent,
        InDeltaTime,
        Config.BarInterpSpeed
    )
    self.CurrentArmorPercent = UE.UKismetMathLibrary.FInterpTo(
        self.CurrentArmorPercent,
        self.TargetArmorPercent,
        InDeltaTime,
        Config.BarInterpSpeed
    )
    self.CurrentStaminaPercent = UE.UKismetMathLibrary.FInterpTo(
        self.CurrentStaminaPercent,
        self.TargetStaminaPercent,
        InDeltaTime,
        Config.BarInterpSpeed
    )

    self:UpdateHealthBarVisual(self.CurrentHealthPercent)
    self:UpdateArmorBarVisual(self.CurrentArmorPercent)
    self:UpdateStaminaBarVisual(self.CurrentStaminaPercent)
    self:UpdateDamageIndicators(InDeltaTime)
    self:TickUGCProviders(InDeltaTime)

    if self.LowHealthWarning then
        self.LowHealthPulseTimer = self.LowHealthPulseTimer + InDeltaTime * Config.LowHealthPulseSpeed
        local alpha = (math.sin(self.LowHealthPulseTimer * math.pi * 2) + 1) * 0.25 + 0.1
        self:SetLowHealthOverlayAlpha(alpha)
    end
end

function M:OnHealthChanged(CurrentHealth, MaxHealth, Percentage)
    self.TargetHealthPercent = Clamp01(Percentage)
    self.LastSnapshot.Health = CurrentHealth
    self.LastSnapshot.MaxHealth = MaxHealth
    SafeSetText(self.HealthText, string.format("%.0f / %.0f", CurrentHealth, MaxHealth))
    self:DispatchHudData("Health", {
        Current = CurrentHealth,
        Max = MaxHealth,
        Percent = self.TargetHealthPercent,
    })
end

function M:OnArmorChanged(CurrentArmor, MaxArmor, Percentage)
    self.TargetArmorPercent = Clamp01(Percentage)
    SafeSetText(self.ArmorText, string.format("%.0f", CurrentArmor))
    SafeSetVisibility(self.ArmorBarContainer, CurrentArmor > 0)
    self:DispatchHudData("Armor", {
        Current = CurrentArmor,
        Max = MaxArmor,
        Percent = self.TargetArmorPercent,
    })
end

function M:OnStaminaChanged(CurrentStamina, MaxStamina, Percentage)
    self.TargetStaminaPercent = Clamp01(Percentage)
    self.LastSnapshot.Stamina = CurrentStamina
    self.LastSnapshot.MaxStamina = MaxStamina
    SafeSetText(self.StaminaText, string.format("%.0f / %.0f", CurrentStamina, MaxStamina))
    self:DispatchHudData("Stamina", {
        Current = CurrentStamina,
        Max = MaxStamina,
        Percent = self.TargetStaminaPercent,
    })
end

function M:OnAmmoChanged(CurrentMagazine, MaxMagazine, CurrentReserve)
    self.LastSnapshot.Magazine = CurrentMagazine
    self.LastSnapshot.MagazineCapacity = MaxMagazine
    self.LastSnapshot.ReserveAmmo = CurrentReserve

    SafeSetText(self.AmmoText, string.format("%d", CurrentMagazine))
    SafeSetText(self.ReserveAmmoText, string.format("/ %d", CurrentReserve))
    self:DispatchHudData("Ammo", {
        CurrentMagazine = CurrentMagazine,
        MaxMagazine = MaxMagazine,
        CurrentReserve = CurrentReserve,
    })

    if MaxMagazine > 0 and CurrentMagazine <= math.floor(MaxMagazine * 0.25) and CurrentMagazine > 0 then
        self:FlashAmmoWarning()
    end
end

function M:OnCrosshairSpreadChanged(SpreadAngle)
    if self.CrosshairWidget and self.CrosshairWidget.SetSpread then
        self.CrosshairWidget:SetSpread(SpreadAngle)
    end
end

function M:OnShowHitMarker(bKill)
    if self.CrosshairWidget and self.CrosshairWidget.ShowHitMarker then
        self.CrosshairWidget:ShowHitMarker(bKill)
    elseif self.CrosshairText then
        self.CrosshairText:SetRenderOpacity(bKill and 1.0 or 0.8)
    end
end

function M:OnLowHealthWarning(bShow)
    self.LowHealthWarning = bShow
    if not bShow then
        self.LowHealthPulseTimer = 0.0
        self:SetLowHealthOverlayAlpha(0.0)
    end
end

function M:OnStatusEffectChanged(EffectID, bActive, Icon, RemainingDuration)
    if bActive then
        self:AddStatusEffectIcon(EffectID, Icon, RemainingDuration)
    else
        self:RemoveStatusEffectIcon(EffectID)
    end
end

function M:SetMinimapTitle(title)
    SafeSetText(self.MinimapTitleText, title or "MINIMAP")
end

function M:SetUGCSlotText(index, label, value)
    local widget = self["w_text_UGCSlot" .. tostring(index)]
    if not widget then return end

    local text = label and string.format("%s: %s", label, tostring(value or "")) or tostring(value or "")
    widget:SetText(text)
    widget:SetVisibility(UE.ESlateVisibility.Visible)
end

function M:SetUGCSlotVisible(index, visible)
    SafeSetVisibility(self["w_text_UGCSlot" .. tostring(index)], visible)
end

function M:RegisterUGCHudProvider(providerName, provider)
    if not providerName or not provider then
        return false
    end
    self.UGCProviders[providerName] = provider

    if provider.OnHudRegistered then
        provider:OnHudRegistered(self, self:GetHUDSnapshot())
    end
    return true
end

function M:UnregisterUGCHudProvider(providerName)
    self.UGCProviders[providerName] = nil
end

function M:GetHUDSnapshot()
    local snapshot = {}
    for key, value in pairs(self.LastSnapshot or {}) do
        snapshot[key] = value
    end
    snapshot.HealthPercent = self.TargetHealthPercent
    snapshot.StaminaPercent = self.TargetStaminaPercent
    return snapshot
end

function M:DispatchHudData(dataType, payload)
    for _, provider in pairs(self.UGCProviders or {}) do
        if provider.OnHudData then
            provider:OnHudData(self, dataType, payload)
        end
    end
end

function M:TickUGCProviders(deltaTime)
    for _, provider in pairs(self.UGCProviders or {}) do
        if provider.OnHudTick then
            provider:OnHudTick(self, deltaTime, self:GetHUDSnapshot())
        end
    end
end

function M:UpdateHealthBarVisual(percent)
    SafeSetPercent(self.HealthBar, percent)
    if self.HealthBar then
        local color
        if percent > 0.5 then
            color = UE.FLinearColor(0.2, 0.8, 0.2, 1.0)
        elseif percent > 0.25 then
            color = UE.FLinearColor(0.85, 0.72, 0.2, 1.0)
        else
            color = UE.FLinearColor(0.9, 0.16, 0.12, 1.0)
        end
        self.HealthBar:SetFillColorAndOpacity(color)
    end
end

function M:UpdateArmorBarVisual(percent)
    SafeSetPercent(self.ArmorBar, percent)
end

function M:UpdateStaminaBarVisual(percent)
    SafeSetPercent(self.StaminaBar, percent)
end

function M:SetLowHealthOverlayAlpha(alpha)
    if self.LowHealthOverlay then
        self.LowHealthOverlay:SetRenderOpacity(alpha)
    end
end

function M:ShowDamageIndicator(DamageDirection, DamageAmount)
    table.insert(self.DamageIndicators, {
        Direction = DamageDirection,
        Amount = DamageAmount,
        Timer = Config.DamageIndicatorDuration,
        Alpha = 1.0,
    })
end

function M:UpdateDamageIndicators(deltaTime)
    for index = #self.DamageIndicators, 1, -1 do
        local indicator = self.DamageIndicators[index]
        indicator.Timer = indicator.Timer - deltaTime
        indicator.Alpha = math.max(0, indicator.Timer / Config.DamageIndicatorDuration)
        if indicator.Timer <= 0 then
            table.remove(self.DamageIndicators, index)
        end
    end
end

function M:AddStatusEffectIcon(EffectID, Icon, Duration)
    self.StatusEffects[EffectID] = {
        Icon = Icon,
        Duration = Duration,
        Widget = nil,
    }
end

function M:RemoveStatusEffectIcon(EffectID)
    local effect = self.StatusEffects[EffectID]
    if effect and effect.Widget then
        effect.Widget:RemoveFromParent()
    end
    self.StatusEffects[EffectID] = nil
end

function M:FlashAmmoWarning()
    if self.AmmoFlashAnimation then
        self:PlayAnimation(self.AmmoFlashAnimation)
    elseif self.AmmoText then
        self.AmmoText:SetRenderOpacity(1.0)
    end
end

return M
