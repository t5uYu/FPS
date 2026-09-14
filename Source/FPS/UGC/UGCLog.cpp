// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCLog.h"

DEFINE_LOG_CATEGORY(LogFPSUGC);

namespace UGCLogPrivate
{
    /** severity 字符串 -> 日志 verbosity；未知值按 Log 处理，保证不会因为拼错而丢日志。 */
    static ELogVerbosity::Type ToVerbosity(const FString& Normalized)
    {
        if (Normalized == TEXT("error"))   return ELogVerbosity::Error;
        if (Normalized == TEXT("warning")) return ELogVerbosity::Warning;
        if (Normalized == TEXT("debug"))   return ELogVerbosity::Verbose;
        return ELogVerbosity::Log;
    }
}

FString UUGCLog::NormalizeSeverity(const FString& Severity)
{
    const FString Lower = Severity.ToLower();
    if (Lower == TEXT("error") || Lower == TEXT("warning") || Lower == TEXT("debug"))
    {
        return Lower;
    }
    return TEXT("info");
}

void UUGCLog::WriteLine(const FString& Severity, const FString& Event, const FString& FieldsJson)
{
    // 单行输出，字段由 Lua 侧编排（session/command/program/entity/code + fields JSON），
    // C++ 只负责分级与分流，避免两端各写一套格式。
    const FString Line = FieldsJson.IsEmpty()
        ? FString::Printf(TEXT("event=%s"), *Event)
        : FString::Printf(TEXT("event=%s fields=%s"), *Event, *FieldsJson);

    switch (UGCLogPrivate::ToVerbosity(NormalizeSeverity(Severity)))
    {
    case ELogVerbosity::Error:
        UE_LOG(LogFPSUGC, Error, TEXT("%s"), *Line);
        break;
    case ELogVerbosity::Warning:
        UE_LOG(LogFPSUGC, Warning, TEXT("%s"), *Line);
        break;
    case ELogVerbosity::Verbose:
        UE_LOG(LogFPSUGC, Verbose, TEXT("%s"), *Line);
        break;
    default:
        UE_LOG(LogFPSUGC, Log, TEXT("%s"), *Line);
        break;
    }
}