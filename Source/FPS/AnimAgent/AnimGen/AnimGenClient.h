// Copyright Epic Games, Inc. All Rights Reserved.
// AnimGenClient.h — 本地资产客户端组件，挂在 PlayerController 上
//
// Phase L1（本地导入）：
// - 接收"导入本地 .glb"请求
// - 拷贝到 Saved/AnimAgent/assets/{uuid}/source.glb
// - 委托 UAnimImportBridge 加载为 UStaticMesh
// - 通过事件广播给 Lua / UI
//
// 后续 Phase F（Fab 平台）会在此组件加 Fab REST 客户端。

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "FPS/AnimAgent/AnimAgentTypes.h"
#include "AnimGenClient.generated.h"

class UAnimImportBridge;

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(
    FOnAnimAssetImported, const FString&, AssetUuid, const FString&, GLBPath);

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(
    FOnAnimAssetImportFailed, const FString&, AssetUuid, const FString&, ErrorMessage);

UCLASS(ClassGroup = "AnimAgent", meta = (BlueprintSpawnableComponent))
class FPS_API UAnimGenClient : public UActorComponent
{
    GENERATED_BODY()

public:
    UAnimGenClient();

    //--------------------------------------------------------------
    // 事件（Lua / BP 订阅）
    //--------------------------------------------------------------

    UPROPERTY(BlueprintAssignable, Category = "AnimAgent|Events")
    FOnAnimAssetImported OnAssetImported;

    UPROPERTY(BlueprintAssignable, Category = "AnimAgent|Events")
    FOnAnimAssetImportFailed OnAssetImportFailed;

    //--------------------------------------------------------------
    // API
    //--------------------------------------------------------------

    /**
     * 从本地 .glb 文件导入资产
     * 流程：拷贝到 Saved/AnimAgent/assets/{uuid}/source.glb → 广播事件
     * @param SourceFilePath 玩家选择的本地绝对路径
     * @param DesiredName    资产显示名（空时取原文件名）
     * @return 新生成的资产 uuid，失败返回空串
     */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    FString ImportLocalGLB(const FString& SourceFilePath, const FString& DesiredName);

    /**
     * 把已导入的资产导出到指定文件
     * 拷贝 source.glb 到目标路径，并在同目录落 .meta.json（来源/名称）
     * @return 是否成功
     */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    bool ExportLocalGLB(const FString& AssetUuid, const FString& TargetFilePath);

    /** 取本地缓存目录绝对路径（Saved/AnimAgent/assets/） */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    static FString GetAssetsCacheDir();

    /**
     * 弹出系统"打开文件"对话框（仅桌面平台）
     * @param DialogTitle  标题
     * @param DefaultPath  初始目录（空则系统默认）
     * @param FileTypes    过滤器，如 "GLB Model (*.glb)|*.glb"
     * @param bAllowMulti  是否允许多选
     * @return 选中的绝对路径列表（用户取消则空）
     */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    static TArray<FString> OpenFileDialog(
        const FString& DialogTitle,
        const FString& DefaultPath,
        const FString& FileTypes,
        bool bAllowMulti);

    /**
     * 弹出系统"保存文件"对话框
     * @return 选中的目标路径（用户取消则空）
     */
    UFUNCTION(BlueprintCallable, Category = "AnimAgent")
    static FString SaveFileDialog(
        const FString& DialogTitle,
        const FString& DefaultPath,
        const FString& DefaultFileName,
        const FString& FileTypes);

    //--------------------------------------------------------------
    // UActorComponent
    //--------------------------------------------------------------
    virtual void BeginPlay() override;
};
