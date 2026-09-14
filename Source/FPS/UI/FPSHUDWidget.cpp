// Copyright Epic Games, Inc. All Rights Reserved.

#include "FPSHUDWidget.h"
#include "FPS/FPSCharacter.h"
#include "FPS/Team/FPSPlayerState.h"
#include "FPS/Weapon/FPSWeaponBase.h"
#include "FPS/GAS/FPSCombatAttributeSet.h"
#include "FPS/GAS/FPSAbilitySystemComponent.h"
#include "FPS/GAS/FPSRecoilComponent.h"
#include "GameFramework/PlayerController.h"

void UFPSHUDWidget::NativeConstruct()
{
	Super::NativeConstruct();

	InitializeHUDFromOwningPlayer();
}

void UFPSHUDWidget::NativeDestruct()
{
	UnbindAttributeChanges();

	if (CurrentWeapon.IsValid())
	{
		CurrentWeapon->OnAmmoChanged.RemoveDynamic(this, &UFPSHUDWidget::HandleAmmoChanged);
		CurrentWeapon = nullptr;
	}

	Super::NativeDestruct();
}

void UFPSHUDWidget::NativeTick(const FGeometry& MyGeometry, float InDeltaTime)
{
	Super::NativeTick(MyGeometry, InDeltaTime);

	if (APlayerController* PC = GetOwningPlayer())
	{
		if (AFPSCharacter* Character = Cast<AFPSCharacter>(PC->GetPawn()))
		{
			if (Character != OwningCharacter.Get())
			{
				OwningCharacter = Character;
				RefreshWeaponBinding();
			}
		}

		if (AFPSPlayerState* PS = Cast<AFPSPlayerState>(PC->PlayerState))
		{
			if (PS != OwningPlayerState.Get() || !CombatAttributes.IsValid())
			{
				InitializeHUDFromPlayerState(PS);
			}
		}
	}

	// Update status effect durations
	TArray<FName> ExpiredEffects;
	for (auto& Pair : ActiveStatusEffects)
	{
		Pair.Value -= InDeltaTime;
		if (Pair.Value <= 0.0f)
		{
			ExpiredEffects.Add(Pair.Key);
		}
	}

	for (const FName& EffectID : ExpiredEffects)
	{
		RemoveStatusEffect(EffectID);
	}

	RefreshWeaponBinding();

	if (OwningCharacter.IsValid())
	{
		// Update crosshair spread（Spread 由 RecoilComponent 管理）
		if (OwningCharacter.IsValid() && OwningCharacter->RecoilComponent)
		{
			UpdateCrosshairSpread(OwningCharacter->RecoilComponent->CurrentSpread);
		}
	}
}

void UFPSHUDWidget::InitializeHUD(AFPSCharacter* InCharacter)
{
	if (!InCharacter)
	{
		return;
	}

	OwningCharacter = InCharacter;
	InitializeHUDFromPlayerState(InCharacter->GetFPSPlayerState());
	RefreshWeaponBinding();
}

void UFPSHUDWidget::InitializeHUDFromPlayerState(AFPSPlayerState* InPlayerState)
{
	if (!InPlayerState)
	{
		return;
	}

	UnbindAttributeChanges();

	OwningPlayerState = InPlayerState;
	CombatAttributes = InPlayerState->GetCombatAttributeSet();

	// Bind to attribute changes
	BindAttributeChanges();

	RefreshFromPlayerState();
}

void UFPSHUDWidget::InitializeHUDFromOwningPlayer()
{
	APlayerController* PC = GetOwningPlayer();
	if (!PC)
	{
		return;
	}

	if (AFPSCharacter* Character = Cast<AFPSCharacter>(PC->GetPawn()))
	{
		OwningCharacter = Character;
	}

	if (AFPSPlayerState* PS = Cast<AFPSPlayerState>(PC->PlayerState))
	{
		InitializeHUDFromPlayerState(PS);
	}

	RefreshWeaponBinding();
}

void UFPSHUDWidget::RefreshFromPlayerState()
{
	if (CombatAttributes.IsValid())
	{
		float Health = CombatAttributes->GetHealth();
		float MaxHealth = CombatAttributes->GetMaxHealth();
		UpdateHealth(Health, MaxHealth);

		float Armor = CombatAttributes->GetArmor();
		float MaxArmor = CombatAttributes->GetMaxArmor();
		UpdateArmor(Armor, MaxArmor);

		float Stamina = CombatAttributes->GetStamina();
		float MaxStamina = CombatAttributes->GetMaxStamina();
		UpdateStamina(Stamina, MaxStamina);
	}
}

void UFPSHUDWidget::RefreshWeaponBinding()
{
	AFPSWeaponBase* NewWeapon = OwningCharacter.IsValid() ? OwningCharacter->GetCurrentWeapon() : nullptr;
	if (NewWeapon == CurrentWeapon.Get())
	{
		return;
	}

	if (CurrentWeapon.IsValid())
	{
		CurrentWeapon->OnAmmoChanged.RemoveDynamic(this, &UFPSHUDWidget::HandleAmmoChanged);
	}

	CurrentWeapon = NewWeapon;
	if (CurrentWeapon.IsValid())
	{
		CurrentWeapon->OnAmmoChanged.AddDynamic(this, &UFPSHUDWidget::HandleAmmoChanged);
		HandleAmmoChanged(CurrentWeapon->GetCurrentMagazine(), CurrentWeapon->GetCurrentReserve());
	}
	else
	{
		UpdateAmmo(0, 0, 0);
	}
}

void UFPSHUDWidget::UpdateHealth(float CurrentHealth, float MaxHealth)
{
	float Percentage = MaxHealth > 0.0f ? CurrentHealth / MaxHealth : 0.0f;
	OnHealthChanged(CurrentHealth, MaxHealth, Percentage);

	// Check for low health warning
	bool bShouldWarn = Percentage <= LowHealthThreshold && Percentage > 0.0f;
	if (bShouldWarn != bLowHealthWarningActive)
	{
		bLowHealthWarningActive = bShouldWarn;
		SetLowHealthWarning(bShouldWarn);
	}
}

void UFPSHUDWidget::UpdateArmor(float CurrentArmor, float MaxArmor)
{
	float Percentage = MaxArmor > 0.0f ? CurrentArmor / MaxArmor : 0.0f;
	OnArmorChanged(CurrentArmor, MaxArmor, Percentage);
}

void UFPSHUDWidget::UpdateStamina(float CurrentStamina, float MaxStamina)
{
	float Percentage = MaxStamina > 0.0f ? CurrentStamina / MaxStamina : 0.0f;
	OnStaminaChanged(CurrentStamina, MaxStamina, Percentage);
}

void UFPSHUDWidget::UpdateAmmo(int32 CurrentMagazine, int32 MaxMagazine, int32 CurrentReserve)
{
	OnAmmoChanged(CurrentMagazine, MaxMagazine, CurrentReserve);
}

void UFPSHUDWidget::UpdateCrosshairSpread(float SpreadAngle)
{
	OnCrosshairSpreadChanged(SpreadAngle);
}

void UFPSHUDWidget::ShowDamageIndicator(FVector DamageDirection, float DamageAmount)
{
	OnDamageReceived.Broadcast(DamageAmount, DamageDirection);
}

void UFPSHUDWidget::AddStatusEffect(FName EffectID, UTexture2D* Icon, float Duration)
{
	ActiveStatusEffects.Add(EffectID, Duration);
	OnStatusEffectChanged(EffectID, true, Icon, Duration);
}

void UFPSHUDWidget::RemoveStatusEffect(FName EffectID)
{
	ActiveStatusEffects.Remove(EffectID);
	OnStatusEffectChanged(EffectID, false, nullptr, 0.0f);
}

void UFPSHUDWidget::ShowHitMarker(bool bKill)
{
	OnShowHitMarker(bKill);
}

void UFPSHUDWidget::SetLowHealthWarning(bool bShow)
{
	OnLowHealthWarning(bShow);
}

void UFPSHUDWidget::BindAttributeChanges()
{
	if (CombatAttributes.IsValid())
	{
		CombatAttributes->OnHealthChanged.RemoveDynamic(this, &UFPSHUDWidget::HandleHealthChanged);
		CombatAttributes->OnArmorChanged.RemoveDynamic(this, &UFPSHUDWidget::HandleArmorChanged);
		CombatAttributes->OnStaminaChanged.RemoveDynamic(this, &UFPSHUDWidget::HandleStaminaChanged);
		CombatAttributes->OnHealthChanged.AddDynamic(this, &UFPSHUDWidget::HandleHealthChanged);
		CombatAttributes->OnArmorChanged.AddDynamic(this, &UFPSHUDWidget::HandleArmorChanged);
		CombatAttributes->OnStaminaChanged.AddDynamic(this, &UFPSHUDWidget::HandleStaminaChanged);
	}
}

void UFPSHUDWidget::UnbindAttributeChanges()
{
	if (CombatAttributes.IsValid())
	{
		CombatAttributes->OnHealthChanged.RemoveDynamic(this, &UFPSHUDWidget::HandleHealthChanged);
		CombatAttributes->OnArmorChanged.RemoveDynamic(this, &UFPSHUDWidget::HandleArmorChanged);
		CombatAttributes->OnStaminaChanged.RemoveDynamic(this, &UFPSHUDWidget::HandleStaminaChanged);
	}
}

void UFPSHUDWidget::HandleHealthChanged(float OldValue, float NewValue, AActor* Instigator)
{
	if (CombatAttributes.IsValid())
	{
		UpdateHealth(NewValue, CombatAttributes->GetMaxHealth());

		// Show damage indicator if health decreased
		if (NewValue < OldValue && Instigator && OwningCharacter.IsValid())
		{
			FVector DamageDirection = (Instigator->GetActorLocation() - OwningCharacter->GetActorLocation()).GetSafeNormal();
			ShowDamageIndicator(DamageDirection, OldValue - NewValue);
		}
	}
}

void UFPSHUDWidget::HandleArmorChanged(float OldValue, float NewValue, AActor* Instigator)
{
	if (CombatAttributes.IsValid())
	{
		UpdateArmor(NewValue, CombatAttributes->GetMaxArmor());
	}
}

void UFPSHUDWidget::HandleStaminaChanged(float OldValue, float NewValue, AActor* Instigator)
{
	if (CombatAttributes.IsValid())
	{
		UpdateStamina(NewValue, CombatAttributes->GetMaxStamina());
	}
}

void UFPSHUDWidget::HandleAmmoChanged(int32 CurrentMagazine, int32 CurrentReserve)
{
	int32 MaxMagazine = CurrentWeapon.IsValid() ? CurrentWeapon->GetMagazineCapacity() : 0;
	UpdateAmmo(CurrentMagazine, MaxMagazine, CurrentReserve);
}
