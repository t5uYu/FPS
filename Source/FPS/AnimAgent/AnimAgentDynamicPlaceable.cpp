// Copyright Epic Games, Inc. All Rights Reserved.

#include "AnimAgentDynamicPlaceable.h"
#include "Engine/StaticMesh.h"
#include "Components/StaticMeshComponent.h"

AAnimAgentDynamicPlaceable::AAnimAgentDynamicPlaceable()
{
    if (UStaticMeshComponent* SMC = GetStaticMeshComponent())
    {
        SMC->SetMobility(EComponentMobility::Movable);
    }
}

void AAnimAgentDynamicPlaceable::SetDynMesh(UStaticMesh* Mesh, const FString& InAssetUuid)
{
    AssetUuid = InAssetUuid;
    if (!Mesh) return;
    if (UStaticMeshComponent* SMC = GetStaticMeshComponent())
    {
        SMC->SetMobility(EComponentMobility::Movable);
        SMC->SetStaticMesh(Mesh);
    }
}
