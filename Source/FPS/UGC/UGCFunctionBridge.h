// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "GameplayAbilitySpec.h"
#include "UGCFunctionBridge.generated.h"

class UFPSGameplayAbility;
class UGameplayEffect;
class AFPSCharacter;
class AFPSWorldWeapon;
class UAbilitySystemComponent;
class UFPSCombatAttributeSet;

/**
 * UUGCFunctionBridge
 *
 * UGC 底层原子操作组件，挂载在 PlayerController 上。
 * 将 GAS / 武器 / 规则等引擎能力封装为 Lua 白名单函数，
 * 供 UGCFunctionRegistry.lua 和 LLM Function Calling 调用。
 *
 * 设计原则：
 * - 不包含业务逻辑，只做"原子操作 + 参数校验 + 返回结果"
 * - 所有写操作均有白名单约束，超出范围返回 false
 * - Server Only 操作内部做 HasAuthority() 检查
 */
UCLASS(ClassGroup = "UGC", meta = (BlueprintSpawnableComponent))
class FPS_API UUGCFunctionBridge : public UActorComponent
{
    GENERATED_BODY()

public:
    UUGCFunctionBridge();

    //-------------------------------------------------------------------
    // GAS — 技能操作
    //-------------------------------------------------------------------

    /**
     * 动态授予 Pawn 一个 GAS 技能
     * @param AbilityClass  技能类（仅白名单内的 FPSGameplayAbility 子类）
     * @param Level         技能等级，默认 1
     * @return 授予成功返回 true
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|GAS")
    bool GrantAbility(TSubclassOf<UFPSGameplayAbility> AbilityClass, int32 Level = 1);

    /**
     * 移除 Pawn 身上指定类型的技能
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|GAS")
    bool RemoveAbility(TSubclassOf<UFPSGameplayAbility> AbilityClass);

    /**
     * 对 Pawn 应用一个 GameplayEffect
     * @param EffectClass  GE 蓝图类
     * @param Magnitude    强度倍率
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|GAS")
    bool ApplyEffect(TSubclassOf<UGameplayEffect> EffectClass, float Magnitude = 1.0f);

    //-------------------------------------------------------------------
    // GAS — 属性操作（白名单）
    //-------------------------------------------------------------------

    /**
     * 直接设置 Pawn 属性值
     * 白名单：Health / MaxHealth / Armor / MovementSpeed / Stamina
     * @return 属性名合法且赋值成功返回 true
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Attribute")
    bool SetAttribute(const FString& AttributeName, float Value);

    /**
     * 读取 Pawn 当前属性值，属性名不合法返回 -1
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Attribute")
    float GetAttribute(const FString& AttributeName) const;

    //-------------------------------------------------------------------
    // 武器操作
    //-------------------------------------------------------------------

    /**
     * 在指定位置生成一把武器（根据 WeaponID 查 DataAsset Registry）
     * @param WeaponID   UFPSWeaponDataAsset 中的 WeaponID 字段
     * @param Location   世界坐标
     * @return 生成的 AFPSWorldWeapon，失败返回 nullptr
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Weapon")
    AFPSWorldWeapon* SpawnWeapon(const FName& WeaponID, FVector Location);

    //-------------------------------------------------------------------
    // 游戏规则
    //-------------------------------------------------------------------

    /**
     * 设置游戏规则参数（仅 Server 生效）
     * 白名单：RoundTime / RespawnDelay / FriendlyFire / GravityScale
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Rule")
    bool SetGameRule(const FString& RuleName, float Value);

    /** Begin/end an isolated playtest mutation session. */
    void BeginPlaytestSession();
    void EndPlaytestSession();

    /** Reset all UGC runtime rules to their authored defaults. */
    UFUNCTION(BlueprintCallable, Category = "UGC|Rule")
    void ResetGameRules();

    /**
     * 读取当前规则值，规则名不合法返回 -1
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Rule")
    float GetGameRule(const FString& RuleName) const;

protected:
    virtual void BeginPlay() override;

private:
    /** 获取本 Controller 控制的 FPSCharacter（可能为 nullptr） */
    AFPSCharacter* GetFPSCharacter() const;

    /** 获取 Character 的 ASC（可能为 nullptr） */
    UAbilitySystemComponent* GetASC() const;

    /** 获取 Character 的 CombatAttributeSet（可能为 nullptr） */
    UFPSCombatAttributeSet* GetCombatAttributes() const;

    /** 所有 World/GAS 写操作的统一 Authority 守卫。 */
    bool HasWriteAuthority() const;

    /** C++ 最终防线：只允许审核过的 GameplayAbility 类路径。 */
    bool IsAbilityClassAllowed(TSubclassOf<UFPSGameplayAbility> AbilityClass) const;

    /** 已通过 GrantAbility 授予的 Handle，用于 RemoveAbility */
    TMap<TSubclassOf<UFPSGameplayAbility>, FGameplayAbilitySpecHandle> GrantedHandles;

    TArray<FActiveGameplayEffectHandle> AppliedEffectHandles;

    UPROPERTY(Transient)
    TArray<TObjectPtr<AFPSWorldWeapon>> SpawnedWeapons;

    TMap<FString, float> PlaytestAttributeSnapshot;
    TMap<FString, float> PlaytestRuleSnapshot;
    bool bPlaytestSessionActive = false;

    /** 游戏规则运行时存储（本局有效，不持久化） */
    TMap<FString, float> GameRules;
};
