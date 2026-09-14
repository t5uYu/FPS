// Copyright Epic Games, Inc. All Rights Reserved.
// FabClientBridge.h — Fab 后端 REST 客户端桥接
//
// 路线 A 核心：游戏内通过 HTTP 直连 Fab（Backend/fab，v2.0.0+）。
// 挂在 APlayerController 上，Lua / Blueprint / UMG 通过它发起所有 Fab 操作。
//
// 设计要点：
//  - 启动时自动 Load Saved/Fab/token.dat；有效则恢复登录态
//  - 每个 authed 请求前检查 access_token exp；距离过期 < leeway 时先 refresh
//  - 401 时单飞 refresh，其余并发请求排队；refresh 成功后重放
//  - 下载走"拿 presigned URL → 直连 MinIO 流式下载到 Saved/AnimAgent/assets/{uuid}/"
//  - 上传走手搓 multipart/form-data（UE 没有现成的 multipart）

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "Interfaces/IHttpRequest.h"
#include "FPS/AnimAgent/Fab/FabTypes.h"
#include "FabClientBridge.generated.h"

class UFabConfig;

UCLASS(ClassGroup = "Fab", meta = (BlueprintSpawnableComponent))
class FPS_API UFabClientBridge : public UActorComponent
{
    GENERATED_BODY()

public:
    UFabClientBridge();

    //---------------------------------------------------------
    // 组件级事件
    //---------------------------------------------------------

    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabAuthChanged OnAuthChanged;

    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabAuthExpired OnAuthExpired;

    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabGlobalError OnGlobalError;

    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabDownloadProgress OnDownloadProgress;

    /** 下载终态多播；成功 Err.IsOk()==true，失败 Err 带 HttpCode/BizCode/Message。
     *  给 Lua / UMG 订阅：Lua 里 `bridge.OnDownloadCompleted:Add(self, self.OnDone)` 即可。*/
    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabDownloadCompleted OnDownloadCompleted;

    /** 登录终态多播；成功 Err.IsOk()==true。给 Lua/UMG 订阅 */
    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabAuthCompleted OnLoginCompleted;

    /** 注册终态多播；成功 Err.IsOk()==true，后端会自动登录并回填 Result */
    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabAuthCompleted OnRegisterCompleted;

    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabUploadProgress OnUploadProgress;

    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabUploadCompleted OnUploadCompleted;

    UPROPERTY(BlueprintAssignable, Category = "Fab|Events")
    FOnFabAiTaskCompleted OnAiTaskCompleted;

    //---------------------------------------------------------
    // 鉴权
    //---------------------------------------------------------

    UFUNCTION(BlueprintCallable, Category = "Fab|Auth")
    void Login(const FString& Account, const FString& Password, const FFabAuthDelegate& OnComplete);

    UFUNCTION(BlueprintCallable, Category = "Fab|Auth")
    void Register(const FString& Account, const FString& Password, const FString& UserName,
                  const FFabAuthDelegate& OnComplete);

    /** Lua 友好的登录入口：不带一次性委托；结果走 OnLoginCompleted 多播 */
    UFUNCTION(BlueprintCallable, Category = "Fab|Auth")
    void LoginSimple(const FString& Account, const FString& Password);

    /** Lua 友好的注册入口：不带一次性委托；结果走 OnRegisterCompleted 多播 */
    UFUNCTION(BlueprintCallable, Category = "Fab|Auth")
    void RegisterSimple(const FString& Account, const FString& Password, const FString& UserName);

    UFUNCTION(BlueprintCallable, Category = "Fab|Auth")
    void Logout();

    UFUNCTION(BlueprintCallable, BlueprintPure, Category = "Fab|Auth")
    bool IsLoggedIn() const;

    UFUNCTION(BlueprintCallable, BlueprintPure, Category = "Fab|Auth")
    FFabUser GetCurrentUser() const { return CurrentUser; }

    /** 当前 access_token 明文。未登录返回空串。供 WBP_FabPanel 注 CEF cookie */
    UFUNCTION(BlueprintCallable, BlueprintPure, Category = "Fab|Auth")
    FString GetAccessToken() const { return AccessToken; }

    /** 当前 refresh_token 明文。未登录返回空串 */
    UFUNCTION(BlueprintCallable, BlueprintPure, Category = "Fab|Auth")
    FString GetRefreshToken() const { return RefreshToken; }

    //---------------------------------------------------------
    // 资产
    //---------------------------------------------------------

    UFUNCTION(BlueprintCallable, Category = "Fab|Asset")
    void ListAssets(const FFabAssetQuery& Query, const FFabAssetListDelegate& OnComplete);

    UFUNCTION(BlueprintCallable, Category = "Fab|Asset")
    void GetAsset(int32 AssetId, const FFabAssetItemDelegate& OnComplete);

    /**
     * 完整下载链路：
     *   1. GET /assets/{id}/download 拿 presigned URL
     *   2. HEAD URL 或直接 GET 流式写盘到 Saved/AnimAgent/assets/{localUuid}/source.{ext}
     *   3. 回调 FFabDownloadResult{assetId, localFilePath, localUuid, sizeBytes}
     *
     * 期间通过 OnDownloadProgress 广播进度。
     */
    UFUNCTION(BlueprintCallable, Category = "Fab|Asset")
    void DownloadAsset(int32 AssetId, const FFabDownloadDelegate& OnComplete);

    UFUNCTION(BlueprintCallable, Category = "Fab|Asset")
    void UploadAsset(const FFabUploadRequest& Request, const FFabAssetItemDelegate& OnComplete);

    /** Lua/LLM 友好的模型发布入口；完成结果走 OnUploadCompleted 多播。 */
    UFUNCTION(BlueprintCallable, Category = "Fab|Asset")
    void UploadModelSimple(const FString& Name, const FString& LocalFilePath,
                           const FString& Description, const FString& TagsCsv);

    UFUNCTION(BlueprintCallable, Category = "Fab|Asset")
    void UpdateAsset(int32 AssetId, const FFabAssetPatch& Patch, const FFabAssetItemDelegate& OnComplete);

    UFUNCTION(BlueprintCallable, Category = "Fab|Asset")
    void DeleteAsset(int32 AssetId, const FFabSimpleDelegate& OnComplete);

    //---------------------------------------------------------
    // AI 任务
    //---------------------------------------------------------

    UFUNCTION(BlueprintCallable, Category = "Fab|AI")
    void CreateAiTextTask(const FString& Prompt, const FString& Mode, const FFabAiTaskDelegate& OnComplete);

    /** Lua/LLM 友好的文生模型入口；完成结果走 OnAiTaskCompleted 多播。 */
    UFUNCTION(BlueprintCallable, Category = "Fab|AI")
    void CreateAiTextTaskSimple(const FString& Prompt, const FString& Mode);

    UFUNCTION(BlueprintCallable, Category = "Fab|AI")
    void CreateAiImageTask(const FString& ImageUrl, const FString& Mode, const FFabAiTaskDelegate& OnComplete);

    /** Lua/LLM 友好的图生模型入口；完成结果走 OnAiTaskCompleted 多播。 */
    UFUNCTION(BlueprintCallable, Category = "Fab|AI")
    void CreateAiImageTaskSimple(const FString& ImageUrl, const FString& Mode);

    UFUNCTION(BlueprintCallable, Category = "Fab|AI")
    void ListAiTasks(int32 StatusFilter, int32 Page, int32 PageSize, const FFabAiTaskListDelegate& OnComplete);

    UFUNCTION(BlueprintCallable, Category = "Fab|AI")
    void GetAiTask(int32 TaskId, const FFabAiTaskDelegate& OnComplete);

    /** Lua/LLM 友好的任务查询入口；完成结果走 OnAiTaskCompleted 多播。 */
    UFUNCTION(BlueprintCallable, Category = "Fab|AI")
    void GetAiTaskSimple(int32 TaskId);

    //---------------------------------------------------------
    // 内部 API（C++-only，接受 TFunction lambda；不走反射）
    // 供同模块的其他 C++ 组件（如 UFabUrlDispatcher）直接调用，
    // 避开 dynamic delegate 不支持 BindLambda 的限制。
    // 参数/返回语义和上面的 UFUNCTION 版本一致。
    //---------------------------------------------------------

    void ListAssetsEx(
        const FFabAssetQuery& Query,
        TFunction<void(const FFabError&, const FFabAssetListResult&)> OnComplete);

    void GetAssetEx(
        int32 AssetId,
        TFunction<void(const FFabError&, const FFabAssetItem&)> OnComplete);

    void DownloadAssetEx(
        int32 AssetId,
        TFunction<void(const FFabError&, const FFabDownloadResult&)> OnComplete);

    void UploadAssetEx(
        const FFabUploadRequest& Request,
        TFunction<void(const FFabError&, const FFabAssetItem&)> OnComplete);

    void UpdateAssetEx(
        int32 AssetId, const FFabAssetPatch& Patch,
        TFunction<void(const FFabError&, const FFabAssetItem&)> OnComplete);

    void DeleteAssetEx(
        int32 AssetId,
        TFunction<void(const FFabError&)> OnComplete);

    void CreateAiTextTaskEx(
        const FString& Prompt, const FString& Mode,
        TFunction<void(const FFabError&, const FFabAiTask&)> OnComplete);

    void CreateAiImageTaskEx(
        const FString& ImageUrl, const FString& Mode,
        TFunction<void(const FFabError&, const FFabAiTask&)> OnComplete);

    void ListAiTasksEx(
        int32 StatusFilter, int32 Page, int32 PageSize,
        TFunction<void(const FFabError&, const FFabAiTaskListResult&)> OnComplete);

    void GetAiTaskEx(
        int32 TaskId,
        TFunction<void(const FFabError&, const FFabAiTask&)> OnComplete);

    //---------------------------------------------------------
    // 静态 DTO 解析（public 是为了让匿名 namespace 里的辅助函数可见；
    // 这些方法不会修改任何实例状态，放外面当工具函数也行）
    //---------------------------------------------------------

    static void ParseUser(const TSharedPtr<class FJsonObject>& JObj, FFabUser& Out);
    static void ParseAsset(const TSharedPtr<class FJsonObject>& JObj, FFabAssetItem& Out);
    static void ParseAiTask(const TSharedPtr<class FJsonObject>& JObj, FFabAiTask& Out);

protected:
    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type Reason) override;

private:
    //---------------------------------------------------------
    // 内部：登录态 & token
    //---------------------------------------------------------

    FString AccessToken;
    FString RefreshToken;
    int64   AccessExpiresAtSec = 0;  // 来自 JWT payload.exp（0 表示未知）

    UPROPERTY()
    FFabUser CurrentUser;

    UPROPERTY()
    UFabConfig* CachedConfig = nullptr;

    /** 当前是否正在跑 refresh 请求（用于并发去重） */
    bool bRefreshInFlight = false;

    /** 等待 refresh 完成后重放的回调队列；bool 表示 refresh 是否成功 */
    TArray<TFunction<void(bool)>> RefreshWaiters;

    UFabConfig* GetConfig();

    /** 从 Saved/Fab/token.dat 恢复；失败则清空登录态 */
    void LoadTokenFromDisk();

    /** 更新内存 + 落盘 + 广播 OnAuthChanged */
    void ApplyAuthResult(const FFabAuthResult& Result);

    /** 清空内存 + 删除 token.dat + 广播（可选） */
    void ClearAuth(bool bBroadcastExpired);

    /** access_token 距过期多少秒（exp - now）；未知 token 返回 INT_MAX 视作"暂时可用" */
    int32 AccessTokenRemainingSec() const;

    /** 返回 true 表示立即用；false 表示已安排 refresh，请把自己塞进 RefreshWaiters */
    bool EnsureAccessTokenFresh(TFunction<void(bool /*ok*/)> OnReady);

    /** 内部：发起 refresh 请求 */
    void BeginRefresh();

    //---------------------------------------------------------
    // 内部：HTTP 基础
    //---------------------------------------------------------

    using FRawResponseHandler = TFunction<void(
        const FFabError& /*err*/,
        const TSharedPtr<class FJsonObject>& /*data*/
    )>;

    /** 发未鉴权请求（login/register/refresh 用），自动解信封 */
    void SendUnauthed(
        const FString& Verb,
        const FString& Path,
        const TSharedPtr<FJsonObject>& BodyJson,
        FRawResponseHandler OnDone);

    /** 发鉴权请求；内部先 EnsureAccessTokenFresh，再附 Bearer header */
    void SendAuthed(
        const FString& Verb,
        const FString& Path,
        const TSharedPtr<FJsonObject>& BodyJson,
        FRawResponseHandler OnDone);

    /** 直接给定 body bytes / content-type 发鉴权请求（上传 multipart 用） */
    void SendAuthedRaw(
        const FString& Verb,
        const FString& Path,
        const TArray<uint8>& Body,
        const FString& ContentType,
        float TimeoutSec,
        const FString& RequestId,       // 供 OnUploadProgress 携带
        FRawResponseHandler OnDone);

    /** 底层拼请求的共用代码 */
    TSharedRef<IHttpRequest> MakeRequest(
        const FString& Verb,
        const FString& Path,
        float TimeoutSec) const;

    /** 解析后端统一信封 {code, message, data} */
    void ParseEnvelope(
        int32 HttpCode,
        const FString& BodyStr,
        FFabError& OutErr,
        TSharedPtr<FJsonObject>& OutData) const;

};
