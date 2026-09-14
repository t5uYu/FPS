// FabUrlDispatcher.h
//
// 解析 uefab:// scheme URL 并派发到 UFabClientBridge。
//
// 用途：WBP_FabPanel 内嵌的 UWebBrowser 在 `OnUrlChanged` 触发时，先调
// `UFabUrlDispatcher::IsFabScheme` 判断，命中则调 `DispatchDownload`（或未来的
// DispatchImport 等）走 C++ 下载链，然后把 WebBrowser 回退到上一个有效 URL。
//
// 当前 MVP 支持的 action：
//   uefab://download?id=123      → Bridge::DownloadAssetEx
//
// 预留未来扩展：
//   uefab://logout               → Bridge::Logout
//   uefab://open-ugc             → 通过 BP 委托跳转 UGC 编辑器
//

#pragma once

#include "CoreMinimal.h"
#include "UObject/NoExportTypes.h"
#include "FabTypes.h"
#include "FabUrlDispatcher.generated.h"

class UFabClientBridge;

UCLASS()
class FPS_API UFabUrlDispatcher : public UObject
{
    GENERATED_BODY()

public:
    /** 快速判断 URL 是不是 uefab:// scheme（不关心 action / params） */
    UFUNCTION(BlueprintCallable, BlueprintPure, Category = "Fab|Url")
    static bool IsFabScheme(const FString& Url);

    /**
     * 解析 uefab://{action}?{k}={v}&... 到 (Action, Params)。
     * @param SchemeUrl  完整 URL
     * @param OutAction  如 "download"、"import"、"logout"
     * @param OutParams  query 参数键值对（key/value 均已 URL-decode）
     * @return true 表示 URL 是合法的 uefab scheme
     */
    UFUNCTION(BlueprintCallable, BlueprintPure, Category = "Fab|Url")
    static bool Parse(const FString& SchemeUrl, FString& OutAction,
                      TMap<FString, FString>& OutParams);

    /**
     * 统一入口（推荐）：解析 URL，命中 download 类 action 即调 Bridge 下载。
     * 不接受一次性回调 — 调用方请订阅 Bridge->OnDownloadCompleted 多播（Lua/UMG 友好）
     * 以及 Bridge->OnDownloadProgress 看进度；action 解析失败时通过返回值和 OutError 反馈。
     *
     * @param Bridge      已登录的 UFabClientBridge；nullptr 视作错误
     * @param SchemeUrl   uefab://... URL
     * @param OutError    本地解析 / 参数校验失败时填错误；HTTP 层错误走多播不走这里
     * @return true  URL 已被识别并派发（不代表下载成功；等多播结果）
     *         false URL 不是 uefab scheme 或参数非法，OutError 带说明，**多播不会触发**
     *
     * Action 目前支持：
     *   download / import   → 下载资产到 Saved/AnimAgent/assets/{uuid}/source.glb
     */
    UFUNCTION(BlueprintCallable, Category = "Fab|Url")
    static bool Dispatch(
        UFabClientBridge* Bridge,
        const FString& SchemeUrl,
        FFabError& OutError);

    /**
     * 带一次性 BP 动态委托的派发入口（给纯 BP 项目用）。
     * Lua 侧优先用 `Dispatch` + 订阅 Bridge 多播，这个函数仅为 BP 便利保留。
     */
    UFUNCTION(BlueprintCallable, Category = "Fab|Url")
    static bool DispatchDownload(
        UFabClientBridge* Bridge,
        const FString& SchemeUrl,
        const FFabDownloadDelegate& OnComplete);

private:
    /**
     * 从 "uefab://download?id=123&foo=bar" 里的 `download?id=...` 拆成 action + query
     * 不处理 scheme 前缀；调用方需自己 strip "uefab://"
     */
    static bool SplitActionAndQuery(const FString& Tail, FString& OutAction, FString& OutQuery);

    /** 解析 "k=v&k2=v2" 到 TMap；值做 URL-decode */
    static void ParseQueryString(const FString& Query, TMap<FString, FString>& OutParams);

    static FString UrlDecode(const FString& In);
};
