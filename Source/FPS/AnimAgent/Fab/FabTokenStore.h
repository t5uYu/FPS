// Copyright Epic Games, Inc. All Rights Reserved.
// FabTokenStore.h — 登录态持久化
//
// 文件位置：Saved/Fab/token.dat
// 编码：UTF-8 JSON → XOR 混淆 → base64 → 落盘
// 目的：防止玩家意外 "文件 → 另存为 → 外传" 时把 token 明文泄露，
//       并不是强加密；Windows 下如需更强可替换成 DPAPI，但一期不做。

#pragma once

#include "CoreMinimal.h"
#include "UObject/Object.h"
#include "FPS/AnimAgent/Fab/FabTypes.h"
#include "FabTokenStore.generated.h"

/** 落盘结构 */
USTRUCT()
struct FFabTokenRecord
{
    GENERATED_BODY()

    UPROPERTY() FString AccessToken;
    UPROPERTY() FString RefreshToken;
    UPROPERTY() int64   AccessIssuedAtSec  = 0;     // 本机时钟，单调性不保证但够用
    UPROPERTY() int64   AccessExpiresAtSec = 0;     // 0 表示未知
    UPROPERTY() FFabUser User;
    UPROPERTY() int64   SavedAtSec = 0;
};

UCLASS()
class FPS_API UFabTokenStore : public UObject
{
    GENERATED_BODY()

public:
    /** 绝对路径 Saved/Fab/token.dat */
    static FString GetTokenFilePath();

    /** 尝试加载；文件不存在或格式错误返回 false */
    static bool Load(FFabTokenRecord& OutRecord);

    /** 写回；失败时日志警告，不抛错 */
    static bool Save(const FFabTokenRecord& Record);

    /** 清空（Logout / refresh 失败时） */
    static bool Clear();

    /**
     * 尝试从 JWT 的 payload 段解析出 exp（Unix 秒）。
     * 解析失败返回 0；不校验签名，仅用来知道"大概什么时候过期"。
     */
    static int64 ExtractJwtExpSec(const FString& Jwt);
};
