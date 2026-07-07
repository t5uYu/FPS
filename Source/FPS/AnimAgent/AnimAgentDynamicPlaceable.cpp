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
    PackageId = InAssetUuid;
    SetRuntimeAsset(Mesh, InAssetUuid, TEXT("main"));
}

void AAnimAgentDynamicPlaceable::SetRuntimeAsset(UStaticMesh* Mesh, const FString& InPackageId, const FString& InAssetId)
{
    (void)InAssetId;
    PackageId = InPackageId;
    AssetUuid = InPackageId;
    if (!Mesh) return;
    if (UStaticMeshComponent* SMC = GetStaticMeshComponent())
    {
        SMC->SetMobility(EComponentMobility::Movable);
        SMC->SetStaticMesh(Mesh);
        for (int32 Index = 0; Index < Mesh->GetStaticMaterials().Num(); ++Index)
        {
            SMC->SetMaterial(Index, Mesh->GetMaterial(Index));
        }
    }
}
