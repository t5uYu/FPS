// Copyright Epic Games, Inc. All Rights Reserved.
// FabTypes.h — Fab 客户端桥接共享类型
//
// 对齐服务端契约：Backend/fab/Docs/v2.0.0.md 与 Docs/Fab/README.md
// 所有字段命名 / 枚举取值严格 1:1 映射后端 JSON，方便 FJsonObjectConverter 直接反序列化。

#pragma once

#include "CoreMinimal.h"
#include "FabTypes.generated.h"

//=============================================================================
// 枚举
//=============================================================================

/** 资产类型，对应后端 assets.asset_type */
UENUM(BlueprintType)
enum class EFabAssetType : uint8
{
    Unknown UMETA(DisplayName = "unknown"),
    Model   UMETA(DisplayName = "model"),
    Map     UMETA(DisplayName = "map"),
};

/** 资产状态；v2.0 之后后端只写 2（Online）；其它值仅在读取 v1.x 遗留数据时出现 */
UENUM(BlueprintType)
enum class EFabAssetStatus : uint8
{
    Unknown          UMETA(DisplayName = "unknown"),
    LegacyPending    UMETA(DisplayName = "legacy-pending"),    // v1.x status=0
    LegacyPackaging  UMETA(DisplayName = "legacy-packaging"),  // v1.x status=1
    Online           UMETA(DisplayName = "online"),            // v2.0 默认
    Rejected         UMETA(DisplayName = "rejected"),          // v1.x status=3
};

/** 用户角色 */
UENUM(BlueprintType)
enum class EFabUserRole : uint8
{
    Player UMETA(DisplayName = "player"),
    Admin  UMETA(DisplayName = "admin"),
};

/** AI 任务状态，对应后端 ai_tasks.status */
UENUM(BlueprintType)
enum class EFabAiTaskStatus : uint8
{
    Unknown    UMETA(DisplayName = "unknown"),
    Pending    UMETA(DisplayName = "pending"),
    Processing UMETA(DisplayName = "processing"),
    Succeeded  UMETA(DisplayName = "succeeded"),
    Failed     UMETA(DisplayName = "failed"),
};

//=============================================================================
// 通用错误
//=============================================================================

/**
 * Fab 客户端统一错误壳。
 * - HttpCode=0 表示网络层失败（未建立连接 / 取消 / 超时）
 * - BizCode 透传后端响应体里的 code（成功是 0，失败是非零；定义见 Backend/fab/backend/app/errors.py）
 */
USTRUCT(BlueprintType)
struct FFabError
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly)
    int32 HttpCode = 0;

    UPROPERTY(BlueprintReadOnly)
    int32 BizCode = 0;

    UPROPERTY(BlueprintReadOnly)
    FString Message;

    bool IsOk() const { return HttpCode >= 200 && HttpCode < 300 && BizCode == 0; }

    static FFabError Ok() { return FFabError{}; }
    static FFabError Network(const FString& InMessage)
    {
        FFabError E; E.HttpCode = 0; E.BizCode = -1; E.Message = InMessage; return E;
    }
};

//=============================================================================
// 用户 & 鉴权
//=============================================================================

USTRUCT(BlueprintType)
struct FFabUser
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly) int32 Id = 0;

    UPROPERTY(BlueprintReadOnly) FString UserAccount;

    UPROPERTY(BlueprintReadOnly) FString UserName;

    UPROPERTY(BlueprintReadOnly) EFabUserRole UserRole = EFabUserRole::Player;

    UPROPERTY(BlueprintReadOnly) int32 AiQuota = 0;

    UPROPERTY(BlueprintReadOnly) int32 AiUsed = 0;

    UPROPERTY(BlueprintReadOnly) FString AvatarUrl;
};

/** 登录 / 注册 / refresh 三个接口的成功响应（后端 data 段） */
USTRUCT(BlueprintType)
struct FFabAuthResult
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly) FString AccessToken;
    UPROPERTY(BlueprintReadOnly) FString RefreshToken;

    /** access_token 的剩余秒数（JWT exp - now），由客户端解析得出；后端无此字段 */
    UPROPERTY(BlueprintReadOnly) int32 AccessExpiresInSec = 0;

    UPROPERTY(BlueprintReadOnly) FFabUser User;
};

//=============================================================================
// 资产
//=============================================================================

/** 资产 DTO，对应后端 AssetOut */
USTRUCT(BlueprintType)
struct FFabAssetItem
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly) int32 Id = 0;

    UPROPERTY(BlueprintReadOnly) FString Name;

    UPROPERTY(BlueprintReadOnly) EFabAssetType AssetType = EFabAssetType::Unknown;

    UPROPERTY(BlueprintReadOnly) EFabAssetStatus Status = EFabAssetStatus::Unknown;

    UPROPERTY(BlueprintReadOnly) FString Description;

    UPROPERTY(BlueprintReadOnly) TArray<FString> Tags;

    UPROPERTY(BlueprintReadOnly) FString ThumbnailUrl;

    UPROPERTY(BlueprintReadOnly) int32 UserId = 0;

    UPROPERTY(BlueprintReadOnly) FString UserName;

    UPROPERTY(BlueprintReadOnly) int32 SizeBytes = 0;

    UPROPERTY(BlueprintReadOnly) FString SourceNote;  // "upload" / "ai_text" / "ai_image"

    UPROPERTY(BlueprintReadOnly) int64 CreatedAtSeconds = 0;

    UPROPERTY(BlueprintReadOnly) int64 UpdatedAtSeconds = 0;
};

/** 列表请求 */
USTRUCT(BlueprintType)
struct FFabAssetQuery
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite) FString Keyword;

    UPROPERTY(BlueprintReadWrite) EFabAssetType AssetType = EFabAssetType::Unknown; // Unknown = 不过滤

    UPROPERTY(BlueprintReadWrite) bool bOnlyMine = false;

    UPROPERTY(BlueprintReadWrite) int32 Page = 1;

    UPROPERTY(BlueprintReadWrite) int32 PageSize = 20;
};

/** 分页响应 */
USTRUCT(BlueprintType)
struct FFabAssetListResult
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly) int32 Total = 0;
    UPROPERTY(BlueprintReadOnly) int32 Page = 1;
    UPROPERTY(BlueprintReadOnly) int32 PageSize = 20;
    UPROPERTY(BlueprintReadOnly) TArray<FFabAssetItem> Items;
};

/** 上传请求 */
USTRUCT(BlueprintType)
struct FFabUploadRequest
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite) FString Name;
    UPROPERTY(BlueprintReadWrite) EFabAssetType AssetType = EFabAssetType::Model;
    UPROPERTY(BlueprintReadWrite) FString LocalFilePath;       // 待上传的本地 .glb / .zip 绝对路径
    UPROPERTY(BlueprintReadWrite) TArray<FString> Tags;
    UPROPERTY(BlueprintReadWrite) FString Description;
};

/** 资产局部修改 */
USTRUCT(BlueprintType)
struct FFabAssetPatch
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite) FString Name;
    UPROPERTY(BlueprintReadWrite) FString Description;
    UPROPERTY(BlueprintReadWrite) TArray<FString> Tags;

    /** bitmask：决定哪些字段参与 PATCH（避免 FString="" 和 "未设置" 歧义） */
    UPROPERTY(BlueprintReadWrite) bool bSetName = false;
    UPROPERTY(BlueprintReadWrite) bool bSetDescription = false;
    UPROPERTY(BlueprintReadWrite) bool bSetTags = false;
};

/** 下载结果：本地落盘路径 */
USTRUCT(BlueprintType)
struct FFabDownloadResult
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly) int32 AssetId = 0;

    /** Saved/AnimAgent/assets/{uuid}/source.glb 或 source.zip */
    UPROPERTY(BlueprintReadOnly) FString LocalFilePath;

    /** 本地存放使用的 uuid（FGuid 字符串） */
    UPROPERTY(BlueprintReadOnly) FString LocalUuid;

    UPROPERTY(BlueprintReadOnly) int32 SizeBytes = 0;
};

//=============================================================================
// AI 任务
//=============================================================================

/** 对应后端 ai_tasks.kind */
UENUM(BlueprintType)
enum class EFabAiTaskKind : uint8
{
    Unknown UMETA(DisplayName = "unknown"),
    Text    UMETA(DisplayName = "text_to_model"),
    Image   UMETA(DisplayName = "image_to_model"),
};

USTRUCT(BlueprintType)
struct FFabAiTask
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly) int32 Id = 0;

    UPROPERTY(BlueprintReadOnly) EFabAiTaskKind Kind = EFabAiTaskKind::Unknown;

    UPROPERTY(BlueprintReadOnly) EFabAiTaskStatus Status = EFabAiTaskStatus::Unknown;

    UPROPERTY(BlueprintReadOnly) int32 Progress = 0;   // 0~100

    UPROPERTY(BlueprintReadOnly) FString InputText;

    UPROPERTY(BlueprintReadOnly) FString InputImageUrl;

    /**
     * 任务完成后，Meshy 产物转存到 MinIO 的对象 key，与 Fab Asset.raw_url 一致。
     * 客户端可用它反查对应资产：ListAssets(only_mine=true) 找 raw_url == OutputModelUrl
     */
    UPROPERTY(BlueprintReadOnly) FString OutputModelUrl;

    /**
     * 客户端本地解析出的对应 Fab 资产 id（通过 OutputModelUrl 反查）。
     * 服务端 AiTaskOut 不直接返回 asset_id，未解析前为 0。
     */
    UPROPERTY(BlueprintReadOnly) int32 AssetId = 0;

    /** Meshy 远端 task_id（调试用，客户端一般不关心） */
    UPROPERTY(BlueprintReadOnly) FString RemoteTaskId;

    UPROPERTY(BlueprintReadOnly) FString ErrorMessage;

    UPROPERTY(BlueprintReadOnly) int64 CreatedAtSeconds = 0;
    UPROPERTY(BlueprintReadOnly) int64 FinishAtSeconds = 0;
};

USTRUCT(BlueprintType)
struct FFabAiTaskListResult
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly) int32 Total = 0;
    UPROPERTY(BlueprintReadOnly) int32 Page = 1;
    UPROPERTY(BlueprintReadOnly) int32 PageSize = 20;
    UPROPERTY(BlueprintReadOnly) TArray<FFabAiTask> Items;
};

//=============================================================================
// Delegate 签名
//=============================================================================

DECLARE_DYNAMIC_DELEGATE_TwoParams(
    FFabAuthDelegate,
    const FFabError&, Error,
    const FFabAuthResult&, Result);

DECLARE_DYNAMIC_DELEGATE_OneParam(
    FFabSimpleDelegate,
    const FFabError&, Error);

DECLARE_DYNAMIC_DELEGATE_TwoParams(
    FFabAssetItemDelegate,
    const FFabError&, Error,
    const FFabAssetItem&, Asset);

DECLARE_DYNAMIC_DELEGATE_TwoParams(
    FFabAssetListDelegate,
    const FFabError&, Error,
    const FFabAssetListResult&, Result);

DECLARE_DYNAMIC_DELEGATE_TwoParams(
    FFabDownloadDelegate,
    const FFabError&, Error,
    const FFabDownloadResult&, Result);

DECLARE_DYNAMIC_DELEGATE_TwoParams(
    FFabAiTaskDelegate,
    const FFabError&, Error,
    const FFabAiTask&, Task);

DECLARE_DYNAMIC_DELEGATE_TwoParams(
    FFabAiTaskListDelegate,
    const FFabError&, Error,
    const FFabAiTaskListResult&, Result);

//=============================================================================
// 组件级多播事件
//=============================================================================

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(
    FOnFabAuthChanged,
    const FFabUser&, User);       // 登录 / refresh 更新；Logout 时派空 User

DECLARE_DYNAMIC_MULTICAST_DELEGATE(
    FOnFabAuthExpired);           // refresh 也失败，需要玩家重新登录

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(
    FOnFabGlobalError,
    const FFabError&, Error);

DECLARE_DYNAMIC_MULTICAST_DELEGATE_FourParams(
    FOnFabDownloadProgress,
    int32, AssetId,
    int32, BytesReceived,
    int32, TotalBytes,
    const FString&, LocalFilePath);

/**
 * 下载完成多播（无论成功失败都广播）。
 * 给 UI 订阅用，尤其是 Lua：UnLua 对 DECLARE_DYNAMIC_DELEGATE 的一次性回调绑定不友好，
 * 用多播就能 :Add(self, fn) 搞定。
 */
DECLARE_DYNAMIC_MULTICAST_DELEGATE_ThreeParams(
    FOnFabDownloadCompleted,
    int32, AssetId,
    const FFabError&, Error,
    const FFabDownloadResult&, Result);

/**
 * 登录 / 注册完成多播（无论成功失败都广播）。
 * 使用场景同 OnDownloadCompleted，给 UMG/Lua 订阅。
 * 和既有的 `FFabAuthDelegate`（一次性）并存：
 *   - 纯 BP 项目：`Login(acc, pwd, BP 生成的 OnComplete)` 用一次性回调
 *   - Lua 项目：`LoginSimple(acc, pwd)` + 订阅 `OnLoginCompleted` 多播
 */
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(
    FOnFabAuthCompleted,
    const FFabError&, Error,
    const FFabAuthResult&, Result);

DECLARE_DYNAMIC_MULTICAST_DELEGATE_FourParams(
    FOnFabUploadProgress,
    const FString&, LocalFilePath,
    int32, BytesSent,
    int32, TotalBytes,
    const FString&, RequestId);

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(
    FOnFabUploadCompleted,
    const FFabError&, Error,
    const FFabAssetItem&, Asset);

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(
    FOnFabAiTaskCompleted,
    const FFabError&, Error,
    const FFabAiTask&, Task);
