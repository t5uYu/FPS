// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Subsystems/WorldSubsystem.h"
#include "UGCEventRouterSubsystem.generated.h"

USTRUCT(BlueprintType)
struct FPS_API FUGCRuntimeEvent
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Event")
    FName EventName = NAME_None;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Event")
    FString SourceEntityID;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Event")
    FString ProgramID;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Event")
    TObjectPtr<AActor> SourceActor = nullptr;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Event")
    TObjectPtr<AActor> InstigatorActor = nullptr;
};

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnUGCRuntimeEvent, const FUGCRuntimeEvent&, Event);

/** World-local event bus between authored actors and the UGC program runtime. */
UCLASS()
class FPS_API UUGCEventRouterSubsystem : public UWorldSubsystem
{
    GENERATED_BODY()

public:
    UPROPERTY(BlueprintAssignable, Category = "UGC|Event")
    FOnUGCRuntimeEvent OnRuntimeEvent;

    UFUNCTION(BlueprintCallable, Category = "UGC|Event")
    void PublishEvent(FName EventName, const FString& SourceEntityID,
        const FString& ProgramID, AActor* SourceActor, AActor* InstigatorActor);
};
