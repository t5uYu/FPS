// Copyright Epic Games, Inc. All Rights Reserved.
// AnimAgentTypes.h — 共享枚举/结构

#pragma once

#include "CoreMinimal.h"
#include "AnimAgentTypes.generated.h"

/** 资产来源 */
UENUM(BlueprintType)
enum class EAnimAssetSource : uint8
{
    Local       UMETA(DisplayName = "Local"),         // 玩家本地导入
    Fab         UMETA(DisplayName = "Fab"),           // 后续 Fab 平台下载
    Generated   UMETA(DisplayName = "Generated"),     // 后续 Fab 调 AI 生成
};

/** 单条本地资产记录 */
USTRUCT(BlueprintType)
struct FAnimAssetRecord
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly)
    FString Uuid;

    UPROPERTY(BlueprintReadOnly)
    FString Name;

    /** 本地 .glb 绝对路径 */
    UPROPERTY(BlueprintReadOnly)
    FString GLBPath;

    UPROPERTY(BlueprintReadOnly)
    EAnimAssetSource Source = EAnimAssetSource::Local;

    /** 来源备注：本地导入时的原文件名；Fab 时的 fab_id；Generated 时的 prompt */
    UPROPERTY(BlueprintReadOnly)
    FString SourceNote;

    /** 创建时间（Unix 秒） */
    UPROPERTY(BlueprintReadOnly)
    int64 CreatedAtSeconds = 0;
};
