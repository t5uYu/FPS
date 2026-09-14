// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCPrefabDefinition.h"
#include "GameFramework/Actor.h"

const FName UUGCPrefabDefinition::PrefabAssetType(TEXT("UGCPrefab"));
const FName UUGCPrefabDefinition::RuntimePrefabAssetType(TEXT("UGCPrefabRuntime"));

FName UUGCPrefabDefinition::GetEffectiveId() const
{
    return PrefabId.IsNone() ? GetFName() : PrefabId;
}

FPrimaryAssetId UUGCPrefabDefinition::GetPrimaryAssetId() const
{
    return FPrimaryAssetId(PrefabAssetType, GetEffectiveId());
}

FString UUGCPrefabDefinition::GetActorClassPath() const
{
    if (ActorClass.IsNull())
    {
        return FString();
    }
    // TSoftClassPtr::ToString() 给出 ".../BA_Placeable_Box.BA_Placeable_Box_C"，正是 LoadClass 需要的形态
    return ActorClass.ToString();
}

void UUGCPrefabDefinition::ToPlaceableInfo(FUGCPlaceableInfo& OutInfo, const FString& InSource) const
{
    OutInfo.Id          = GetEffectiveId();
    OutInfo.ClassPath   = GetActorClassPath();
    OutInfo.Label       = DisplayName.IsEmpty() ? OutInfo.Id.ToString() : DisplayName.ToString();
    OutInfo.Category    = Category.IsNone() ? TEXT("未分类") : Category.ToString();
    OutInfo.Description = Description;
    OutInfo.Tags.Reset();
    for (const FName& Tag : Tags)
    {
        OutInfo.Tags.Add(Tag.ToString());
    }
    OutInfo.Version      = Version;
    OutInfo.Cost         = Cost;
    OutInfo.Bounds       = Bounds;
    OutInfo.AllowedModes.Reset();
    for (const FName& Mode : AllowedModes)
    {
        OutInfo.AllowedModes.Add(Mode.ToString());
    }
    OutInfo.Kind   = Kind;
    OutInfo.Source = InSource;
}
