--[[
    Shared allowlists for UGC graph nodes and AI tools.
    Public inputs use stable IDs; raw asset class paths are never model-facing.
]]

local Policy = {}

Policy.Attributes = { "Health", "MaxHealth", "Armor", "MovementSpeed", "Stamina" }
Policy.Rules = { "RoundTime", "RespawnDelay", "FriendlyFire", "GravityScale" }
Policy.Weapons = { "WPN_Rifle_AK47", "WPN_Pistol_Glock" }
Policy.AbilityIDs = { "WeaponFire", "WeaponReload", "WeaponMelee" }
Policy.AbilityPaths = {
    WeaponFire = "/Game/_FPS/Weapon/BP_GA_WeaponFire.BP_GA_WeaponFire_C",
    WeaponReload = "/Game/_FPS/Weapon/BP_GA_WeaponReload.BP_GA_WeaponReload_C",
    WeaponMelee = "/Game/_FPS/Weapon/BP_GA_WeaponMelee.BP_GA_WeaponMelee_C",
}
Policy.PCGGraphPaths = { "" }

return Policy
