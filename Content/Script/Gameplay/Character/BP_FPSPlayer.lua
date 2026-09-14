--[[
    BP_FPSPlayer.lua
    角色 Lua 逻辑（ThirdPerson 方案，全身 Mesh + ABP_Manny）

    职责：
    - 实现 BI_PlayerInterface，为 ABP_Manny 提供左手 IK 数据和 HandSway 数据
    - 每帧同步 HasWeapon 到 ABP_Manny
    - 监听武器槽变化，非主手武器挂到背部插槽

    背部插槽（需在骨骼编辑器手动添加到 spine_03）：
      weapon_back_1   → Primary1 槽
      weapon_back_2   → Primary2 槽
      weapon_back_pistol → Pistol 槽

    绑定：BP_FPSPlayer → UnLuaInterface → GetModuleName = "Gameplay.Character.BP_FPSPlayer"
]]

local M = UnLua.Class()

-- 槽索引（C++ SlotWeapons 数组 0-based）对应的背部插槽名
-- Primary1=0, Primary2=1, Pistol槽=2（默认拳头，无背部插槽）
local BACK_SOCKETS = {
    [0] = "weapon_back_1",
    [1] = "weapon_back_2",
}

local LEFT_HAND_SOCKET = "LeftHandSocket"
local RIGHT_HAND_SOCKETS = { "RightHandSocket", "GripSocket", "GripPoint" }

function M:ReceiveBeginPlay()
    -- 每次重生/开始游戏时清空武器槽位
    self:ClearAllWeapons()

    -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] ReceiveBeginPlay 触发", true, true, UE.FLinearColor(0,1,0,1), 10)

    if self.WeaponSlotComp then
        UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] WeaponSlotComp 存在", true, true, UE.FLinearColor(0,1,0,1), 10)
        self.WeaponSlotComp.OnActiveWeaponChanged:Add(self, function(OldSlot, NewSlot)
            UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] OnActiveWeaponChanged 触发!", true, true, UE.FLinearColor(0,1,0,1), 10)
            self:RefreshWeaponAttachments()
        end)
        self.WeaponSlotComp.OnWeaponSlotChanged:Add(self, function(Slot)
            UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] OnWeaponSlotChanged 触发!", true, true, UE.FLinearColor(0,1,0,1), 10)
            self:RefreshWeaponAttachments()
        end)
    else
        -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] WeaponSlotComp 为空!", true, true, UE.FLinearColor(1,0,0,1), 10)
    end

    -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] 即将调用 UpdateAnimClass", true, true, UE.FLinearColor(1,0.5,0,1), 10)
    self:UpdateAnimClass()

    -- 延迟0.3s检查武器是否生成（C++武器生成在Super::BeginPlay之后）
    -- UE.UKismetSystemLibrary.K2_SetTimer(self, "DebugCheckWeapons", 0.3, false)
end

-- 清空所有武器槽位（在每次重生/BeginPlay时调用）
function M:ClearAllWeapons()
    if not self.WeaponSlotComp then return end

    local Dummy = UE.FInventoryItem()
    self.WeaponSlotComp:RemoveWeaponFromSlot(UE.EFPSWeaponSlot.Primary1, Dummy)
    self.WeaponSlotComp:RemoveWeaponFromSlot(UE.EFPSWeaponSlot.Primary2, Dummy)
    self.WeaponSlotComp:RemoveWeaponFromSlot(UE.EFPSWeaponSlot.Pistol, Dummy)

    UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] 已清空默认初始武器", true, true, UE.FLinearColor(0.5, 0.5, 0.5, 1), 5)
end

function M:DebugCheckWeapons()
    if not self.WeaponSlotComp then return end
    local w = self.WeaponSlotComp:GetActiveWeapon()
    -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] 0.3s后 ActiveWeapon=" .. tostring(w), true, true, UE.FLinearColor(1,0.5,0,1), 15)
    local n = self.WeaponSlotComp.SlotWeapons:Num()
    for i = 1, n do
        local sw = self.WeaponSlotComp.SlotWeapons[i]
        -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] Slot[" .. i .. "]=" .. tostring(sw), true, true, UE.FLinearColor(1,0.5,0,1), 15)
    end
end

-- 武器槽变化时刷新所有武器的挂点（主手 / 背部）
function M:RefreshWeaponAttachments(...)
    if not self.WeaponSlotComp then return end

    local ActiveWeapon = self.WeaponSlotComp:GetActiveWeapon()
    local Mesh = self.Mesh
    if not Mesh then return end

    local Weapons = self.WeaponSlotComp.SlotWeapons
    local n = Weapons:Num()

    for i = 1, n do
        local Weapon = Weapons[i]
        if Weapon then
            if Weapon == ActiveWeapon then
                -- 主手：C++ 已经 AttachToComponent(hand_r)，只需确保可见
                Weapon:SetActorHiddenInGame(false)
            else
                -- 非主手：挂到背部插槽并显示（BACK_SOCKETS 按 0-based 槽索引）
                local Socket = BACK_SOCKETS[i - 1]
                if Socket then
                    Weapon:K2_AttachToComponent(
                        Mesh, Socket,
                        UE.EAttachmentRule.SnapToTarget,
                        UE.EAttachmentRule.SnapToTarget,
                        UE.EAttachmentRule.SnapToTarget,
                        false
                    )
                    Weapon:SetActorHiddenInGame(false)
                end
            end
        end
    end

    -- 武器槽变化时同步 AnimClass
    self:UpdateAnimClass()
end

-- 根据是否持枪切换 AnimClass
function M:UpdateAnimClass()
    local Mesh = self.Mesh
    if not Mesh then
        -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] UpdateAnimClass: Mesh 为空!", true, true, UE.FLinearColor(1,0,0,1), 10)
        return
    end

    local HasWeapon = self.WeaponSlotComp and self.WeaponSlotComp:GetActiveWeapon() ~= nil
    -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] UpdateAnimClass HasWeapon=" .. tostring(HasWeapon), true, true, UE.FLinearColor(1,1,0,1), 10)

    if HasWeapon then
        local cls = UE.UClass.Load("/Game/FPS/Migrate/ABP_Manny.ABP_Manny_C")
        -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] 切换到 ABP_Manny, cls=" .. tostring(cls), true, true, UE.FLinearColor(0,1,1,1), 10)
        if cls then Mesh:SetAnimClass(cls) end
    else
        local cls = UE.UClass.Load("/Game/ShootingAI/Characters/Mannequins/Animations/ABP_UEDefault_Manny.ABP_UEDefault_Manny_C")
        -- UE.UKismetSystemLibrary.PrintString(self, "[FPSPlayer] 切换到 NoWeapon ABP, cls=" .. tostring(cls), true, true, UE.FLinearColor(0,1,1,1), 10)
        if cls then Mesh:SetAnimClass(cls) end
    end

    -- 切换完成后主动同步一次状态
    self:SyncMovementMode()
end

-- 同步 Movement Mode 到动画蓝图
function M:SyncMovementMode()
    local Mesh = self.Mesh
    if not Mesh then return end

    local AnimInst = Mesh:GetAnimInstance()
    if not AnimInst or not UE.UKismetSystemLibrary.IsValid(AnimInst) then return end

    local MovComp = self.CharacterMovement
    if not MovComp then return end

    -- 只在 ABP_Manny 时写 Movement Mode
    local animClass = AnimInst:GetClass()
    if not self.MannyClassCache then
        self.MannyClassCache = UE.UClass.Load("/Game/FPS/Migrate/ABP_Manny.ABP_Manny_C")
    end

    if animClass == self.MannyClassCache then
        AnimInst["Movement Mode"] = MovComp.MovementMode
    end
end

-- 角色 MovementMode 发生变化时由引擎回调（代替每帧 Tick 更新）
function M:K2_OnMovementModeChanged(PrevMovementMode, NewMovementMode, PrevCustomMode, NewCustomMode)
    self:SyncMovementMode()
end

-- ── BI_PlayerInterface 实现 ──────────────────────────────────────────
-- ABP_Manny 每帧通过接口调用，BP 侧接口函数体为空（Entry→Return）
-- UnLua 拦截 ProcessEvent 后路由到此处

-- 返回当前武器左手握持点的 Component Space Transform（供 ABP_Manny FABRIK/TwoBoneIK 使用）
-- 只传位置，旋转置零——避免 FABRIK EffectorRotationSource=CopyFromTarget 时拷贝错误旋转导致手扭曲
local function MakeComponentSpaceTransform(WorldTransform, charMesh)
    local meshLoc = charMesh:K2_GetComponentLocation()
    local meshRot = charMesh:K2_GetComponentRotation()
    local meshWorldT = UE.UKismetMathLibrary.MakeTransform(meshLoc, meshRot, UE.FVector(1, 1, 1))
    return UE.UKismetMathLibrary.MakeRelativeTransform(WorldTransform, meshWorldT)
end

local function GetCurrentHandComponentTransform(charMesh, HandSocketName)
    if not charMesh then return UE.FTransform() end

    local handWorldT = charMesh:GetSocketTransform(HandSocketName, 0)
    return MakeComponentSpaceTransform(handWorldT, charMesh)
end

local function FindFirstSocket(Mesh, SocketNames)
    if not Mesh then return nil end

    for _, SocketName in ipairs(SocketNames) do
        if Mesh:DoesSocketExist(SocketName) then
            return SocketName
        end
    end

    return nil
end

function M:SetAnimValue(Name, Value)
    local Mesh = self.Mesh
    if not Mesh then return end

    local AnimInst = Mesh:GetAnimInstance()
    if AnimInst and UE.UKismetSystemLibrary.IsValid(AnimInst) then
        AnimInst[Name] = Value
    end
end

function M:UpdateRightHandIK(WeaponMesh, charMesh)
    local SocketName = FindFirstSocket(WeaponMesh, RIGHT_HAND_SOCKETS)
    if not SocketName or not charMesh then
        self:SetAnimValue("RightHandIKAlpha", 0)
        self:SetAnimValue("RightHandSocketTransform", GetCurrentHandComponentTransform(charMesh, "hand_r"))
        return
    end

    local socketWorldT = WeaponMesh:GetSocketTransform(SocketName, 0)
    self:SetAnimValue("RightHandSocketTransform", MakeComponentSpaceTransform(socketWorldT, charMesh))
    self:SetAnimValue("RightHandIKAlpha", 0)
end

function M:IF_GetLeftHandSocketTransform()
    local charMesh = self.Mesh
    if not self.WeaponSlotComp then
        self:SetAnimValue("LeftHandIKAlpha", 0)
        self:UpdateRightHandIK(nil, charMesh)
        return GetCurrentHandComponentTransform(charMesh, "hand_l")
    end

    local Weapon = self.WeaponSlotComp:GetActiveWeapon()
    if not Weapon then
        self:SetAnimValue("LeftHandIKAlpha", 0)
        self:UpdateRightHandIK(nil, charMesh)
        return GetCurrentHandComponentTransform(charMesh, "hand_l")
    end

    local WeaponMesh = Weapon.WeaponMesh
    if not WeaponMesh or not charMesh then
        self:SetAnimValue("LeftHandIKAlpha", 0)
        self:UpdateRightHandIK(WeaponMesh, charMesh)
        return GetCurrentHandComponentTransform(charMesh, "hand_l")
    end

    self:UpdateRightHandIK(WeaponMesh, charMesh)

    if not WeaponMesh:DoesSocketExist(LEFT_HAND_SOCKET) then
        self:SetAnimValue("LeftHandIKAlpha", 0)
        return GetCurrentHandComponentTransform(charMesh, "hand_l")
    end

    self:SetAnimValue("LeftHandIKAlpha", 0.85)

    -- 用分步函数获取 Mesh Component 世界坐标（BlueprintCallable UFUNCTION，比 K2_GetComponentToWorld 更稳定）
    local socketWorldT = WeaponMesh:GetSocketTransform(LEFT_HAND_SOCKET, 0)
    return MakeComponentSpaceTransform(socketWorldT, charMesh)
end

-- 返回手部晃动数据给 ABP_Manny（SideMovement, MouseX, MouseY）
function M:IF_GetHandSwayFloats()
    local CtrlRot = self:GetControlRotation()
    local Vel = self:GetVelocity()
    local Right = UE.UKismetMathLibrary.GetRightVector(CtrlRot)
    local Side = UE.UKismetMathLibrary.Dot_VectorVector(Vel, Right)
    return Side, 0, 0  -- TODO: 替换为真实鼠标帧增量
end

return M
