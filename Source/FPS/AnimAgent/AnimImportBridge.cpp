// Copyright Epic Games, Inc. All Rights Reserved.

#include "AnimImportBridge.h"
#include "Engine/StaticMesh.h"
#include "Engine/StaticMeshActor.h"
#include "Engine/World.h"
#include "Materials/MaterialInterface.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"

#include "glTFRuntimeFunctionLibrary.h"
#include "glTFRuntimeAsset.h"
#include "glTFRuntimeParser.h"

DEFINE_LOG_CATEGORY_STATIC(LogAnimImport, Log, All);

namespace
{
    void LogMeshDiagnostics(const FString& Key, UStaticMesh* Mesh)
    {
        if (!Mesh)
        {
            return;
        }

        const TArray<FStaticMaterial>& Materials = Mesh->GetStaticMaterials();
        UE_LOG(LogAnimImport, Log, TEXT("Runtime asset diagnostics key=%s mesh=%s materials=%d"),
            *Key, *Mesh->GetName(), Materials.Num());

        for (int32 Index = 0; Index < Materials.Num(); ++Index)
        {
            const UMaterialInterface* Material = Materials[Index].MaterialInterface;
            UE_LOG(LogAnimImport, Log, TEXT("  slot[%d] name=%s material=%s"),
                Index,
                *Materials[Index].MaterialSlotName.ToString(),
                Material ? *Material->GetName() : TEXT("<null>"));
        }
    }
}

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

    // 当前仍用同步加载，几 MB 的本地 glTF/GLB 在 game thread 一次性吃完。
    // 后续若资产规模变大再升级到 glTFLoadAssetFromFilenameAsync + UFUNCTION 回调
    FglTFRuntimeConfig LoaderConfig;   // 默认配置
    UglTFRuntimeAsset* Asset = UglTFRuntimeFunctionLibrary::glTFLoadAssetFromFilename(
        GLBFilePath, /*bPathRelativeToContent*/false, LoaderConfig);

    if (!Asset)
    {
        UE_LOG(LogAnimImport, Error, TEXT("ImportGLBAsync: glTF/UGC 解析失败 %s"), *GLBFilePath);
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
    UE_LOG(LogAnimImport, Log, TEXT("ImportGLBAsync ok: key=%s mesh=%s"), *JobUuid, *Mesh->GetName());
    LogMeshDiagnostics(JobUuid, Mesh);
    OnMeshImported.Broadcast(JobUuid, Mesh);
}

void UAnimImportBridge::ImportRuntimeAssetAsync(const FString& PackageId, const FString& ManifestPath)
{
    if (PackageId.IsEmpty() || ManifestPath.IsEmpty())
    {
        OnMeshImportFailed.Broadcast(PackageId, TEXT("PackageId 或 ManifestPath 为空"));
        return;
    }
    if (!FPaths::FileExists(ManifestPath))
    {
        OnMeshImportFailed.Broadcast(PackageId, FString::Printf(TEXT("manifest 不存在: %s"), *ManifestPath));
        return;
    }
    if (UStaticMesh* Cached = FindCachedMesh(PackageId))
    {
        UE_LOG(LogAnimImport, Log, TEXT("ImportRuntimeAssetAsync: cache hit %s"), *PackageId);
        OnMeshImported.Broadcast(PackageId, Cached);
        return;
    }

    FString ManifestText;
    if (!FFileHelper::LoadFileToString(ManifestText, *ManifestPath))
    {
        OnMeshImportFailed.Broadcast(PackageId, TEXT("读取 manifest 失败"));
        return;
    }

    TSharedPtr<FJsonObject> Root;
    const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(ManifestText);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid())
    {
        OnMeshImportFailed.Broadcast(PackageId, TEXT("manifest JSON 解析失败"));
        return;
    }

    FString ModelRelativePath;
    Root->TryGetStringField(TEXT("model"), ModelRelativePath);
    if (ModelRelativePath.IsEmpty())
    {
        OnMeshImportFailed.Broadcast(PackageId, TEXT("manifest 缺少 model 字段"));
        return;
    }

    FString SourceType;
    Root->TryGetStringField(TEXT("source_type"), SourceType);
    if (SourceType.Equals(TEXT("zip"), ESearchCase::IgnoreCase))
    {
        UE_LOG(LogAnimImport, Warning,
            TEXT("ImportRuntimeAssetAsync: package=%s 是 zip 输入；若 zip 内没有 glTFRuntime 可直接识别的 glTF，将加载失败"),
            *PackageId);
    }

    const FString PackageDir = FPaths::GetPath(ManifestPath);
    const FString ModelPath = FPaths::ConvertRelativePathToFull(FPaths::Combine(PackageDir, ModelRelativePath));
    UE_LOG(LogAnimImport, Log, TEXT("ImportRuntimeAssetAsync: package=%s manifest=%s model=%s"),
        *PackageId, *ManifestPath, *ModelPath);

    ImportGLBAsync(PackageId, ModelPath);
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
