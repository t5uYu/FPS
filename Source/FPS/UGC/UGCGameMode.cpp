// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCGameMode.h"
#include "UGCPlayerController.h"
#include "FPS/Team/FPSPlayerState.h"
#include "GameFramework/SpectatorPawn.h"
#include "UObject/ConstructorHelpers.h"

AUGCGameMode::AUGCGameMode()
{
    DefaultPawnClass = ASpectatorPawn::StaticClass();
    PlayerControllerClass = AUGCPlayerController::StaticClass();
    PlayerStateClass = AFPSPlayerState::StaticClass();

    static ConstructorHelpers::FClassFinder<APlayerController> ControllerFinder(
        TEXT("/Game/_UGC/Blueprints/BP_UGCPlayerController"));
    if (ControllerFinder.Succeeded())
    {
        PlayerControllerClass = ControllerFinder.Class;
    }
}

void AUGCGameMode::HandleStartingNewPlayer_Implementation(APlayerController* NewPlayer)
{
    // Use the framework spawn path only. No FPS team assignment or match-state
    // gate is allowed in the authoring world.
    Super::HandleStartingNewPlayer_Implementation(NewPlayer);
}
