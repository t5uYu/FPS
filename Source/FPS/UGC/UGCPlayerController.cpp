// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCPlayerController.h"
#include "UGCFunctionBridge.h"
#include "UGCHttpClient.h"
#include "UGCEditorBridge.h"
#include "UGCPCGBridge.h"
#include "UGCEventRouterSubsystem.h"
#include "UGCStorageBridge.h"
#include "EnhancedInputComponent.h"
#include "InputAction.h"
#include "HAL/PlatformApplicationMisc.h"
#include "GameFramework/Pawn.h"
#include "Engine/World.h"
#include "UObject/ConstructorHelpers.h"

AUGCPlayerController::AUGCPlayerController()
{
    UGCBridge     = CreateDefaultSubobject<UUGCFunctionBridge>(TEXT("UGCFunctionBridge"));
    UGCHttpClient = CreateDefaultSubobject<UUGCHttpClient>(TEXT("UGCHttpClient"));
    EditorBridge  = CreateDefaultSubobject<UUGCEditorBridge>(TEXT("UGCEditorBridge"));
    PCGBridge     = CreateDefaultSubobject<UUGCPCGBridge>(TEXT("UGCPCGBridge"));
    StorageBridge = CreateDefaultSubobject<UUGCStorageBridge>(TEXT("UGCStorageBridge"));

    static ConstructorHelpers::FClassFinder<APawn> PlaytestPawnFinder(TEXT("/Game/_FPS/Blueprints/BP_FPSPlayer"));
    if (PlaytestPawnFinder.Succeeded())
    {
        PlaytestPawnClass = PlaytestPawnFinder.Class;
    }
}

void AUGCPlayerController::BeginPlay()
{
    Super::BeginPlay();
    if (UWorld* World = GetWorld())
    {
        if (UUGCEventRouterSubsystem* Router = World->GetSubsystem<UUGCEventRouterSubsystem>())
        {
            Router->OnRuntimeEvent.AddUniqueDynamic(this, &AUGCPlayerController::HandleUGCRuntimeEvent);
        }
    }
}

void AUGCPlayerController::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
    if (UWorld* World = GetWorld())
    {
        if (UUGCEventRouterSubsystem* Router = World->GetSubsystem<UUGCEventRouterSubsystem>())
        {
            Router->OnRuntimeEvent.RemoveDynamic(this, &AUGCPlayerController::HandleUGCRuntimeEvent);
        }
    }
    if (HasAuthority())
    {
        UGCBridge->EndPlaytestSession();
        if (IsValid(ActivePlaytestPawn)) ActivePlaytestPawn->Destroy();
    }
    ActivePlaytestPawn = nullptr;
    AuthoringPawn = nullptr;
    Super::EndPlay(EndPlayReason);
}

bool AUGCPlayerController::EnterPlaytestPawn()
{
    if (!HasAuthority() || !PlaytestPawnClass)
    {
        return false;
    }

    APawn* CurrentPawn = GetPawn();
    if (IsValid(ActivePlaytestPawn))
    {
        if (CurrentPawn && CurrentPawn != ActivePlaytestPawn)
        {
            AuthoringPawn = CurrentPawn;
            AuthoringPawn->SetActorHiddenInGame(true);
            AuthoringPawn->SetActorEnableCollision(false);
            AuthoringPawn->SetActorTickEnabled(false);
            ActivePlaytestPawn->SetActorLocationAndRotation(
                AuthoringPawn->GetActorLocation(), GetControlRotation(), false, nullptr,
                ETeleportType::TeleportPhysics);
        }
        ActivePlaytestPawn->SetActorHiddenInGame(false);
        ActivePlaytestPawn->SetActorEnableCollision(true);
        ActivePlaytestPawn->SetActorTickEnabled(true);
        Possess(ActivePlaytestPawn);
        const bool bPossessed = GetPawn() == ActivePlaytestPawn;
        if (bPossessed) UGCBridge->BeginPlaytestSession();
        return bPossessed;
    }

    if (CurrentPawn)
    {
        AuthoringPawn = CurrentPawn;
    }

    UWorld* World = GetWorld();
    if (!World) return false;
    const FVector PlaytestSpawnLocation = CurrentPawn ? CurrentPawn->GetActorLocation() : GetSpawnLocation();
    const FRotator SpawnRotation = GetControlRotation();
    FActorSpawnParameters Params;
    Params.Owner = this;
    Params.Instigator = CurrentPawn;
    Params.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn;

    APawn* NewPawn = World->SpawnActor<APawn>(PlaytestPawnClass, PlaytestSpawnLocation, SpawnRotation, Params);
    if (!NewPawn)
    {
        return false;
    }

    if (AuthoringPawn)
    {
        AuthoringPawn->SetActorHiddenInGame(true);
        AuthoringPawn->SetActorEnableCollision(false);
        AuthoringPawn->SetActorTickEnabled(false);
    }
    Possess(NewPawn);
    if (GetPawn() != NewPawn)
    {
        NewPawn->Destroy();
        if (AuthoringPawn)
        {
            AuthoringPawn->SetActorHiddenInGame(false);
            AuthoringPawn->SetActorEnableCollision(true);
            AuthoringPawn->SetActorTickEnabled(true);
            Possess(AuthoringPawn);
        }
        return false;
    }

    ActivePlaytestPawn = NewPawn;
    UGCBridge->BeginPlaytestSession();
    return true;
}

bool AUGCPlayerController::ExitPlaytestPawn()
{
    if (!HasAuthority())
    {
        return false;
    }

    UGCBridge->EndPlaytestSession();

    if (AuthoringPawn && IsValid(AuthoringPawn))
    {
        AuthoringPawn->SetActorHiddenInGame(false);
        AuthoringPawn->SetActorEnableCollision(true);
        AuthoringPawn->SetActorTickEnabled(true);
        Possess(AuthoringPawn);
    }
    else if (GetPawn() == ActivePlaytestPawn)
    {
        UnPossess();
    }

    if (IsValid(ActivePlaytestPawn))
    {
        ActivePlaytestPawn->SetActorHiddenInGame(true);
        ActivePlaytestPawn->SetActorEnableCollision(false);
        ActivePlaytestPawn->SetActorTickEnabled(false);
    }
    return GetPawn() == AuthoringPawn || AuthoringPawn == nullptr;
}

void AUGCPlayerController::HandleUGCRuntimeEvent(const FUGCRuntimeEvent& Event)
{
    if (const APawn* InstigatorPawn = Cast<APawn>(Event.InstigatorActor))
    {
        if (InstigatorPawn->GetController() != this)
        {
            return;
        }
    }

    if (Event.EventName == TEXT("Event_OnEnter"))
    {
        OnTriggerZoneEnter(Event.ProgramID);
    }
    else if (Event.EventName == TEXT("Event_OnExit"))
    {
        OnTriggerZoneExit(Event.ProgramID);
    }
}

void AUGCPlayerController::SetupInputComponent()
{
    Super::SetupInputComponent();

    if (UEnhancedInputComponent* EIC = Cast<UEnhancedInputComponent>(InputComponent))
    {
        if (ToggleEditorAction)
            EIC->BindAction(ToggleEditorAction, ETriggerEvent::Started, this,
                &AUGCPlayerController::HandleToggleEditorInput);

        if (EditorClickAction)
            EIC->BindAction(EditorClickAction, ETriggerEvent::Started, this,
                &AUGCPlayerController::HandleEditorClickInput);
    }
}

void AUGCPlayerController::CopyToClipboard(const FString& Text)
{
    FPlatformApplicationMisc::ClipboardCopy(*Text);
}

void AUGCPlayerController::HandleToggleEditorInput()
{
    ToggleEditor();
}

void AUGCPlayerController::HandleEditorClickInput()
{
    EditorClick();
}
