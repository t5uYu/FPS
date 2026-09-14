// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "UGCStorageBridge.generated.h"

/** Runtime-safe JSON storage boundary limited to the project Saved directory. */
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
