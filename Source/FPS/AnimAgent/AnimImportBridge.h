// Copyright Epic Games, Inc. All Rights Reserved.
// AnimImportBridge.h — glb 运行时导入 + 场景生成
//
// 当前阶段：仅提供骨架接口，待 glTFRuntime 插件安装后填充 Cpp 实现。
// 设计目标：把 Saved/AnimAgent/assets/{uuid}/source.glb 加载为 UStaticMesh* 并 spawn 出 AStaticMeshActor。

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "AnimImportBridge.generated.h"

class AStaticMeshActor;
class UStaticMesh;

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(
    FOnAnimMeshImported, const FString&, JobUuid, UStaticMesh*, ImportedMesh);

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(
    FOnAnimMeshImportFailed, const FString&, JobUuid, const FString&, ErrorMessage);

/**
 * UAnimImportBridge
 *
 * 职责：
 * - 把本地 glb → UStaticMesh*（运行时，依赖 glTFRuntime）
 * - 把 mesh spawn 到场景指定 transform
 * - 维护 uuid → 已加载 Mesh 的弱引用缓存
 *
 * 注意：
 * - 当前 cpp 仅留 stub，glTFRuntime 安装后填充
 * - 需要在 FPS.Build.cs 添加 "glTFRuntime" 模块依赖
 */
UCLASS(ClassGroup = "AnimAgent", meta = (BlueprintSpawnableComponent))
class FPS_API UAnimImportBridge : public UActorComponent
{
    GENERATED_BODY()

public:
    UAnimImportBridge();

    UPROPERTY(BlueprintAssignable, Category = "AnimAgent|Events")
    FOnAnimMeshImported OnMeshImported;

    UPROPERTY(BlueprintAssignable, Category = "AnimAgent|Events")
    FOnAnimMeshImportFailed OnMeshImportFailed;

    /**
     * 异步把 glb 文件解析为 UStaticMesh
     * @param JobUuid       关联的生成任务 uuid
     * @param GLBFilePath   绝对路径
     */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    void ImportGLBAsync(const FString& JobUuid, const FString& GLBFilePath);

    /**
     * 把已经加载的 mesh spawn 到场景
     * @return 新生成的 AStaticMeshActor*，失败返回 nullptr
     */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    AStaticMeshActor* SpawnMeshActor(UStaticMesh* Mesh, const FTransform& Transform);

    /** 查询缓存中是否已有该 uuid 的 mesh */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    UStaticMesh* FindCachedMesh(const FString& JobUuid) const;

private:
    /** uuid → mesh 弱引用 */
    UPROPERTY()
    TMap<FString, TWeakObjectPtr<UStaticMesh>> MeshCache;
};
