// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "UGCGameMode.generated.h"

/**
 * Authoring-only UGC game mode.
 *
 * This deliberately does not inherit the competitive FPS game mode: authoring
 * sessions have no team assignment, match clock, scoring, death, or respawn
 * policy. Playtest sessions should use a separate gameplay game mode/snapshot.
 */
UCLASS()
class FPS_API AUGCGameMode : public AGameModeBase
{
    GENERATED_BODY()

public:
    AUGCGameMode();

protected:
    virtual void HandleStartingNewPlayer_Implementation(APlayerController* NewPlayer) override;
};
