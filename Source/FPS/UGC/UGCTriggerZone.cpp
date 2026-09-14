// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCTriggerZone.h"
#include "UGCEventRouterSubsystem.h"
#include "Components/BoxComponent.h"
#include "Components/StaticMeshComponent.h"
#include "Engine/StaticMesh.h"
#include "Engine/World.h"
#include "UObject/ConstructorHelpers.h"
#include "GameFramework/Pawn.h"

AUGCTriggerZone::AUGCTriggerZone()
{
    PrimaryActorTick.bCanEverTick = false;

    Box = CreateDefaultSubobject<UBoxComponent>(TEXT("TriggerBox"));
    Box->SetBoxExtent(BoxExtent);
    Box->SetCollisionProfileName(TEXT("Trigger"));
    Box->SetGenerateOverlapEvents(true);
    RootComponent = Box;

    DebugMesh = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("DebugMesh"));
    DebugMesh->SetupAttachment(RootComponent);
    DebugMesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    DebugMesh->SetCollisionResponseToAllChannels(ECollisionResponse::ECR_Ignore);
    DebugMesh->SetCollisionResponseToChannel(ECC_Visibility, ECollisionResponse::ECR_Block);
    DebugMesh->SetCastShadow(false);
    DebugMesh->SetVisibility(false);

    static ConstructorHelpers::FObjectFinder<UStaticMesh> CubeFinder(TEXT("/Engine/BasicShapes/Cube.Cube"));
    if (CubeFinder.Succeeded())
    {
        DebugMesh->SetStaticMesh(CubeFinder.Object);
        DebugMesh->SetRelativeScale3D(BoxExtent * 2.f / 100.f);
    }
}

void AUGCTriggerZone::SetDebugVisible(bool bVisible)
{
    if (DebugMesh)
    {
        DebugMesh->SetVisibility(bVisible);
        DebugMesh->SetCollisionEnabled(
            bVisible ? ECollisionEnabled::QueryOnly : ECollisionEnabled::NoCollision);
    }
}

void AUGCTriggerZone::BeginPlay()
{
    Super::BeginPlay();

    Box->SetBoxExtent(BoxExtent);
    if (DebugMesh)
    {
        DebugMesh->SetRelativeScale3D(BoxExtent * 2.f / 100.f);
    }

    Box->OnComponentBeginOverlap.AddDynamic(this, &AUGCTriggerZone::OnBoxBeginOverlap);
    Box->OnComponentEndOverlap.AddDynamic(this, &AUGCTriggerZone::OnBoxEndOverlap);
}

void AUGCTriggerZone::OnBoxBeginOverlap(
    UPrimitiveComponent* OverlappedComp, AActor* OtherActor,
    UPrimitiveComponent* OtherComp, int32 OtherBodyIndex,
    bool bFromSweep, const FHitResult& SweepResult)
{
    if (!HasAuthority() || ProgramID.IsEmpty()) return;
    APawn* Pawn = Cast<APawn>(OtherActor);
    if (!Pawn) return;

    if (UWorld* World = GetWorld())
    {
        if (UUGCEventRouterSubsystem* Router = World->GetSubsystem<UUGCEventRouterSubsystem>())
        {
            Router->PublishEvent(TEXT("Event_OnEnter"), SourceEntityID, ProgramID, this, Pawn);
        }
    }
}

void AUGCTriggerZone::OnBoxEndOverlap(
    UPrimitiveComponent* OverlappedComp, AActor* OtherActor,
    UPrimitiveComponent* OtherComp, int32 OtherBodyIndex)
{
    if (!HasAuthority() || ProgramID.IsEmpty()) return;
    APawn* Pawn = Cast<APawn>(OtherActor);
    if (!Pawn) return;

    if (UWorld* World = GetWorld())
    {
        if (UUGCEventRouterSubsystem* Router = World->GetSubsystem<UUGCEventRouterSubsystem>())
        {
            Router->PublishEvent(TEXT("Event_OnExit"), SourceEntityID, ProgramID, this, Pawn);
        }
    }
}
