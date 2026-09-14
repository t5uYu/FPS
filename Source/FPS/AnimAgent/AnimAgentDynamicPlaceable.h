// Copyright Epic Games, Inc. All Rights Reserved.
// AnimAgentDynamicPlaceable.h
//
// 让 GLB 资产能复用整套 UGC Placeable 基建（高亮/Gizmo/SceneData/保存读档/Undo）。
// 设计：单一 native 类，spawn 时 mesh 为空，由 Lua 侧立即 SetDynMesh 注入。

#pragma once

#include "CoreMinimal.h"
#include "Engine/StaticMeshActor.h"
#include "AnimAgentDynamicPlaceable.generated.h"

class UStaticMesh;

UCLASS(ClassGroup = "AnimAgent")
class FPS_API AAnimAgentDynamicPlaceable : public AStaticMeshActor
{
    GENERATED_BODY()

public:
    AAnimAgentDynamicPlaceable();

    /** 关联的 AnimAsset uuid（与 AnimAssetLibrary / UGCPrefabRegistry.DynamicGLB 同 key） */
    UPROPERTY(BlueprintReadOnly, Category = "AnimAgent")
    FString AssetUuid;

    /** 注入 GLB 加载得到的 mesh + 记录 uuid */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    void SetDynMesh(UStaticMesh* Mesh, const FString& InAssetUuid);

    //--------------------------------------------------------------
    // Placeable 接口兼容（SceneData / UGCEditorCore 调用）
    // 现有 BP_Placeable_* 蓝图实现的方法，dyn 这边给空实现避免 pcall 失败
    //--------------------------------------------------------------

    UFUNCTION(BlueprintCallable, Category = "Placeable")
    void SetDebugVisible(bool bVisible) {}

    UFUNCTION(BlueprintCallable, Category = "Placeable")
    void SetProgramID(const FString& InProgramID) {}
};
