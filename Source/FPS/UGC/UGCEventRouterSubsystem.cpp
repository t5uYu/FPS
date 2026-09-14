// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCEventRouterSubsystem.h"

void UUGCEventRouterSubsystem::PublishEvent(FName EventName, const FString& SourceEntityID,
    const FString& ProgramID, AActor* SourceActor, AActor* InstigatorActor)
{
    if (EventName.IsNone() || ProgramID.IsEmpty())
    {
        return;
    }

    FUGCRuntimeEvent Event;
    Event.EventName = EventName;
    Event.SourceEntityID = SourceEntityID;
    Event.ProgramID = ProgramID;
    Event.SourceActor = SourceActor;
    Event.InstigatorActor = InstigatorActor;
    OnRuntimeEvent.Broadcast(Event);
}
