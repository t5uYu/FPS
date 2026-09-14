// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "FPSHUDWidget.generated.h"

class AFPSCharacter;
class AFPSPlayerState;
class AFPSWeaponBase;
class UFPSCombatAttributeSet;
class UProgressBar;
class UTextBlock;

// Delegate for damage indicator
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOnDamageReceived, float, DamageAmount, FVector, DamageDirection);

/**
 * UFPSHUDWidget
 *
 * Main HUD widget for the FPS game.
 * Provides C++ interface for Lua to bind to and update UI elements.
 */
UCLASS()
class FPS_API UFPSHUDWidget : public UUserWidget
{
	GENERATED_BODY()

public:
	/** Initialize the HUD with a character */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void InitializeHUD(AFPSCharacter* InCharacter);

	/** Initialize the HUD directly from PlayerState, where GAS data lives */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void InitializeHUDFromPlayerState(AFPSPlayerState* InPlayerState);

	/** Initialize from the owning player controller's PlayerState/Pawn */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void InitializeHUDFromOwningPlayer();

	/** Update health display */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void UpdateHealth(float CurrentHealth, float MaxHealth);

	/** Update armor display */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void UpdateArmor(float CurrentArmor, float MaxArmor);

	/** Update stamina display */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void UpdateStamina(float CurrentStamina, float MaxStamina);

	/** Update ammo display */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void UpdateAmmo(int32 CurrentMagazine, int32 MaxMagazine, int32 CurrentReserve);

	/** Update crosshair spread */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void UpdateCrosshairSpread(float SpreadAngle);

	/** Show damage indicator from a direction */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void ShowDamageIndicator(FVector DamageDirection, float DamageAmount);

	/** Add a status effect icon */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void AddStatusEffect(FName EffectID, UTexture2D* Icon, float Duration);

	/** Remove a status effect icon */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void RemoveStatusEffect(FName EffectID);

	/** Show hit marker */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void ShowHitMarker(bool bKill = false);

	/** Show low health warning */
	UFUNCTION(BlueprintCallable, Category = "FPS|HUD")
	void SetLowHealthWarning(bool bShow);

	//-------------------------------------------------------------------
	// Events (for Blueprint/Lua binding)
	//-------------------------------------------------------------------

	/** Called when health changes */
	UFUNCTION(BlueprintImplementableEvent, Category = "FPS|HUD|Events")
	void OnHealthChanged(float CurrentHealth, float MaxHealth, float Percentage);

	/** Called when armor changes */
	UFUNCTION(BlueprintImplementableEvent, Category = "FPS|HUD|Events")
	void OnArmorChanged(float CurrentArmor, float MaxArmor, float Percentage);

	/** Called when stamina changes */
	UFUNCTION(BlueprintImplementableEvent, Category = "FPS|HUD|Events")
	void OnStaminaChanged(float CurrentStamina, float MaxStamina, float Percentage);

	/** Called when ammo changes */
	UFUNCTION(BlueprintImplementableEvent, Category = "FPS|HUD|Events")
	void OnAmmoChanged(int32 CurrentMagazine, int32 MaxMagazine, int32 CurrentReserve);

	/** Called when crosshair spread changes */
	UFUNCTION(BlueprintImplementableEvent, Category = "FPS|HUD|Events")
	void OnCrosshairSpreadChanged(float SpreadAngle);

	/** Called when damage is received */
	UPROPERTY(BlueprintAssignable, Category = "FPS|HUD|Events")
	FOnDamageReceived OnDamageReceived;

	/** Called to show hit marker */
	UFUNCTION(BlueprintImplementableEvent, Category = "FPS|HUD|Events")
	void OnShowHitMarker(bool bKill);

	/** Called for low health warning */
	UFUNCTION(BlueprintImplementableEvent, Category = "FPS|HUD|Events")
	void OnLowHealthWarning(bool bShow);

	/** Called to show/hide a status effect */
	UFUNCTION(BlueprintImplementableEvent, Category = "FPS|HUD|Events")
	void OnStatusEffectChanged(FName EffectID, bool bActive, UTexture2D* Icon, float RemainingDuration);

protected:
	virtual void NativeConstruct() override;
	virtual void NativeDestruct() override;
	virtual void NativeTick(const FGeometry& MyGeometry, float InDeltaTime) override;

	/** Reference to the owning character */
	UPROPERTY(BlueprintReadOnly, Category = "FPS|HUD")
	TWeakObjectPtr<AFPSCharacter> OwningCharacter;

	/** Cached reference to combat attributes */
	UPROPERTY()
	TWeakObjectPtr<UFPSCombatAttributeSet> CombatAttributes;

	/** Cached reference to current weapon */
	UPROPERTY()
	TWeakObjectPtr<AFPSWeaponBase> CurrentWeapon;

	/** Cached PlayerState; GAS attributes are owned by PlayerState */
	UPROPERTY()
	TWeakObjectPtr<AFPSPlayerState> OwningPlayerState;

	/** Bind to attribute changes */
	void BindAttributeChanges();

	/** Unbind from attribute changes */
	void UnbindAttributeChanges();

	/** Refresh all GAS-driven values from the cached PlayerState */
	void RefreshFromPlayerState();

	/** Bind/unbind weapon ammo events when active weapon changes */
	void RefreshWeaponBinding();

	//-------------------------------------------------------------------
	// Attribute change handlers
	//-------------------------------------------------------------------

	UFUNCTION()
	void HandleHealthChanged(float OldValue, float NewValue, AActor* Instigator);

	UFUNCTION()
	void HandleArmorChanged(float OldValue, float NewValue, AActor* Instigator);

	UFUNCTION()
	void HandleStaminaChanged(float OldValue, float NewValue, AActor* Instigator);

	UFUNCTION()
	void HandleAmmoChanged(int32 CurrentMagazine, int32 CurrentReserve);

	//-------------------------------------------------------------------
	// UI State
	//-------------------------------------------------------------------

	/** Low health threshold percentage (0-1) */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "FPS|HUD|Config")
	float LowHealthThreshold = 0.25f;

	/** Current low health warning state */
	bool bLowHealthWarningActive = false;

	/** Active status effects */
	UPROPERTY()
	TMap<FName, float> ActiveStatusEffects;
};
