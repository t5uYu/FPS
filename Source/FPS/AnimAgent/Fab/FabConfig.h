// Copyright Epic Games, Inc. All Rights Reserved.
// FabConfig.h — Saved/Fab/config.json 运行时配置
//
// schema 见 Docs/Fab/2026-04-24_客户端桥接规划.md 第三节。

#pragma once

#include "CoreMinimal.h"
#include "UObject/Object.h"
#include "FabConfig.generated.h"

/**
 * Fab 客户端运行时配置。
 *
 * 使用方式：
 *   const UFabConfig* Cfg = UFabConfig::Get();
 *   const FString& Url = Cfg->BaseUrl;
 *
 * 首次启动若 Saved/Fab/config.json 不存在，会按 CDO 默认值落一份。
 * 不做热加载，改完重启生效。
 */
UCLASS(BlueprintType, Config = Game)
class FPS_API UFabConfig : public UObject
{
    GENERATED_BODY()

public:
    UFabConfig();

    /** Fab 服务端基础地址（不带末尾 /） */
    UPROPERTY(BlueprintReadOnly) FString BaseUrl;

    /** 普通请求超时（秒） */
    UPROPERTY(BlueprintReadOnly) float RequestTimeoutSec = 30.f;

    /** 下载 / 上传超时（秒） */
    UPROPERTY(BlueprintReadOnly) float DownloadTimeoutSec = 300.f;
    UPROPERTY(BlueprintReadOnly) float UploadTimeoutSec   = 300.f;

    /** AI 任务轮询：起始间隔 / 退避封顶（秒） */
    UPROPERTY(BlueprintReadOnly) float AiPollIntervalSec    = 5.f;
    UPROPERTY(BlueprintReadOnly) float AiPollMaxIntervalSec = 15.f;

    /** access_token 距过期多少秒以内算"即将过期"，主动 refresh */
    UPROPERTY(BlueprintReadOnly) int32 TokenRefreshLeewaySec = 60;

    /** 打开 [Fab] 日志（VeryVerbose） */
    UPROPERTY(BlueprintReadOnly) bool bVerboseLog = false;

    /** 绝对路径 Saved/Fab/config.json */
    UFUNCTION(BlueprintCallable, Category = "Fab|Config")
    static FString GetConfigFilePath();

    /**
     * 加载并返回全局单例；首次调用时若文件不存在会自动创建默认文件。
     * 失败兜底返回带默认值的实例，绝不返回 nullptr。
     */
    UFUNCTION(BlueprintCallable, Category = "Fab|Config")
    static UFabConfig* Get();

    /** 显式强制重载一次（调试用；正常流程不用调） */
    UFUNCTION(BlueprintCallable, Category = "Fab|Config")
    static UFabConfig* Reload();

    /** 拼 endpoint，如 AppendPath("/api/v1/auth/login") */
    FString Url(const FString& RelativePath) const;

private:
    /** 从 JSON 填字段；非法字段回退默认值，不抛错 */
    void LoadFromJsonString(const FString& Json);

    /** 把当前配置序列化为 JSON */
    FString ToJsonString() const;

    /** 全局缓存（WeakObject；GC 发生时会触发 Reload） */
    static TWeakObjectPtr<UFabConfig> GCached;
};
