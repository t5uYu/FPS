// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "UGCStorageBridge.generated.h"

/** Runtime-safe JSON storage boundary limited to the project Saved directory.
 *  允许的后缀：<.json>（存档本体）、<.bak> / <.bakN>（备份轮转世代）。 */
UCLASS(ClassGroup = "UGC", meta = (BlueprintSpawnableComponent))
class FPS_API UUGCStorageBridge : public UActorComponent
{
    GENERATED_BODY()

public:
    UUGCStorageBridge();

    UFUNCTION(BlueprintPure, Category = "UGC|Storage")
    bool FileExists(const FString& Path) const;

    UFUNCTION(BlueprintCallable, Category = "UGC|Storage")
    FString ReadTextFile(const FString& Path) const;

    UFUNCTION(BlueprintCallable, Category = "UGC|Storage")
    bool WriteTextFileAtomic(const FString& Path, const FString& Content) const;

private:
    bool IsAllowedJsonPath(const FString& Path, FString& OutAbsolutePath) const;
};
