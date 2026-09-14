// Copyright Epic Games, Inc. All Rights Reserved.

#include "AnimImportBridge.h"
#include "Engine/StaticMesh.h"
#include "Engine/StaticMeshActor.h"
#include "Engine/World.h"
#include "Misc/Paths.h"

#include "glTFRuntimeFunctionLibrary.h"
#include "glTFRuntimeAsset.h"
#include "glTFRuntimeParser.h"

DEFINE_LOG_CATEGORY_STATIC(LogAnimImport, Log, All);

UAnimImportBridge::UAnimImportBridge()
{
    PrimaryComponentTick.bCanEverTick = false;
}

void UAnimImportBridge::ImportGLBAsync(const FString& JobUuid, const FString& GLBFilePath)
{
    if (JobUuid.IsEmpty() || GLBFilePath.IsEmpty())
    {
        OnMeshImportFailed.Broadcast(JobUuid, TEXT("参数为空"));
        return;
    }
    if (!FPaths::FileExists(GLBFilePath))
    {
        OnMeshImportFailed.Broadcast(JobUuid, FString::Printf(TEXT("文件不存在: %s"), *GLBFilePath));
        return;
    }

    // 缓存命中：直接广播已有 mesh
    if (UStaticMesh* Cached = FindCachedMesh(JobUuid))
    {
        UE_LOG(LogAnimImport, Log, TEXT("ImportGLBAsync: cache hit %s"), *JobUuid);
        OnMeshImported.Broadcast(JobUuid, Cached);
        return;
    }

    // Phase L1：用同步加载，几 MB 的 glb 在 game thread 一次性吃完
    // 后续若资产规模变大再升级到 glTFLoadAssetFromFilenameAsync + UFUNCTION 回调
    FglTFRuntimeConfig LoaderConfig;   // 默认配置
    UglTFRuntimeAsset* Asset = UglTFRuntimeFunctionLibrary::glTFLoadAssetFromFilename(
        GLBFilePath, /*bPathRelativeToContent*/false, LoaderConfig);

    if (!Asset)
    {
        UE_LOG(LogAnimImport, Error, TEXT("ImportGLBAsync: glTF 解析失败 %s"), *GLBFilePath);
        OnMeshImportFailed.Broadcast(JobUuid, TEXT("glTF 解析失败"));
        return;
    }

    // LoadStaticMeshRecursive 把整个 glb 场景合并成一个 StaticMesh，对 placeable 最合适
    FglTFRuntimeStaticMeshConfig StaticMeshConfig;   // 默认
    TArray<FString> ExcludeNodes;
    UStaticMesh* Mesh = Asset->LoadStaticMeshRecursive(/*NodeName*/FString(), ExcludeNodes, StaticMeshConfig);

    if (!Mesh)
    {
        UE_LOG(LogAnimImport, Error, TEXT("ImportGLBAsync: LoadStaticMeshRecursive 失败 %s"), *JobUuid);
        OnMeshImportFailed.Broadcast(JobUuid, TEXT("LoadStaticMeshRecursive 失败"));
        return;
    }

    MeshCache.Add(JobUuid, Mesh);
    UE_LOG(LogAnimImport, Log, TEXT("ImportGLBAsync ok: uuid=%s mesh=%s"), *JobUuid, *Mesh->GetName());
    OnMeshImported.Broadcast(JobUuid, Mesh);
}

AStaticMeshActor* UAnimImportBridge::SpawnMeshActor(UStaticMesh* Mesh, const FTransform& Transform)
{
    if (!Mesh) return nullptr;
    UWorld* World = GetWorld();
    if (!World) return nullptr;

    FActorSpawnParameters Params;
    Params.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;

    AStaticMeshActor* Actor = World->SpawnActor<AStaticMeshActor>(
        AStaticMeshActor::StaticClass(), Transform, Params);
    if (!Actor) return nullptr;

    if (UStaticMeshComponent* SMC = Actor->GetStaticMeshComponent())
    {
        SMC->SetMobility(EComponentMobility::Movable);
        SMC->SetStaticMesh(Mesh);
    }
    return Actor;
}

UStaticMesh* UAnimImportBridge::FindCachedMesh(const FString& JobUuid) const
{
    if (const TWeakObjectPtr<UStaticMesh>* Found = MeshCache.Find(JobUuid))
    {
        return Found->Get();
    }
    return nullptr;
}
