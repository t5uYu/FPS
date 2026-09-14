// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCFunctionBridge.h"
#include "AbilitySystemComponent.h"
#include "GameplayEffectTypes.h"
#include "FPS/FPSCharacter.h"
#include "FPS/GAS/FPSGameplayAbility.h"
#include "FPS/GAS/FPSCombatAttributeSet.h"
#include "FPS/Level/FPSWorldWeapon.h"
#include "FPS/Inventory/Public/ItemDataManager.h"
#include "FPS/Inventory/InventoryTypes.h"
#include "GameFramework/PlayerController.h"
#include "Engine/GameInstance.h"
#include "GameFramework/WorldSettings.h"
#include "Engine/World.h"
#include "Kismet/GameplayStatics.h"

// -----------------------------------------------------------------------
// 属性白名单：允许 SetAttribute / GetAttribute 访问的字段
// -----------------------------------------------------------------------
namespace UGCAttributeWhitelist
{
    static const TMap<FString, float> MinValues = {
        { TEXT("Health"),        0.f   },
        { TEXT("MaxHealth"),     1.f   },
        { TEXT("Armor"),         0.f   },
        { TEXT("MovementSpeed"), 100.f },
        { TEXT("Stamina"),       0.f   },
    };
    static const TMap<FString, float> MaxValues = {
        { TEXT("Health"),        10000.f },
        { TEXT("MaxHealth"),     10000.f },
        { TEXT("Armor"),         10000.f },
        { TEXT("MovementSpeed"), 1200.f  },
        { TEXT("Stamina"),       10000.f },
    };
}

// -----------------------------------------------------------------------
// 规则白名单
// -----------------------------------------------------------------------
namespace UGCRuleWhitelist
{
    static const TMap<FString, float> MinValues = {
        { TEXT("RoundTime"),     60.f  },
        { TEXT("RespawnDelay"),  0.f   },
        { TEXT("FriendlyFire"),  0.f   },
        { TEXT("GravityScale"),  0.1f  },
    };
    static const TMap<FString, float> MaxValues = {
        { TEXT("RoundTime"),     3600.f },
        { TEXT("RespawnDelay"),  60.f   },
        { TEXT("FriendlyFire"),  1.f    },
        { TEXT("GravityScale"),  3.f    },
    };
}

// -----------------------------------------------------------------------
// 构造 / BeginPlay
// -----------------------------------------------------------------------

UUGCFunctionBridge::UUGCFunctionBridge()
{
    PrimaryComponentTick.bCanEverTick = false;
    ResetGameRules();
}

void UUGCFunctionBridge::BeginPlay()
{
    Super::BeginPlay();
}

void UUGCFunctionBridge::BeginPlaytestSession()
{
    if (bPlaytestSessionActive || !HasWriteAuthority()) return;

    static const TCHAR* AttributeNames[] = {
        TEXT("MaxHealth"), TEXT("Health"), TEXT("Armor"),
        TEXT("MovementSpeed"), TEXT("Stamina"),
    };
    PlaytestAttributeSnapshot.Reset();
    for (const TCHAR* Name : AttributeNames)
    {
        const float Value = GetAttribute(Name);
        if (Value >= 0.f) PlaytestAttributeSnapshot.Add(Name, Value);
    }
    PlaytestRuleSnapshot = GameRules;
    bPlaytestSessionActive = true;
}

void UUGCFunctionBridge::EndPlaytestSession()
{
    if (!bPlaytestSessionActive || !HasWriteAuthority()) return;

    if (UAbilitySystemComponent* ASC = GetASC())
    {
        for (const TPair<TSubclassOf<UFPSGameplayAbility>, FGameplayAbilitySpecHandle>& Pair : GrantedHandles)
        {
            ASC->ClearAbility(Pair.Value);
        }
        for (const FActiveGameplayEffectHandle& Handle : AppliedEffectHandles)
        {
            ASC->RemoveActiveGameplayEffect(Handle);
        }
    }
    GrantedHandles.Reset();
    AppliedEffectHandles.Reset();

    for (AFPSWorldWeapon* Weapon : SpawnedWeapons)
    {
        if (IsValid(Weapon)) Weapon->Destroy();
    }
    SpawnedWeapons.Reset();

    static const TCHAR* AttributeRestoreOrder[] = {
        TEXT("MaxHealth"), TEXT("Health"), TEXT("Armor"),
        TEXT("MovementSpeed"), TEXT("Stamina"),
    };
    for (const TCHAR* Name : AttributeRestoreOrder)
    {
        if (const float* Value = PlaytestAttributeSnapshot.Find(Name))
        {
            SetAttribute(Name, *Value);
        }
    }
    PlaytestAttributeSnapshot.Reset();

    const TMap<FString, float> RulesToRestore = PlaytestRuleSnapshot;
    ResetGameRules();
    for (const TPair<FString, float>& Pair : RulesToRestore)
    {
        SetGameRule(Pair.Key, Pair.Value);
    }
    PlaytestRuleSnapshot.Reset();
    bPlaytestSessionActive = false;
}

// -----------------------------------------------------------------------
// 私有辅助
// -----------------------------------------------------------------------

AFPSCharacter* UUGCFunctionBridge::GetFPSCharacter() const
{
    if (const APlayerController* PC = Cast<APlayerController>(GetOwner()))
    {
        return Cast<AFPSCharacter>(PC->GetPawn());
    }
    return nullptr;
}

UAbilitySystemComponent* UUGCFunctionBridge::GetASC() const
{
    if (AFPSCharacter* Char = GetFPSCharacter())
    {
        return Char->GetAbilitySystemComponent();
    }
    return nullptr;
}

UFPSCombatAttributeSet* UUGCFunctionBridge::GetCombatAttributes() const
{
    if (UAbilitySystemComponent* ASC = GetASC())
    {
        return const_cast<UFPSCombatAttributeSet*>(
            ASC->GetSet<UFPSCombatAttributeSet>()
        );
    }
    return nullptr;
}

bool UUGCFunctionBridge::HasWriteAuthority() const
{
    const AActor* OwnerActor = GetOwner();
    return OwnerActor && OwnerActor->HasAuthority();
}

bool UUGCFunctionBridge::IsAbilityClassAllowed(TSubclassOf<UFPSGameplayAbility> AbilityClass) const
{
    if (!AbilityClass) return false;
    static const TSet<FString> AllowedPaths = {
        TEXT("/Game/_FPS/Weapon/BP_GA_WeaponFire.BP_GA_WeaponFire_C"),
        TEXT("/Game/_FPS/Weapon/BP_GA_WeaponReload.BP_GA_WeaponReload_C"),
        TEXT("/Game/_FPS/Weapon/BP_GA_WeaponMelee.BP_GA_WeaponMelee_C"),
    };
    return AllowedPaths.Contains(AbilityClass->GetPathName());
}

// -----------------------------------------------------------------------
// GAS — 技能操作
// -----------------------------------------------------------------------

bool UUGCFunctionBridge::GrantAbility(TSubclassOf<UFPSGameplayAbility> AbilityClass, int32 Level)
{
    if (!HasWriteAuthority() || !IsAbilityClassAllowed(AbilityClass)) return false;

    UAbilitySystemComponent* ASC = GetASC();
    if (!ASC || !ASC->GetOwnerActor()->HasAuthority()) return false;

    // 已经授予过同一类型则跳过
    if (GrantedHandles.Contains(AbilityClass)) return true;

    FGameplayAbilitySpec Spec(AbilityClass, Level, INDEX_NONE, GetOwner());
    FGameplayAbilitySpecHandle Handle = ASC->GiveAbility(Spec);
    if (Handle.IsValid())
    {
        GrantedHandles.Add(AbilityClass, Handle);
        return true;
    }
    return false;
}

bool UUGCFunctionBridge::RemoveAbility(TSubclassOf<UFPSGameplayAbility> AbilityClass)
{
    if (!HasWriteAuthority() || !IsAbilityClassAllowed(AbilityClass)) return false;

    UAbilitySystemComponent* ASC = GetASC();
    if (!ASC || !ASC->GetOwnerActor()->HasAuthority()) return false;

    FGameplayAbilitySpecHandle* Handle = GrantedHandles.Find(AbilityClass);
    if (!Handle) return false;

    ASC->ClearAbility(*Handle);
    GrantedHandles.Remove(AbilityClass);
    return true;
}

bool UUGCFunctionBridge::ApplyEffect(TSubclassOf<UGameplayEffect> EffectClass, float Magnitude)
{
    if (!EffectClass || !HasWriteAuthority()) return false;

    UAbilitySystemComponent* ASC = GetASC();
    if (!ASC) return false;

    FGameplayEffectContextHandle Ctx = ASC->MakeEffectContext();
    Ctx.AddSourceObject(GetOwner());
    FGameplayEffectSpecHandle Spec = ASC->MakeOutgoingSpec(EffectClass, Magnitude, Ctx);
    if (!Spec.IsValid()) return false;

    const FActiveGameplayEffectHandle Handle = ASC->ApplyGameplayEffectSpecToSelf(*Spec.Data.Get());
    if (!Handle.IsValid()) return false;
    if (bPlaytestSessionActive) AppliedEffectHandles.Add(Handle);
    return true;
}

// -----------------------------------------------------------------------
// GAS — 属性操作
// -----------------------------------------------------------------------

bool UUGCFunctionBridge::SetAttribute(const FString& AttributeName, float Value)
{
    if (!HasWriteAuthority()) return false;

    // 白名单检查
    const float* MinPtr = UGCAttributeWhitelist::MinValues.Find(AttributeName);
    const float* MaxPtr = UGCAttributeWhitelist::MaxValues.Find(AttributeName);
    if (!MinPtr || !MaxPtr)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCBridge] SetAttribute: '%s' 不在白名单"), *AttributeName);
        return false;
    }

    // 范围 clamp
    Value = FMath::Clamp(Value, *MinPtr, *MaxPtr);

    UFPSCombatAttributeSet* Attrs = GetCombatAttributes();
    UAbilitySystemComponent* ASC  = GetASC();
    if (!Attrs || !ASC) return false;

    // 通过 GE 临时修改（SetBaseAttributeValueFromReplication 仅服务端有效）
    // 直接用 ForceSetAttributeBaseValue 修改基础值
    FGameplayAttribute Attr;

    if (AttributeName == TEXT("Health"))           Attr = UFPSCombatAttributeSet::GetHealthAttribute();
    else if (AttributeName == TEXT("MaxHealth"))   Attr = UFPSCombatAttributeSet::GetMaxHealthAttribute();
    else if (AttributeName == TEXT("Armor"))       Attr = UFPSCombatAttributeSet::GetArmorAttribute();
    else if (AttributeName == TEXT("MovementSpeed")) Attr = UFPSCombatAttributeSet::GetMovementSpeedAttribute();
    else if (AttributeName == TEXT("Stamina"))     Attr = UFPSCombatAttributeSet::GetStaminaAttribute();
    else return false;

    ASC->SetNumericAttributeBase(Attr, Value);
    return true;
}

float UUGCFunctionBridge::GetAttribute(const FString& AttributeName) const
{
    if (!UGCAttributeWhitelist::MinValues.Contains(AttributeName)) return -1.f;

    const UFPSCombatAttributeSet* Attrs = GetCombatAttributes();
    if (!Attrs) return -1.f;

    if (AttributeName == TEXT("Health"))           return Attrs->GetHealth();
    if (AttributeName == TEXT("MaxHealth"))        return Attrs->GetMaxHealth();
    if (AttributeName == TEXT("Armor"))            return Attrs->GetArmor();
    if (AttributeName == TEXT("MovementSpeed"))    return Attrs->GetMovementSpeed();
    if (AttributeName == TEXT("Stamina"))          return Attrs->GetStamina();

    return -1.f;
}

// -----------------------------------------------------------------------
// 武器操作
// -----------------------------------------------------------------------

AFPSWorldWeapon* UUGCFunctionBridge::SpawnWeapon(const FName& WeaponID, FVector Location)
{
    if (!HasWriteAuthority() || WeaponID.IsNone()) return nullptr;
    UWorld* World = GetWorld();
    if (!World) return nullptr;

    UGameInstance* GameInstance = World->GetGameInstance();
    const UItemDataManager* ItemData = GameInstance ? GameInstance->GetSubsystem<UItemDataManager>() : nullptr;
    const FItemDefinitionRow* Definition = ItemData ? ItemData->GetItemDefinition(WeaponID) : nullptr;
    if (!Definition || Definition->ItemType != EItemType::Weapon)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCBridge] SpawnWeapon: invalid or non-weapon ItemID '%s'"), *WeaponID.ToString());
        return nullptr;
    }

    FActorSpawnParameters Params;
    Params.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn;

    AFPSWorldWeapon* Spawned = World->SpawnActor<AFPSWorldWeapon>(
        AFPSWorldWeapon::StaticClass(),
        Location,
        FRotator::ZeroRotator,
        Params
    );

    if (Spawned)
    {
        // WeaponItemDefID 对应 DT_ItemDefinition 的行名，用于背包物品创建
        Spawned->WeaponItemDefID = WeaponID;
        if (bPlaytestSessionActive) SpawnedWeapons.Add(Spawned);
    }

    return Spawned;
}

// -----------------------------------------------------------------------
// 游戏规则
// -----------------------------------------------------------------------

void UUGCFunctionBridge::ResetGameRules()
{
    GameRules.Reset();
    GameRules.Add(TEXT("RoundTime"), 300.f);
    GameRules.Add(TEXT("RespawnDelay"), 5.f);
    GameRules.Add(TEXT("FriendlyFire"), 0.f);
    GameRules.Add(TEXT("GravityScale"), 1.f);
    if (HasWriteAuthority())
    {
        if (UWorld* World = GetWorld())
        {
            if (AWorldSettings* WS = World->GetWorldSettings())
            {
                WS->WorldGravityZ = -980.f;
            }
        }
    }
}

bool UUGCFunctionBridge::SetGameRule(const FString& RuleName, float Value)
{
    if (!HasWriteAuthority()) return false;
    const float* MinPtr = UGCRuleWhitelist::MinValues.Find(RuleName);
    const float* MaxPtr = UGCRuleWhitelist::MaxValues.Find(RuleName);
    if (!MinPtr || !MaxPtr)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCBridge] SetGameRule: '%s' 不在白名单"), *RuleName);
        return false;
    }

    Value = FMath::Clamp(Value, *MinPtr, *MaxPtr);
    GameRules.Add(RuleName, Value);

    // GravityScale 直接作用于 WorldSettings
    if (RuleName == TEXT("GravityScale"))
    {
        if (UWorld* World = GetWorld())
        {
            if (AWorldSettings* WS = World->GetWorldSettings())
            {
                WS->WorldGravityZ = -980.f * Value;
            }
        }
    }

    return true;
}

float UUGCFunctionBridge::GetGameRule(const FString& RuleName) const
{
    if (!UGCRuleWhitelist::MinValues.Contains(RuleName)) return -1.f;
    const float* Val = GameRules.Find(RuleName);
    return Val ? *Val : -1.f;
}
