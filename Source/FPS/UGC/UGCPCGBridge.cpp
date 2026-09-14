// UGCPCGBridge.cpp — PCG 过程化生成桥接组件（2026-04-16）

#include "UGCPCGBridge.h"
#include "PCGComponent.h"
#include "PCGGraph.h"
#include "Engine/World.h"
#include "GameFramework/Actor.h"
#include "Kismet/GameplayStatics.h"

UUGCPCGBridge::UUGCPCGBridge()
{
    PrimaryComponentTick.bCanEverTick = false;
}

// -----------------------------------------------------------------------
// Generate
// -----------------------------------------------------------------------

AActor* UUGCPCGBridge::Generate(FVector Location, float Radius, int32 Seed, const FString& GraphPath)
{
    if (!GetOwner() || !GetOwner()->HasAuthority()) return nullptr;
    UWorld* World = GetWorld();
    if (!World)
    {
        UE_LOG(LogTemp, Error, TEXT("[UGCPCGBridge] Generate: World 为空"));
        return nullptr;
    }

    // Runtime callers may only use the reviewed default graph. Arbitrary asset
    // paths are not an acceptable capability boundary for UGC/AI input.
    if (!GraphPath.IsEmpty())
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCPCGBridge] Generate: custom GraphPath is disabled"));
        return nullptr;
    }

    UPCGGraphInterface* Graph = nullptr;
    if (!DefaultPCGGraph.IsNull())
    {
        Graph = DefaultPCGGraph.LoadSynchronous();
    }
    if (!Graph)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCPCGBridge] Generate: 无可用 PCG Graph"));
        return nullptr;
    }

    // 参数默认值
    const float UseRadius = FMath::Clamp((Radius > 0.f) ? Radius : DefaultRadius, 100.f, 10000.f);
    int32 UseSeed = (Seed != 0) ? Seed : DefaultSeed;
    if (UseSeed == 0)
    {
        UseSeed = FMath::RandRange(1, 999999);
    }

    // Spawn 一个空 Actor 作为 PCG 宿主
    FActorSpawnParameters SpawnParams;
    SpawnParams.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;

    AActor* PCGActor = World->SpawnActor<AActor>(AActor::StaticClass(), Location, FRotator::ZeroRotator, SpawnParams);
    if (!PCGActor)
    {
        UE_LOG(LogTemp, Error, TEXT("[UGCPCGBridge] Generate: Spawn PCG Actor 失败"));
        return nullptr;
    }

    // 添加 PCG Component
    UPCGComponent* PCGComp = NewObject<UPCGComponent>(PCGActor, TEXT("PCGComponent"));
    if (!PCGComp)
    {
        PCGActor->Destroy();
        return nullptr;
    }

    PCGComp->RegisterComponent();
    PCGComp->SetGraph(Graph);
    PCGComp->Seed = UseSeed;

    // 设置生成范围（通过 Actor Scale 间接控制 PCG 的 Volume）
    PCGActor->SetActorScale3D(FVector(UseRadius / 100.f));

    // 触发生成
    PCGComp->Generate();

    ActivePCGActors.Add(PCGActor);

    UE_LOG(LogTemp, Log, TEXT("[UGCPCGBridge] Generate: 位置=(%.0f,%.0f,%.0f) 半径=%.0f 种子=%d"),
        Location.X, Location.Y, Location.Z, UseRadius, UseSeed);

    return PCGActor;
}

// -----------------------------------------------------------------------
// Cleanup
// -----------------------------------------------------------------------

bool UUGCPCGBridge::Cleanup(AActor* PCGActor)
{
    if (!GetOwner() || !GetOwner()->HasAuthority() || !PCGActor
        || !ActivePCGActors.Contains(PCGActor)) return false;

    // 找到 PCG Component 并清理
    UPCGComponent* PCGComp = PCGActor->FindComponentByClass<UPCGComponent>();
    if (PCGComp)
    {
        PCGComp->Cleanup();
    }

    PCGActor->Destroy();
    ActivePCGActors.Remove(PCGActor);

    UE_LOG(LogTemp, Log, TEXT("[UGCPCGBridge] Cleanup: Actor 已清理"));
    return true;
}

void UUGCPCGBridge::CleanupAll()
{
    if (!GetOwner() || !GetOwner()->HasAuthority()) return;
    for (AActor* Actor : ActivePCGActors)
    {
        if (Actor && IsValid(Actor))
        {
            UPCGComponent* PCGComp = Actor->FindComponentByClass<UPCGComponent>();
            if (PCGComp)
            {
                PCGComp->Cleanup();
            }
            Actor->Destroy();
        }
    }
    int32 Count = ActivePCGActors.Num();
    ActivePCGActors.Empty();
    UE_LOG(LogTemp, Log, TEXT("[UGCPCGBridge] CleanupAll: 已清理 %d 个 PCG Actor"), Count);
}
