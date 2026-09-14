// FabUrlDispatcher.cpp

#include "FabUrlDispatcher.h"
#include "FabClientBridge.h"
#include "GenericPlatform/GenericPlatformHttp.h"

DEFINE_LOG_CATEGORY_STATIC(LogFabUrl, Log, All);

//=============================================================================
// 公共 API
//=============================================================================

bool UFabUrlDispatcher::IsFabScheme(const FString& Url)
{
    return Url.StartsWith(TEXT("uefab://"), ESearchCase::IgnoreCase);
}

bool UFabUrlDispatcher::Parse(const FString& SchemeUrl, FString& OutAction,
                              TMap<FString, FString>& OutParams)
{
    OutAction.Reset();
    OutParams.Reset();

    if (!IsFabScheme(SchemeUrl))
    {
        return false;
    }

    // 去掉 "uefab://" 前缀
    const FString Tail = SchemeUrl.Mid(FString(TEXT("uefab://")).Len());
    if (Tail.IsEmpty())
    {
        return false;
    }

    FString Query;
    if (!SplitActionAndQuery(Tail, OutAction, Query))
    {
        return false;
    }

    if (!Query.IsEmpty())
    {
        ParseQueryString(Query, OutParams);
    }
    return !OutAction.IsEmpty();
}

bool UFabUrlDispatcher::Dispatch(
    UFabClientBridge* Bridge,
    const FString& SchemeUrl,
    FFabError& OutError)
{
    OutError = FFabError::Ok();

    if (!IsFabScheme(SchemeUrl))
    {
        OutError.HttpCode = 0; OutError.BizCode = -1;
        OutError.Message = TEXT("not a uefab:// url");
        return false;
    }
    if (!Bridge)
    {
        OutError.HttpCode = 0; OutError.BizCode = -1;
        OutError.Message = TEXT("FabClientBridge 未绑定");
        return false;
    }

    FString Action;
    TMap<FString, FString> Params;
    if (!Parse(SchemeUrl, Action, Params))
    {
        OutError.HttpCode = 0; OutError.BizCode = -1;
        OutError.Message = TEXT("URL 格式错误");
        return false;
    }

    const FString ActionLower = Action.ToLower();
    if (ActionLower == TEXT("download") || ActionLower == TEXT("import"))
    {
        const FString* IdStrPtr = Params.Find(TEXT("id"));
        if (!IdStrPtr || IdStrPtr->IsEmpty())
        {
            OutError.HttpCode = 0; OutError.BizCode = -1;
            OutError.Message = TEXT("缺少 id 参数");
            return false;
        }
        const int32 AssetId = FCString::Atoi(**IdStrPtr);
        if (AssetId <= 0)
        {
            OutError.HttpCode = 0; OutError.BizCode = -1;
            OutError.Message = FString::Printf(TEXT("id 非法: %s"), **IdStrPtr);
            return false;
        }

        UE_LOG(LogFabUrl, Log, TEXT("dispatch %s id=%d (fire-and-forget)"), *ActionLower, AssetId);

        // 派发后结果走 Bridge->OnDownloadCompleted 多播；这里扔一个空 lambda
        Bridge->DownloadAssetEx(AssetId,
            [](const FFabError&, const FFabDownloadResult&) {});
        return true;
    }

    OutError.HttpCode = 0; OutError.BizCode = -1;
    OutError.Message = FString::Printf(TEXT("未知 action: %s"), *Action);
    UE_LOG(LogFabUrl, Warning, TEXT("unknown action '%s' in url %s"), *Action, *SchemeUrl);
    return false;
}

bool UFabUrlDispatcher::DispatchDownload(
    UFabClientBridge* Bridge,
    const FString& SchemeUrl,
    const FFabDownloadDelegate& OnComplete)
{
    // 1) 快速筛 scheme
    if (!IsFabScheme(SchemeUrl))
    {
        return false;
    }

    FFabDownloadDelegate CaptCb = OnComplete;

    auto FireErr = [CaptCb](int32 HttpCode, int32 BizCode, const FString& Msg)
    {
        FFabError E; E.HttpCode = HttpCode; E.BizCode = BizCode; E.Message = Msg;
        FFabDownloadResult EmptyResult;
        CaptCb.ExecuteIfBound(E, EmptyResult);
    };

    if (!Bridge)
    {
        UE_LOG(LogFabUrl, Warning, TEXT("Dispatch failed: bridge is null (url=%s)"), *SchemeUrl);
        FireErr(0, -1, TEXT("FabClientBridge 未绑定"));
        return true; // URL 已识别，只是内部失败
    }

    // 2) 解析
    FString Action;
    TMap<FString, FString> Params;
    if (!Parse(SchemeUrl, Action, Params))
    {
        UE_LOG(LogFabUrl, Warning, TEXT("Dispatch failed: bad scheme url=%s"), *SchemeUrl);
        FireErr(0, -1, TEXT("URL 格式错误"));
        return true;
    }

    const FString ActionLower = Action.ToLower();

    // 3) 分发
    if (ActionLower == TEXT("download") || ActionLower == TEXT("import"))
    {
        const FString* IdStrPtr = Params.Find(TEXT("id"));
        if (!IdStrPtr || IdStrPtr->IsEmpty())
        {
            FireErr(0, -1, TEXT("缺少 id 参数"));
            return true;
        }
        const int32 AssetId = FCString::Atoi(**IdStrPtr);
        if (AssetId <= 0)
        {
            FireErr(0, -1, FString::Printf(TEXT("id 非法: %s"), **IdStrPtr));
            return true;
        }

        UE_LOG(LogFabUrl, Log, TEXT("dispatch %s id=%d"), *ActionLower, AssetId);

        // 走 Ex 版本（TFunction lambda），完成后把结果回灌到 dynamic delegate 上
        Bridge->DownloadAssetEx(AssetId,
            [CaptCb](const FFabError& Err, const FFabDownloadResult& Result)
            {
                CaptCb.ExecuteIfBound(Err, Result);
            });
        return true;
    }

    // 未来：uefab://logout / uefab://open-ugc / ...
    UE_LOG(LogFabUrl, Warning, TEXT("unknown action '%s' in url %s"),
        *Action, *SchemeUrl);
    FireErr(0, -1, FString::Printf(TEXT("未知 action: %s"), *Action));
    return true;
}

//=============================================================================
// 内部：切片 + URL decode
//=============================================================================

bool UFabUrlDispatcher::SplitActionAndQuery(
    const FString& Tail, FString& OutAction, FString& OutQuery)
{
    // "download?id=123&foo=bar" 或纯 "logout"
    int32 QIdx = INDEX_NONE;
    if (Tail.FindChar(TEXT('?'), QIdx))
    {
        OutAction = Tail.Left(QIdx);
        OutQuery  = Tail.Mid(QIdx + 1);
    }
    else
    {
        OutAction = Tail;
        OutQuery.Reset();
    }

    // 兼容结尾带 '/'，例如 "download/?id=1"
    OutAction.RemoveFromEnd(TEXT("/"));
    return !OutAction.IsEmpty();
}

void UFabUrlDispatcher::ParseQueryString(
    const FString& Query, TMap<FString, FString>& OutParams)
{
    TArray<FString> Pairs;
    Query.ParseIntoArray(Pairs, TEXT("&"), /*bCullEmpty*/true);

    for (const FString& P : Pairs)
    {
        FString K, V;
        if (P.Split(TEXT("="), &K, &V))
        {
            OutParams.Add(UrlDecode(K), UrlDecode(V));
        }
        else
        {
            OutParams.Add(UrlDecode(P), FString());
        }
    }
}

FString UFabUrlDispatcher::UrlDecode(const FString& In)
{
    // FGenericPlatformHttp::UrlDecode 足够用
    return FGenericPlatformHttp::UrlDecode(In);
}
