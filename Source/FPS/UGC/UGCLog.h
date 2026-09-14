// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "UGCLog.generated.h"

/**
 * UGC 独立日志分类。
 *
 * UGC 的 Lua 侧统一经 UGCLog.lua 出日志；当运行时有 UnLua/UE 环境时，
 * 该模块把结构化单行转发到这里，于是所有 UGC 事件都落在 LogFPSUGC 分类下，
 * 可以被 `-LogCmds="LogFPSUGC Verbose"` 或日志采集单独开关与过滤。
 */
DECLARE_LOG_CATEGORY_EXTERN(LogFPSUGC, Log, All);

/** UGC 结构化日志的 C++ 落点（供 Lua 调用）。 */
UCLASS(ClassGroup = "UGC")
class FPS_API UUGCLog : public UBlueprintFunctionLibrary
{
    GENERATED_BODY()

public:
    /**
     * 写入一条结构化 UGC 日志。
     *
     * @param Severity   "debug" / "info" / "warning" / "error"（大小写不敏感，未知值按 info 处理）
     * @param Event      事件名，例如 "command" / "save_project" / "session_begin"
     * @param FieldsJson 字段 JSON（Lua 侧由 Util.json 生成，键序稳定），可为空
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Log")
    static void WriteLine(const FString& Severity, const FString& Event, const FString& FieldsJson);

    /** 把 severity 字符串规范化为 "debug"/"info"/"warning"/"error"（未知值 -> "info"）。 */
    UFUNCTION(BlueprintPure, Category = "UGC|Log")
    static FString NormalizeSeverity(const FString& Severity);
};