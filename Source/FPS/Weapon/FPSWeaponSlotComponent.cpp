// Copyright Epic Games, Inc. All Rights Reserved.

#include "FPSWeaponSlotComponent.h"
#include "FPSWeaponBase.h"
#include "FPSWeaponDataAsset.h"
#include "FPS/FPSCharacter.h"
#include "Components/SkeletalMeshComponent.h"
#include "Net/UnrealNetwork.h"
#include "Engine/World.h"

UFPSWeaponSlotComponent::UFPSWeaponSlotComponent()
{
	PrimaryComponentTick.bCanEverTick = false;
	SetIsReplicatedByDefault(true);

	// Initialize fixed-size arrays (3 slots: Primary1 / Primary2 / Pistol)
	SlotWeapons.SetNum(3);
	SlotInventoryItems.SetNum(3);
}

void UFPSWeaponSlotComponent::BeginPlay()
{
	Super::BeginPlay();
}

void UFPSWeaponSlotComponent::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);

	DOREPLIFETIME(UFPSWeaponSlotComponent, SlotWeapons);
	DOREPLIFETIME(UFPSWeaponSlotComponent, SlotInventoryItems);
	DOREPLIFETIME(UFPSWeaponSlotComponent, ActiveSlot);
}

//-------------------------------------------------------------------
// Slot ↔ Index Helpers
//-------------------------------------------------------------------

int32 UFPSWeaponSlotComponent::SlotToIndex(EFPSWeaponSlot Slot)
{
	switch (Slot)
	{
	case EFPSWeaponSlot::Primary1: return 0;
	case EFPSWeaponSlot::Primary2: return 1;
	case EFPSWeaponSlot::Pistol:   return 2;
	default:                        return INDEX_NONE;
	}
}

EFPSWeaponSlot UFPSWeaponSlotComponent::IndexToSlot(int32 Index)
{
	switch (Index)
	{
	case 0: return EFPSWeaponSlot::Primary1;
	case 1: return EFPSWeaponSlot::Primary2;
	case 2: return EFPSWeaponSlot::Pistol;
	default: return EFPSWeaponSlot::None;
	}
}

//-------------------------------------------------------------------
// Public Interface
//-------------------------------------------------------------------

bool UFPSWeaponSlotComponent::SetWeaponInSlot(EFPSWeaponSlot Slot,
                                               const FInventoryItem& WeaponItem,
                                               TSubclassOf<AFPSWeaponBase> WeaponClass)
{
	if (!GetOwner()->HasAuthority())
	{
		return false;
	}

	const int32 Index = SlotToIndex(Slot);
	if (Index == INDEX_NONE)
	{
		return false;
	}

	// Destroy any existing weapon in this slot
	if (SlotWeapons[Index])
	{
		if (Slot == ActiveSlot)
		{
			SlotWeapons[Index]->OnUnequip();
			SlotWeapons[Index]->DetachFromActor(FDetachmentTransformRules::KeepWorldTransform);
			ActiveSlot = EFPSWeaponSlot::None;
		}
		SlotWeapons[Index]->Destroy();
		SlotWeapons[Index] = nullptr;
	}

	// Spawn the new weapon
	AFPSWeaponBase* NewWeapon = SpawnWeaponActor(WeaponClass);
	if (!NewWeapon)
	{
		return false;
	}

	SlotWeapons[Index] = NewWeapon;
	SlotInventoryItems[Index] = WeaponItem;

	// If no slot is currently active, auto-equip the new weapon
	if (ActiveSlot == EFPSWeaponSlot::None)
	{
		PerformSwitchToSlot(Slot);
	}
	else
	{
		// Hide until switched to
		SetWeaponVisible(NewWeapon, false);
	}

	OnWeaponSlotChanged.Broadcast(Slot);
	return true;
}

bool UFPSWeaponSlotComponent::RemoveWeaponFromSlot(EFPSWeaponSlot Slot, FInventoryItem& OutItem)
{
	if (!GetOwner()->HasAuthority())
	{
		return false;
	}

	const int32 Index = SlotToIndex(Slot);
	if (Index == INDEX_NONE || !SlotWeapons[Index])
	{
		return false;
	}

	// Unequip if this is the active slot
	if (Slot == ActiveSlot)
	{
		SlotWeapons[Index]->OnUnequip();
		SlotWeapons[Index]->DetachFromActor(FDetachmentTransformRules::KeepWorldTransform);
		ActiveSlot = EFPSWeaponSlot::None;
	}

	OutItem = SlotInventoryItems[Index];

	SlotWeapons[Index]->Destroy();
	SlotWeapons[Index] = nullptr;
	SlotInventoryItems[Index] = FInventoryItem();

	OnWeaponSlotChanged.Broadcast(Slot);
	return true;
}

void UFPSWeaponSlotComponent::SwitchToSlot(EFPSWeaponSlot Slot)
{
	if (!GetOwner()->HasAuthority())
	{
		ServerSwitchToSlot(Slot);
		return;
	}
	PerformSwitchToSlot(Slot);
}

void UFPSWeaponSlotComponent::ServerSwitchToSlot_Implementation(EFPSWeaponSlot Slot)
{
	PerformSwitchToSlot(Slot);
}

void UFPSWeaponSlotComponent::CycleToNextSlot()
{
	if (!GetOwner()->HasAuthority())
	{
		ServerCycleToNextSlot();
		return;
	}

	const int32 CurrentIndex = SlotToIndex(ActiveSlot);

	for (int32 i = 0; i < 3; i++)
	{
		int32 NextIndex;
		if (CurrentIndex == INDEX_NONE)
		{
			NextIndex = i;
		}
		else
		{
			NextIndex = (CurrentIndex + 1 + i) % 3;
		}

		if (SlotWeapons.IsValidIndex(NextIndex) && SlotWeapons[NextIndex])
		{
			PerformSwitchToSlot(IndexToSlot(NextIndex));
			return;
		}
	}
}

void UFPSWeaponSlotComponent::ServerCycleToNextSlot_Implementation()
{
	CycleToNextSlot();
}

AFPSWeaponBase* UFPSWeaponSlotComponent::GetActiveWeapon() const
{
	const int32 Index = SlotToIndex(ActiveSlot);
	if (Index == INDEX_NONE || !SlotWeapons.IsValidIndex(Index))
	{
		return nullptr;
	}
	return SlotWeapons[Index];
}

AFPSWeaponBase* UFPSWeaponSlotComponent::GetWeaponInSlot(EFPSWeaponSlot Slot) const
{
	const int32 Index = SlotToIndex(Slot);
	if (Index == INDEX_NONE || !SlotWeapons.IsValidIndex(Index))
	{
		return nullptr;
	}
	return SlotWeapons[Index];
}

bool UFPSWeaponSlotComponent::IsSlotOccupied(EFPSWeaponSlot Slot) const
{
	const int32 Index = SlotToIndex(Slot);
	if (Index == INDEX_NONE || !SlotWeapons.IsValidIndex(Index))
	{
		return false;
	}
	return SlotWeapons[Index] != nullptr;
}

EFPSWeaponSlot UFPSWeaponSlotComponent::FindEmptySlotForWeapon(TSubclassOf<AFPSWeaponBase> WeaponClass) const
{
	// Pistols only go to the Pistol slot
	if (WeaponClass)
	{
		const AFPSWeaponBase* DefaultObj = WeaponClass.GetDefaultObject();
		if (DefaultObj && DefaultObj->WeaponData && DefaultObj->WeaponData->bIsPistol)
		{
			return IsSlotOccupied(EFPSWeaponSlot::Pistol) ? EFPSWeaponSlot::None : EFPSWeaponSlot::Pistol;
		}
	}

	// Primary weapons: Primary1 first, then Primary2
	if (!IsSlotOccupied(EFPSWeaponSlot::Primary1))
	{
		return EFPSWeaponSlot::Primary1;
	}
	if (!IsSlotOccupied(EFPSWeaponSlot::Primary2))
	{
		return EFPSWeaponSlot::Primary2;
	}
	return EFPSWeaponSlot::None;
}

//-------------------------------------------------------------------
// Internal
//-------------------------------------------------------------------

AFPSWeaponBase* UFPSWeaponSlotComponent::SpawnWeaponActor(TSubclassOf<AFPSWeaponBase> WeaponClass)
{
	UWorld* World = GetWorld();
	if (!World || !WeaponClass)
	{
		return nullptr;
	}

	FActorSpawnParameters SpawnParams;
	SpawnParams.Owner = GetOwner();
	SpawnParams.Instigator = Cast<APawn>(GetOwner());
	SpawnParams.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;

	return World->SpawnActor<AFPSWeaponBase>(
		WeaponClass, FVector::ZeroVector, FRotator::ZeroRotator, SpawnParams);
}

void UFPSWeaponSlotComponent::PerformSwitchToSlot(EFPSWeaponSlot NewSlot)
{
	if (NewSlot == ActiveSlot)
	{
		return;
	}

	const int32 NewIndex = SlotToIndex(NewSlot);
	if (NewIndex == INDEX_NONE || !SlotWeapons.IsValidIndex(NewIndex) || !SlotWeapons[NewIndex])
	{
		return; // Target slot empty
	}

	AFPSCharacter* OwnerChar = Cast<AFPSCharacter>(GetOwner());
	const EFPSWeaponSlot OldSlot = ActiveSlot;

	// Unequip old weapon
	const int32 OldIndex = SlotToIndex(OldSlot);
	if (OldIndex != INDEX_NONE && SlotWeapons.IsValidIndex(OldIndex) && SlotWeapons[OldIndex])
	{
		SlotWeapons[OldIndex]->OnUnequip();
		SlotWeapons[OldIndex]->DetachFromActor(FDetachmentTransformRules::KeepWorldTransform);
		SetWeaponVisible(SlotWeapons[OldIndex], false);
	}

	// Equip new weapon
	ActiveSlot = NewSlot;
	AFPSWeaponBase* NewWeapon = SlotWeapons[NewIndex];
	SetWeaponVisible(NewWeapon, true);

	if (OwnerChar)
	{
		NewWeapon->OnEquip(OwnerChar);
		if (USkeletalMeshComponent* BodyMesh = OwnerChar->GetMesh())
		{
			NewWeapon->AttachToComponent(
				BodyMesh,
				FAttachmentTransformRules::SnapToTargetNotIncludingScale,
				TEXT("hand_r"));
			if (NewWeapon->GetRootComponent())
			{
				NewWeapon->GetRootComponent()->SetRelativeLocation(NewWeapon->EquippedRelativeLocationOffset);
			}
			UE_LOG(LogTemp, Warning, TEXT("[WeaponSlot] Equipped %s offset=%s relative=%s"),
				*GetNameSafe(NewWeapon),
				*NewWeapon->EquippedRelativeLocationOffset.ToString(),
				*NewWeapon->GetRootComponent()->GetRelativeLocation().ToString());
		}
	}

	OnActiveWeaponChanged.Broadcast(OldSlot, NewSlot);
}

void UFPSWeaponSlotComponent::SetWeaponVisible(AFPSWeaponBase* Weapon, bool bVisible)
{
	if (Weapon)
	{
		Weapon->SetActorHiddenInGame(!bVisible);
	}
}

//-------------------------------------------------------------------
// RepNotifies
//-------------------------------------------------------------------

void UFPSWeaponSlotComponent::OnRep_SlotWeapons()
{
	// Clients: sync weapon visibility with current active slot
	for (int32 i = 0; i < SlotWeapons.Num(); i++)
	{
		if (SlotWeapons[i])
		{
			const bool bSlotActive = (IndexToSlot(i) == ActiveSlot);
			SetWeaponVisible(SlotWeapons[i], bSlotActive);
		}
	}
}

void UFPSWeaponSlotComponent::OnRep_ActiveSlot()
{
	OnRep_SlotWeapons();
	OnActiveWeaponChanged.Broadcast(EFPSWeaponSlot::None, ActiveSlot);
}
