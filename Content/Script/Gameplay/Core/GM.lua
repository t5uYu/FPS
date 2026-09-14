--[[
    GM.lua
    GM 调试指令集——开发期作弊/测试工具
    不绑定任何蓝图，由 PlayerController.lua require 后驱动。

    用法（PlayerController.lua）：
        local GM = require("Gameplay.Core.GM")
        GM.Init(self)            -- ReceiveBeginPlay
        GM.Tick(self, DeltaTime) -- ReceiveTick

    默认按键（GM_KEYS 里改）：
      T   —— 给 Primary1 槽默认步枪
      F2  —— 给 Primary2 槽第二把步枪
      F3  —— 给 Pistol 槽手枪
      F4  —— 清空所有武器槽
      F5  —— 满血

    武器蓝图路径在 GM_WEAPONS 里改
]]

-- ── 配置区 ────────────────────────────────────────────────────────────────
local GM_WEAPONS = {
    Primary1 = "/Game/_FPS/Weapon/KA47/BP_Weapon_KA47.BP_Weapon_KA47_C",
    Primary2 = "/Game/_FPS/Blueprints/Weapons/BP_Rifle.BP_Rifle_C",
    Pistol   = "/Game/_FPS/Blueprints/Weapons/BP_Pistol.BP_Pistol_C",
}

local GM_KEYS = nil  -- 延迟初始化，等函数定义完再赋值
-- ─────────────────────────────────────────────────────────────────────────

local GM = {}

-- 每个 PC 实例独立状态
local _state = {}

function GM.Init(pc)
    if not pc:IsLocalPlayerController() then return end
    _state[pc] = { KeyStates = {} }
    pc.PrimaryActorTick.bCanEverTick = true
    pc:SetActorTickEnabled(true)
    UE.UKismetSystemLibrary.PrintString(pc, "[GM] 加载完成，T / F2~F5 可用", true, true, UE.FLinearColor(1,0.5,0,1), 5)
end

function GM.Tick(pc, DeltaTime)
    if not pc:IsLocalPlayerController() then return end
    local s = _state[pc]
    if not s then return end
    for _, binding in ipairs(GM_KEYS) do
        local k = UE.FKey()
        k.KeyName = binding.key
        local down = pc:IsInputKeyDown(k)
        if down and not s.KeyStates[binding.key] then
            UE.UKismetSystemLibrary.PrintString(pc, "[GM] 触发: " .. binding.key, true, true, UE.FLinearColor(1,1,0,1), 5)
            binding.fn(pc)
        end
        s.KeyStates[binding.key] = down
    end
end

-- ── 内部工具 ──────────────────────────────────────────────────────────────
local function GetSlotComp(pc)
    local Pawn = pc.Pawn
    if not Pawn then return nil end
    return Pawn.WeaponSlotComp
end

local function GiveWeapon(pc, SlotEnum, ClassPath)
    local SlotComp = GetSlotComp(pc)
    if not SlotComp then
        UE.UKismetSystemLibrary.PrintString(pc, "[GM] 找不到 WeaponSlotComp", true, true, UE.FLinearColor(1,0,0,1), 5)
        return
    end
    local WeaponClass = UE.UClass.Load(ClassPath)
    if not WeaponClass then
        UE.UKismetSystemLibrary.PrintString(pc, "[GM] 找不到武器蓝图: " .. ClassPath, true, true, UE.FLinearColor(1,0,0,1), 5)
        return
    end
    local Ok = SlotComp:SetWeaponInSlot(SlotEnum, UE.FInventoryItem(), WeaponClass)
    UE.UKismetSystemLibrary.PrintString(pc,
        string.format("[GM] 给武器 %s → 槽 %s %s", ClassPath, tostring(SlotEnum), Ok and "✓" or "✗"),
        true, true, UE.FLinearColor(0,1,0,1), 5)
end

-- ── GM 指令 ────────────────────────────────────────────────────────────────
function GM.GivePrimary1(pc)  GiveWeapon(pc, UE.EFPSWeaponSlot.Primary1, GM_WEAPONS.Primary1) end
function GM.GivePrimary2(pc)  GiveWeapon(pc, UE.EFPSWeaponSlot.Primary2, GM_WEAPONS.Primary2) end
function GM.GivePistol(pc)    GiveWeapon(pc, UE.EFPSWeaponSlot.Pistol,   GM_WEAPONS.Pistol)   end

function GM.ClearWeapons(pc)
    local SlotComp = GetSlotComp(pc)
    if not SlotComp then return end
    local Dummy = UE.FInventoryItem()
    SlotComp:RemoveWeaponFromSlot(UE.EFPSWeaponSlot.Primary1, Dummy)
    SlotComp:RemoveWeaponFromSlot(UE.EFPSWeaponSlot.Primary2, Dummy)
    SlotComp:RemoveWeaponFromSlot(UE.EFPSWeaponSlot.Pistol,   Dummy)
    UE.UKismetSystemLibrary.PrintString(pc, "[GM] 武器槽已清空", true, true, UE.FLinearColor(1,1,0,1), 5)
end

function GM.FullHP(pc)
    local Pawn = pc.Pawn
    if not Pawn then return end
    local ASC = Pawn:GetAbilitySystemComponent()
    if not ASC then return end
    UE.UKismetSystemLibrary.PrintString(pc, "[GM] 满血（TODO：接 GE_FullHP）", true, true, UE.FLinearColor(0,1,1,1), 5)
end

-- 延迟赋值，确保函数已定义
GM_KEYS = {
    { key = "T",  fn = GM.GivePrimary1  },
    { key = "F2", fn = GM.GivePrimary2  },
    { key = "F3", fn = GM.GivePistol    },
    { key = "F4", fn = GM.ClearWeapons  },
    { key = "F5", fn = GM.FullHP        },
}

return GM
