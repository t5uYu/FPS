// Copyright Epic Games, Inc. All Rights Reserved.

#include "FabClientBridge.h"

#include "FabConfig.h"
#include "FabTokenStore.h"

#include "HttpModule.h"
#include "Interfaces/IHttpResponse.h"
#include "GenericPlatform/GenericPlatformHttp.h"
#include "Dom/JsonObject.h"
#include "Dom/JsonValue.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"
#include "Misc/Guid.h"
#include "Misc/Paths.h"
#include "Misc/FileHelper.h"
#include "Misc/DateTime.h"
#include "HAL/FileManager.h"

DEFINE_LOG_CATEGORY_STATIC(LogFabClient, Log, All);

#define FAB_LOGV(Fmt, ...) do { if (CachedConfig && CachedConfig->bVerboseLog) { UE_LOG(LogFabClient, Log, Fmt, ##__VA_ARGS__); } } while(0)

//=============================================================================
// 小工具
//=============================================================================

namespace
{
    int64 NowUnixSec() { return FDateTime::UtcNow().ToUnixTimestamp(); }

    int64 IsoToUnixSec(const FString& Iso)
    {
        if (Iso.IsEmpty()) return 0;
        FDateTime Dt;
        if (FDateTime::ParseIso8601(*Iso, Dt))
        {
            return Dt.ToUnixTimestamp();
        }
        return 0;
    }

    EFabAssetType ParseAssetType(const FString& S)
    {
        if (S == TEXT("model")) return EFabAssetType::Model;
        if (S == TEXT("map"))   return EFabAssetType::Map;
        return EFabAssetType::Unknown;
    }
    FString AssetTypeToStr(EFabAssetType T)
    {
        switch (T)
        {
        case EFabAssetType::Model: return TEXT("model");
        case EFabAssetType::Map:   return TEXT("map");
        default:                   return FString();
        }
    }
    EFabAssetStatus ParseAssetStatus(int32 N)
    {
        switch (N)
        {
        case 0: return EFabAssetStatus::LegacyPending;
        case 1: return EFabAssetStatus::LegacyPackaging;
        case 2: return EFabAssetStatus::Online;
        case 3: return EFabAssetStatus::Rejected;
        default: return EFabAssetStatus::Unknown;
        }
    }
    EFabAiTaskStatus ParseAiStatus(int32 N)
    {
        switch (N)
        {
        case 0: return EFabAiTaskStatus::Pending;
        case 1: return EFabAiTaskStatus::Processing;
        case 2: return EFabAiTaskStatus::Succeeded;
        case 3: return EFabAiTaskStatus::Failed;
        default: return EFabAiTaskStatus::Unknown;
        }
    }
    EFabAiTaskKind ParseAiKind(const FString& S)
    {
        if (S == TEXT("text_to_model"))  return EFabAiTaskKind::Text;
        if (S == TEXT("image_to_model")) return EFabAiTaskKind::Image;
        return EFabAiTaskKind::Unknown;
    }

    FString JsonObjectToString(const TSharedRef<FJsonObject>& JObj)
    {
        FString Out;
        const TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Out);
        FJsonSerializer::Serialize(JObj, Writer);
        return Out;
    }

    /** 拼 application/x-www-form-urlencoded key=value（简单字符转义） */
    FString UrlEncode(const FString& In)
    {
        return FGenericPlatformHttp::UrlEncode(In);
    }

    /** 把 JSON 数组转 TArray<FString>，静默丢掉非字符串元素 */
    TArray<FString> JsonArrayToStringArray(const TArray<TSharedPtr<FJsonValue>>& Arr)
    {
        TArray<FString> Out;
        Out.Reserve(Arr.Num());
        for (const TSharedPtr<FJsonValue>& V : Arr)
        {
            FString S;
            if (V.IsValid() && V->TryGetString(S))
            {
                Out.Add(MoveTemp(S));
            }
        }
        return Out;
    }

    TArray<FString> SplitCsvTags(const FString& TagsCsv)
    {
        TArray<FString> Out;
        TArray<FString> Parts;
        TagsCsv.ParseIntoArray(Parts, TEXT(","), true);
        for (FString Part : Parts)
        {
            Part.TrimStartAndEndInline();
            if (!Part.IsEmpty())
            {
                Out.Add(MoveTemp(Part));
            }
        }
        return Out;
    }

    bool IsFabOk(const FFabError& Err)
    {
        return Err.BizCode == 0 && (Err.HttpCode == 0 || (Err.HttpCode >= 200 && Err.HttpCode < 300));
    }
}

//=============================================================================
// 生命周期
//=============================================================================

UFabClientBridge::UFabClientBridge()
{
    PrimaryComponentTick.bCanEverTick = false;
}

void UFabClientBridge::BeginPlay()
{
    Super::BeginPlay();
    GetConfig();              // 预载配置
    LoadTokenFromDisk();
    UE_LOG(LogFabClient, Log, TEXT("FabClientBridge ready, base_url=%s, logged_in=%s"),
        *CachedConfig->BaseUrl, IsLoggedIn() ? TEXT("yes") : TEXT("no"));
}

void UFabClientBridge::EndPlay(const EEndPlayReason::Type Reason)
{
    RefreshWaiters.Empty();
    Super::EndPlay(Reason);
}

UFabConfig* UFabClientBridge::GetConfig()
{
    if (!CachedConfig)
    {
        CachedConfig = UFabConfig::Get();
    }
    return CachedConfig;
}

//=============================================================================
// 登录态 & token
//=============================================================================

void UFabClientBridge::LoadTokenFromDisk()
{
    FFabTokenRecord R;
    if (!UFabTokenStore::Load(R))
    {
        return;
    }
    if (R.AccessToken.IsEmpty() || R.RefreshToken.IsEmpty())
    {
        return;
    }

    AccessToken = R.AccessToken;
    RefreshToken = R.RefreshToken;
    AccessExpiresAtSec = R.AccessExpiresAtSec;
    if (AccessExpiresAtSec == 0)
    {
        AccessExpiresAtSec = UFabTokenStore::ExtractJwtExpSec(AccessToken);
    }
    CurrentUser = R.User;

    UE_LOG(LogFabClient, Log, TEXT("restored auth: user_id=%d account=%s remaining=%ds"),
        CurrentUser.Id, *CurrentUser.UserAccount, AccessTokenRemainingSec());

    OnAuthChanged.Broadcast(CurrentUser);
}

void UFabClientBridge::ApplyAuthResult(const FFabAuthResult& Result)
{
    AccessToken = Result.AccessToken;
    if (!Result.RefreshToken.IsEmpty())
    {
        RefreshToken = Result.RefreshToken;
    }
    AccessExpiresAtSec = UFabTokenStore::ExtractJwtExpSec(AccessToken);
    CurrentUser = Result.User;

    FFabTokenRecord R;
    R.AccessToken = AccessToken;
    R.RefreshToken = RefreshToken;
    R.AccessIssuedAtSec = NowUnixSec();
    R.AccessExpiresAtSec = AccessExpiresAtSec;
    R.User = CurrentUser;
    UFabTokenStore::Save(R);

    OnAuthChanged.Broadcast(CurrentUser);
}

void UFabClientBridge::ClearAuth(bool bBroadcastExpired)
{
    AccessToken.Empty();
    RefreshToken.Empty();
    AccessExpiresAtSec = 0;
    CurrentUser = FFabUser{};
    UFabTokenStore::Clear();

    OnAuthChanged.Broadcast(CurrentUser);
    if (bBroadcastExpired)
    {
        OnAuthExpired.Broadcast();
    }
}

bool UFabClientBridge::IsLoggedIn() const
{
    return !AccessToken.IsEmpty() && !RefreshToken.IsEmpty();
}

int32 UFabClientBridge::AccessTokenRemainingSec() const
{
    if (AccessToken.IsEmpty()) return 0;
    if (AccessExpiresAtSec <= 0) return MAX_int32;
    const int64 Rem = AccessExpiresAtSec - NowUnixSec();
    return Rem > (int64)MAX_int32 ? MAX_int32 : (int32)Rem;
}

bool UFabClientBridge::EnsureAccessTokenFresh(TFunction<void(bool)> OnReady)
{
    if (!IsLoggedIn())
    {
        if (OnReady) OnReady(false);
        return true;
    }

    const int32 Leeway = GetConfig() ? GetConfig()->TokenRefreshLeewaySec : 60;
    if (AccessTokenRemainingSec() > Leeway)
    {
        if (OnReady) OnReady(true);
        return true;
    }

    RefreshWaiters.Add(MoveTemp(OnReady));
    if (!bRefreshInFlight)
    {
        BeginRefresh();
    }
    return false;
}

void UFabClientBridge::BeginRefresh()
{
    if (RefreshToken.IsEmpty())
    {
        // 没有 refresh_token，直接失败
        TArray<TFunction<void(bool)>> Waiters = MoveTemp(RefreshWaiters);
        RefreshWaiters.Reset();
        bRefreshInFlight = false;
        for (auto& W : Waiters) { if (W) W(false); }
        ClearAuth(/*expired*/true);
        return;
    }

    bRefreshInFlight = true;

    TSharedPtr<FJsonObject> Body = MakeShared<FJsonObject>();
    Body->SetStringField(TEXT("refresh_token"), RefreshToken);

    SendUnauthed(TEXT("POST"), TEXT("/api/v1/auth/refresh"), Body,
        [this](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            TArray<TFunction<void(bool)>> Waiters = MoveTemp(RefreshWaiters);
            RefreshWaiters.Reset();
            bRefreshInFlight = false;

            if (!Err.IsOk() || !Data.IsValid())
            {
                UE_LOG(LogFabClient, Warning, TEXT("refresh failed: http=%d biz=%d %s"),
                    Err.HttpCode, Err.BizCode, *Err.Message);
                ClearAuth(/*expired*/true);
                for (auto& W : Waiters) { if (W) W(false); }
                return;
            }

            FString NewAccess;
            Data->TryGetStringField(TEXT("access_token"), NewAccess);
            if (NewAccess.IsEmpty())
            {
                ClearAuth(/*expired*/true);
                for (auto& W : Waiters) { if (W) W(false); }
                return;
            }

            AccessToken = NewAccess;
            AccessExpiresAtSec = UFabTokenStore::ExtractJwtExpSec(AccessToken);

            FFabTokenRecord R;
            R.AccessToken = AccessToken;
            R.RefreshToken = RefreshToken;
            R.AccessIssuedAtSec = NowUnixSec();
            R.AccessExpiresAtSec = AccessExpiresAtSec;
            R.User = CurrentUser;
            UFabTokenStore::Save(R);

            UE_LOG(LogFabClient, Log, TEXT("refreshed access token, remaining=%ds"),
                AccessTokenRemainingSec());

            for (auto& W : Waiters) { if (W) W(true); }
        });
}

//=============================================================================
// HTTP 基础
//=============================================================================

TSharedRef<IHttpRequest> UFabClientBridge::MakeRequest(const FString& Verb,
                                                      const FString& Path,
                                                      float TimeoutSec) const
{
    const TSharedRef<IHttpRequest> Req = FHttpModule::Get().CreateRequest();
    const FString Url = CachedConfig
        ? CachedConfig->Url(Path)
        : (TEXT("https://fab-cloud.cn") + (Path.StartsWith(TEXT("/")) ? Path : TEXT("/") + Path));
    Req->SetURL(Url);
    Req->SetVerb(Verb);
    Req->SetTimeout(TimeoutSec);
    Req->SetHeader(TEXT("Accept"), TEXT("application/json"));
    return Req;
}

void UFabClientBridge::ParseEnvelope(int32 HttpCode,
                                     const FString& BodyStr,
                                     FFabError& OutErr,
                                     TSharedPtr<FJsonObject>& OutData) const
{
    OutErr = FFabError{};
    OutErr.HttpCode = HttpCode;
    OutData.Reset();

    if (BodyStr.IsEmpty())
    {
        OutErr.BizCode = -1;
        OutErr.Message = FString::Printf(TEXT("empty body (http=%d)"), HttpCode);
        return;
    }

    TSharedPtr<FJsonObject> Root;
    const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(BodyStr);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid())
    {
        OutErr.BizCode = -1;
        OutErr.Message = FString::Printf(TEXT("invalid json (http=%d, body_len=%d)"),
                                         HttpCode, BodyStr.Len());
        return;
    }

    double CodeNum = 0.0;
    int32 CodeInt = 0;
    if (Root->TryGetNumberField(TEXT("code"), CodeInt)) { OutErr.BizCode = CodeInt; }
    else if (Root->TryGetNumberField(TEXT("code"), CodeNum)) { OutErr.BizCode = (int32)CodeNum; }

    Root->TryGetStringField(TEXT("message"), OutErr.Message);

    const TSharedPtr<FJsonObject>* DataObj = nullptr;
    if (Root->TryGetObjectField(TEXT("data"), DataObj) && DataObj && (*DataObj).IsValid())
    {
        OutData = *DataObj;
    }
}

void UFabClientBridge::SendUnauthed(const FString& Verb,
                                    const FString& Path,
                                    const TSharedPtr<FJsonObject>& BodyJson,
                                    FRawResponseHandler OnDone)
{
    const float Timeout = GetConfig() ? GetConfig()->RequestTimeoutSec : 30.f;
    const TSharedRef<IHttpRequest> Req = MakeRequest(Verb, Path, Timeout);

    if (BodyJson.IsValid())
    {
        Req->SetHeader(TEXT("Content-Type"), TEXT("application/json"));
        Req->SetContentAsString(JsonObjectToString(BodyJson.ToSharedRef()));
    }

    TWeakObjectPtr<UFabClientBridge> WeakSelf(this);
    Req->OnProcessRequestComplete().BindLambda(
        [WeakSelf, OnDone](FHttpRequestPtr Request, FHttpResponsePtr Response, bool bOk)
        {
            UFabClientBridge* Self = WeakSelf.Get();
            if (!Self)
            {
                return;
            }

            if (!bOk || !Response.IsValid())
            {
                FFabError Err = FFabError::Network(TEXT("network error or timeout"));
                if (OnDone) OnDone(Err, nullptr);
                return;
            }

            FFabError Err;
            TSharedPtr<FJsonObject> Data;
            Self->ParseEnvelope(Response->GetResponseCode(), Response->GetContentAsString(), Err, Data);
            if (OnDone) OnDone(Err, Data);
        });

    Req->ProcessRequest();
}

void UFabClientBridge::SendAuthed(const FString& Verb,
                                  const FString& Path,
                                  const TSharedPtr<FJsonObject>& BodyJson,
                                  FRawResponseHandler OnDone)
{
    TWeakObjectPtr<UFabClientBridge> WeakSelf(this);
    const FString CaptVerb = Verb;
    const FString CaptPath = Path;
    TSharedPtr<FJsonObject> CaptBody = BodyJson;

    auto Perform = [WeakSelf, CaptVerb, CaptPath, CaptBody, OnDone](bool bAuthOk)
    {
        UFabClientBridge* Self = WeakSelf.Get();
        if (!Self) return;

        if (!bAuthOk)
        {
            FFabError Err; Err.HttpCode = 401; Err.BizCode = 2003;
            Err.Message = TEXT("未登录或 token 已过期");
            Self->OnGlobalError.Broadcast(Err);
            if (OnDone) OnDone(Err, nullptr);
            return;
        }

        const float Timeout = Self->GetConfig() ? Self->GetConfig()->RequestTimeoutSec : 30.f;
        const TSharedRef<IHttpRequest> Req = Self->MakeRequest(CaptVerb, CaptPath, Timeout);
        Req->SetHeader(TEXT("Authorization"), FString::Printf(TEXT("Bearer %s"), *Self->AccessToken));

        if (CaptBody.IsValid())
        {
            Req->SetHeader(TEXT("Content-Type"), TEXT("application/json"));
            Req->SetContentAsString(JsonObjectToString(CaptBody.ToSharedRef()));
        }

        Req->OnProcessRequestComplete().BindLambda(
            [WeakSelf, OnDone](FHttpRequestPtr Request, FHttpResponsePtr Response, bool bOk)
            {
                UFabClientBridge* S = WeakSelf.Get();
                if (!S) return;

                if (!bOk || !Response.IsValid())
                {
                    FFabError Err = FFabError::Network(TEXT("network error or timeout"));
                    if (OnDone) OnDone(Err, nullptr);
                    return;
                }

                FFabError Err;
                TSharedPtr<FJsonObject> Data;
                S->ParseEnvelope(Response->GetResponseCode(), Response->GetContentAsString(), Err, Data);
                if (OnDone) OnDone(Err, Data);
            });

        Req->ProcessRequest();
    };

    EnsureAccessTokenFresh(MoveTemp(Perform));
}

void UFabClientBridge::SendAuthedRaw(const FString& Verb,
                                     const FString& Path,
                                     const TArray<uint8>& Body,
                                     const FString& ContentType,
                                     float TimeoutSec,
                                     const FString& RequestId,
                                     FRawResponseHandler OnDone)
{
    TWeakObjectPtr<UFabClientBridge> WeakSelf(this);
    const FString CaptVerb = Verb;
    const FString CaptPath = Path;
    const FString CaptCT = ContentType;
    const FString CaptReqId = RequestId;
    const TArray<uint8> CaptBody = Body; // 拷贝到 lambda 生命周期

    auto Perform = [WeakSelf, CaptVerb, CaptPath, CaptCT, CaptReqId, CaptBody, TimeoutSec, OnDone](bool bAuthOk)
    {
        UFabClientBridge* Self = WeakSelf.Get();
        if (!Self) return;

        if (!bAuthOk)
        {
            FFabError Err; Err.HttpCode = 401; Err.BizCode = 2003;
            Err.Message = TEXT("未登录或 token 已过期");
            Self->OnGlobalError.Broadcast(Err);
            if (OnDone) OnDone(Err, nullptr);
            return;
        }

        const TSharedRef<IHttpRequest> Req = Self->MakeRequest(CaptVerb, CaptPath, TimeoutSec);
        Req->SetHeader(TEXT("Authorization"), FString::Printf(TEXT("Bearer %s"), *Self->AccessToken));
        Req->SetHeader(TEXT("Content-Type"), CaptCT);
        Req->SetContent(CaptBody);

        const int32 TotalBytes = CaptBody.Num();
        TWeakObjectPtr<UFabClientBridge> InnerWeak(Self);

        Req->OnRequestProgress64().BindLambda(
            [InnerWeak, CaptReqId, TotalBytes](FHttpRequestPtr, uint64 BytesSent, uint64 /*BytesReceived*/)
            {
                UFabClientBridge* S = InnerWeak.Get();
                if (!S) return;
                S->OnUploadProgress.Broadcast(CaptReqId, (int32)BytesSent, TotalBytes, CaptReqId);
            });

        Req->OnProcessRequestComplete().BindLambda(
            [WeakSelf, OnDone](FHttpRequestPtr Request, FHttpResponsePtr Response, bool bOk)
            {
                UFabClientBridge* S = WeakSelf.Get();
                if (!S) return;

                if (!bOk || !Response.IsValid())
                {
                    FFabError Err = FFabError::Network(TEXT("network error or timeout"));
                    if (OnDone) OnDone(Err, nullptr);
                    return;
                }

                FFabError Err;
                TSharedPtr<FJsonObject> Data;
                S->ParseEnvelope(Response->GetResponseCode(), Response->GetContentAsString(), Err, Data);
                if (OnDone) OnDone(Err, Data);
            });

        Req->ProcessRequest();
    };

    EnsureAccessTokenFresh(MoveTemp(Perform));
}

//=============================================================================
// DTO 解析
//=============================================================================

void UFabClientBridge::ParseUser(const TSharedPtr<FJsonObject>& J, FFabUser& Out)
{
    if (!J.IsValid()) return;
    int32 IntTmp = 0; double DblTmp = 0.0; FString StrTmp;

    if (J->TryGetNumberField(TEXT("id"), IntTmp))      { Out.Id = IntTmp; }
    else if (J->TryGetNumberField(TEXT("id"), DblTmp)) { Out.Id = (int32)DblTmp; }

    J->TryGetStringField(TEXT("user_account"), Out.UserAccount);
    J->TryGetStringField(TEXT("user_name"), Out.UserName);

    if (J->TryGetStringField(TEXT("user_role"), StrTmp))
    {
        Out.UserRole = (StrTmp == TEXT("admin")) ? EFabUserRole::Admin : EFabUserRole::Player;
    }

    if (J->TryGetNumberField(TEXT("ai_quota"), IntTmp))      { Out.AiQuota = IntTmp; }
    else if (J->TryGetNumberField(TEXT("ai_quota"), DblTmp)) { Out.AiQuota = (int32)DblTmp; }

    if (J->TryGetNumberField(TEXT("ai_used"), IntTmp))       { Out.AiUsed = IntTmp; }
    else if (J->TryGetNumberField(TEXT("ai_used"), DblTmp))  { Out.AiUsed = (int32)DblTmp; }

    J->TryGetStringField(TEXT("user_avatar"), Out.AvatarUrl);
    if (Out.AvatarUrl.IsEmpty())
    {
        J->TryGetStringField(TEXT("avatar_url"), Out.AvatarUrl);
    }
}

void UFabClientBridge::ParseAsset(const TSharedPtr<FJsonObject>& J, FFabAssetItem& Out)
{
    if (!J.IsValid()) return;
    int32 IntTmp = 0; double DblTmp = 0.0; FString StrTmp;

    if (J->TryGetNumberField(TEXT("id"), IntTmp))      { Out.Id = IntTmp; }
    else if (J->TryGetNumberField(TEXT("id"), DblTmp)) { Out.Id = (int32)DblTmp; }

    J->TryGetStringField(TEXT("name"), Out.Name);
    J->TryGetStringField(TEXT("description"), Out.Description);

    if (J->TryGetStringField(TEXT("asset_type"), StrTmp))
    {
        Out.AssetType = ParseAssetType(StrTmp);
    }

    int32 StatusInt = -1;
    if (J->TryGetNumberField(TEXT("status"), StatusInt))
    {
        Out.Status = ParseAssetStatus(StatusInt);
    }
    else if (J->TryGetNumberField(TEXT("status"), DblTmp))
    {
        Out.Status = ParseAssetStatus((int32)DblTmp);
    }

    const TArray<TSharedPtr<FJsonValue>>* TagsArr = nullptr;
    if (J->TryGetArrayField(TEXT("tags"), TagsArr) && TagsArr)
    {
        Out.Tags = JsonArrayToStringArray(*TagsArr);
    }

    J->TryGetStringField(TEXT("thumbnail_url"), Out.ThumbnailUrl);

    if (J->TryGetNumberField(TEXT("user_id"), IntTmp))      { Out.UserId = IntTmp; }
    else if (J->TryGetNumberField(TEXT("user_id"), DblTmp)) { Out.UserId = (int32)DblTmp; }

    J->TryGetStringField(TEXT("user_name"), Out.UserName);

    if (J->TryGetNumberField(TEXT("size_bytes"), IntTmp))      { Out.SizeBytes = IntTmp; }
    else if (J->TryGetNumberField(TEXT("size_bytes"), DblTmp)) { Out.SizeBytes = (int32)DblTmp; }

    J->TryGetStringField(TEXT("source_note"), Out.SourceNote);

    if (J->TryGetStringField(TEXT("create_time"), StrTmp))
    {
        Out.CreatedAtSeconds = IsoToUnixSec(StrTmp);
    }
    if (J->TryGetStringField(TEXT("update_time"), StrTmp))
    {
        Out.UpdatedAtSeconds = IsoToUnixSec(StrTmp);
    }
}

void UFabClientBridge::ParseAiTask(const TSharedPtr<FJsonObject>& J, FFabAiTask& Out)
{
    if (!J.IsValid()) return;
    int32 IntTmp = 0; double DblTmp = 0.0; FString StrTmp;

    if (J->TryGetNumberField(TEXT("id"), IntTmp))      { Out.Id = IntTmp; }
    else if (J->TryGetNumberField(TEXT("id"), DblTmp)) { Out.Id = (int32)DblTmp; }

    if (J->TryGetStringField(TEXT("task_type"), StrTmp))
    {
        Out.Kind = ParseAiKind(StrTmp);
    }

    int32 StatusInt = -1;
    if (J->TryGetNumberField(TEXT("status"), StatusInt))
    {
        Out.Status = ParseAiStatus(StatusInt);
    }
    else if (J->TryGetNumberField(TEXT("status"), DblTmp))
    {
        Out.Status = ParseAiStatus((int32)DblTmp);
    }

    if (J->TryGetNumberField(TEXT("progress"), IntTmp))      { Out.Progress = IntTmp; }
    else if (J->TryGetNumberField(TEXT("progress"), DblTmp)) { Out.Progress = (int32)DblTmp; }

    J->TryGetStringField(TEXT("input_text"), Out.InputText);
    J->TryGetStringField(TEXT("input_image_url"), Out.InputImageUrl);
    J->TryGetStringField(TEXT("output_model_url"), Out.OutputModelUrl);
    J->TryGetStringField(TEXT("task_id"), Out.RemoteTaskId);
    J->TryGetStringField(TEXT("error_message"), Out.ErrorMessage);

    if (J->TryGetStringField(TEXT("create_time"), StrTmp))
    {
        Out.CreatedAtSeconds = IsoToUnixSec(StrTmp);
    }
    if (J->TryGetStringField(TEXT("finish_time"), StrTmp))
    {
        Out.FinishAtSeconds = IsoToUnixSec(StrTmp);
    }
}

//=============================================================================
// 鉴权端点
//=============================================================================

namespace
{
    /** 从 /auth/login 或 /auth/register 返回的 data JSON 里解出 FFabAuthResult */
    bool ParseAuthResult(const TSharedPtr<FJsonObject>& Data, FFabAuthResult& Out)
    {
        if (!Data.IsValid()) return false;
        Data->TryGetStringField(TEXT("access_token"),  Out.AccessToken);
        Data->TryGetStringField(TEXT("refresh_token"), Out.RefreshToken);

        const TSharedPtr<FJsonObject>* UserObj = nullptr;
        if (Data->TryGetObjectField(TEXT("user"), UserObj) && UserObj && (*UserObj).IsValid())
        {
            UFabClientBridge::ParseUser(*UserObj, Out.User);
        }
        Out.AccessExpiresInSec = 0; // 客户端会通过 ExtractJwtExpSec 自己算
        return !Out.AccessToken.IsEmpty();
    }
}

void UFabClientBridge::Login(const FString& Account, const FString& Password,
                             const FFabAuthDelegate& OnComplete)
{
    TSharedPtr<FJsonObject> Body = MakeShared<FJsonObject>();
    Body->SetStringField(TEXT("user_account"), Account);
    Body->SetStringField(TEXT("user_password"), Password);

    TWeakObjectPtr<UFabClientBridge> WeakSelf(this);
    FFabAuthDelegate CaptCb = OnComplete;

    SendUnauthed(TEXT("POST"), TEXT("/api/v1/auth/login"), Body,
        [WeakSelf, CaptCb](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            UFabClientBridge* Self = WeakSelf.Get();
            if (!Self) return;

            FFabAuthResult Result;
            if (!Err.IsOk() || !ParseAuthResult(Data, Result))
            {
                Self->OnLoginCompleted.Broadcast(Err, Result);
                CaptCb.ExecuteIfBound(Err, Result);
                return;
            }
            Self->ApplyAuthResult(Result);
            Self->OnLoginCompleted.Broadcast(FFabError::Ok(), Result);
            CaptCb.ExecuteIfBound(FFabError::Ok(), Result);
        });
}

void UFabClientBridge::Register(const FString& Account, const FString& Password,
                                const FString& UserName, const FFabAuthDelegate& OnComplete)
{
    TSharedPtr<FJsonObject> Body = MakeShared<FJsonObject>();
    Body->SetStringField(TEXT("user_account"), Account);
    Body->SetStringField(TEXT("user_password"), Password);
    if (!UserName.IsEmpty())
    {
        Body->SetStringField(TEXT("user_name"), UserName);
    }

    TWeakObjectPtr<UFabClientBridge> WeakSelf(this);
    FFabAuthDelegate CaptCb = OnComplete;

    SendUnauthed(TEXT("POST"), TEXT("/api/v1/auth/register"), Body,
        [WeakSelf, CaptCb](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            UFabClientBridge* Self = WeakSelf.Get();
            if (!Self) return;

            FFabAuthResult Result;
            if (!Err.IsOk() || !ParseAuthResult(Data, Result))
            {
                Self->OnRegisterCompleted.Broadcast(Err, Result);
                CaptCb.ExecuteIfBound(Err, Result);
                return;
            }
            Self->ApplyAuthResult(Result);
            Self->OnRegisterCompleted.Broadcast(FFabError::Ok(), Result);
            CaptCb.ExecuteIfBound(FFabError::Ok(), Result);
        });
}

void UFabClientBridge::LoginSimple(const FString& Account, const FString& Password)
{
    FFabAuthDelegate Empty;
    Login(Account, Password, Empty);
}

void UFabClientBridge::RegisterSimple(const FString& Account, const FString& Password,
                                      const FString& UserName)
{
    FFabAuthDelegate Empty;
    Register(Account, Password, UserName, Empty);
}

void UFabClientBridge::Logout()
{
    ClearAuth(/*expired*/false);
}

//=============================================================================
// 资产端点：Ex（TFunction 版本，承载真正实现） + UFUNCTION 薄转发
//=============================================================================

void UFabClientBridge::ListAssetsEx(
    const FFabAssetQuery& Query,
    TFunction<void(const FFabError&, const FFabAssetListResult&)> OnComplete)
{
    FString QS;
    QS += FString::Printf(TEXT("?page=%d&page_size=%d"),
        Query.Page < 1 ? 1 : Query.Page,
        Query.PageSize < 1 ? 20 : Query.PageSize);
    if (Query.AssetType != EFabAssetType::Unknown)
    {
        QS += TEXT("&asset_type=") + AssetTypeToStr(Query.AssetType);
    }
    if (!Query.Keyword.IsEmpty())
    {
        QS += TEXT("&keyword=") + UrlEncode(Query.Keyword);
    }
    if (Query.bOnlyMine)
    {
        QS += TEXT("&only_mine=true");
    }

    SendAuthed(TEXT("GET"), TEXT("/api/v1/assets") + QS, nullptr,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            FFabAssetListResult Result;
            if (!Err.IsOk() || !Data.IsValid())
            {
                if (OnComplete) OnComplete(Err, Result);
                return;
            }

            int32 IntTmp = 0; double DblTmp = 0.0;
            if (Data->TryGetNumberField(TEXT("total"),     IntTmp)) { Result.Total    = IntTmp; }
            else if (Data->TryGetNumberField(TEXT("total"), DblTmp)) { Result.Total    = (int32)DblTmp; }
            if (Data->TryGetNumberField(TEXT("page"),      IntTmp)) { Result.Page     = IntTmp; }
            else if (Data->TryGetNumberField(TEXT("page"),  DblTmp)) { Result.Page     = (int32)DblTmp; }
            if (Data->TryGetNumberField(TEXT("page_size"), IntTmp)) { Result.PageSize = IntTmp; }
            else if (Data->TryGetNumberField(TEXT("page_size"), DblTmp)) { Result.PageSize = (int32)DblTmp; }

            const TArray<TSharedPtr<FJsonValue>>* ItemsArr = nullptr;
            if (Data->TryGetArrayField(TEXT("items"), ItemsArr) && ItemsArr)
            {
                Result.Items.Reserve(ItemsArr->Num());
                for (const TSharedPtr<FJsonValue>& V : *ItemsArr)
                {
                    const TSharedPtr<FJsonObject>* Obj = nullptr;
                    if (V.IsValid() && V->TryGetObject(Obj) && Obj && (*Obj).IsValid())
                    {
                        FFabAssetItem Item;
                        ParseAsset(*Obj, Item);
                        Result.Items.Add(MoveTemp(Item));
                    }
                }
            }
            if (OnComplete) OnComplete(FFabError::Ok(), Result);
        });
}

void UFabClientBridge::ListAssets(const FFabAssetQuery& Query,
                                  const FFabAssetListDelegate& OnComplete)
{
    FFabAssetListDelegate CaptCb = OnComplete;
    ListAssetsEx(Query,
        [CaptCb](const FFabError& Err, const FFabAssetListResult& Result)
        {
            CaptCb.ExecuteIfBound(Err, Result);
        });
}

void UFabClientBridge::GetAssetEx(
    int32 AssetId,
    TFunction<void(const FFabError&, const FFabAssetItem&)> OnComplete)
{
    const FString Path = FString::Printf(TEXT("/api/v1/assets/%d"), AssetId);
    SendAuthed(TEXT("GET"), Path, nullptr,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            FFabAssetItem Item;
            if (!Err.IsOk() || !Data.IsValid())
            {
                if (OnComplete) OnComplete(Err, Item);
                return;
            }
            ParseAsset(Data, Item);
            if (OnComplete) OnComplete(FFabError::Ok(), Item);
        });
}

void UFabClientBridge::GetAsset(int32 AssetId, const FFabAssetItemDelegate& OnComplete)
{
    FFabAssetItemDelegate CaptCb = OnComplete;
    GetAssetEx(AssetId,
        [CaptCb](const FFabError& Err, const FFabAssetItem& Item)
        {
            CaptCb.ExecuteIfBound(Err, Item);
        });
}

void UFabClientBridge::DownloadAssetEx(
    int32 AssetId,
    TFunction<void(const FFabError&, const FFabDownloadResult&)> OnComplete)
{
    const FString Endpoint = FString::Printf(TEXT("/api/v1/assets/%d/download"), AssetId);
    TWeakObjectPtr<UFabClientBridge> WeakSelf(this);

    SendAuthed(TEXT("GET"), Endpoint, nullptr,
        [WeakSelf, AssetId, OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            UFabClientBridge* Self = WeakSelf.Get();
            FFabDownloadResult Result;
            Result.AssetId = AssetId;

            if (!Self)
            {
                return;
            }
            if (!Err.IsOk() || !Data.IsValid())
            {
                Self->OnDownloadCompleted.Broadcast(AssetId, Err, Result);
                if (OnComplete) OnComplete(Err, Result);
                return;
            }

            FString PresignedUrl;
            Data->TryGetStringField(TEXT("url"), PresignedUrl);
            if (PresignedUrl.IsEmpty())
            {
                FFabError E; E.HttpCode = 200; E.BizCode = -1;
                E.Message = TEXT("download url empty");
                Self->OnDownloadCompleted.Broadcast(AssetId, E, Result);
                if (OnComplete) OnComplete(E, Result);
                return;
            }

            FString Ext = TEXT("glb");
            {
                FString UrlNoQuery = PresignedUrl;
                int32 QIdx = INDEX_NONE;
                if (UrlNoQuery.FindChar(TEXT('?'), QIdx))
                {
                    UrlNoQuery = UrlNoQuery.Left(QIdx);
                }
                const FString LowerU = UrlNoQuery.ToLower();
                if (LowerU.EndsWith(TEXT(".zip"))) { Ext = TEXT("zip"); }
                else if (LowerU.EndsWith(TEXT(".glb"))) { Ext = TEXT("glb"); }
            }

            const FString LocalUuid = FGuid::NewGuid().ToString(EGuidFormats::DigitsWithHyphensLower);
            const FString TargetDir = FPaths::Combine(
                FPaths::ProjectSavedDir(), TEXT("AnimAgent"), TEXT("assets"), LocalUuid);
            const FString TargetPath = FPaths::Combine(TargetDir, FString::Printf(TEXT("source.%s"), *Ext));
            IFileManager::Get().MakeDirectory(*TargetDir, /*Tree*/true);

            Result.LocalUuid = LocalUuid;
            Result.LocalFilePath = TargetPath;

            const float Timeout = Self->GetConfig() ? Self->GetConfig()->DownloadTimeoutSec : 300.f;
            const TSharedRef<IHttpRequest> DlReq = FHttpModule::Get().CreateRequest();
            DlReq->SetURL(PresignedUrl);
            DlReq->SetVerb(TEXT("GET"));
            DlReq->SetTimeout(Timeout);

            TWeakObjectPtr<UFabClientBridge> InnerWeak(Self);
            DlReq->OnRequestProgress64().BindLambda(
                [InnerWeak, AssetId, TargetPath](FHttpRequestPtr, uint64 /*Sent*/, uint64 Received)
                {
                    UFabClientBridge* S = InnerWeak.Get();
                    if (!S) return;
                    S->OnDownloadProgress.Broadcast(AssetId, (int32)Received, 0, TargetPath);
                });

            DlReq->OnProcessRequestComplete().BindLambda(
                [WeakSelf, Result, OnComplete, TargetPath, AssetId](
                    FHttpRequestPtr, FHttpResponsePtr Response, bool bOk) mutable
                {
                    UFabClientBridge* S = WeakSelf.Get();
                    if (!S) return;

                    if (!bOk || !Response.IsValid())
                    {
                        FFabError E = FFabError::Network(TEXT("download network error"));
                        S->OnDownloadCompleted.Broadcast(AssetId, E, Result);
                        if (OnComplete) OnComplete(E, Result);
                        return;
                    }
                    const int32 Code = Response->GetResponseCode();
                    if (Code < 200 || Code >= 300)
                    {
                        FFabError E; E.HttpCode = Code; E.BizCode = -1;
                        E.Message = FString::Printf(TEXT("download http=%d"), Code);
                        S->OnDownloadCompleted.Broadcast(AssetId, E, Result);
                        if (OnComplete) OnComplete(E, Result);
                        return;
                    }

                    const TArray<uint8>& Bytes = Response->GetContent();
                    if (!FFileHelper::SaveArrayToFile(Bytes, *TargetPath))
                    {
                        FFabError E; E.HttpCode = 0; E.BizCode = -1;
                        E.Message = FString::Printf(TEXT("save file failed: %s"), *TargetPath);
                        S->OnDownloadCompleted.Broadcast(AssetId, E, Result);
                        if (OnComplete) OnComplete(E, Result);
                        return;
                    }
                    Result.SizeBytes = Bytes.Num();
                    S->OnDownloadProgress.Broadcast(AssetId, Bytes.Num(), Bytes.Num(), TargetPath);

                    UE_LOG(LogFabClient, Log, TEXT("asset %d downloaded -> %s (%d bytes)"),
                        AssetId, *TargetPath, Bytes.Num());

                    S->OnDownloadCompleted.Broadcast(AssetId, FFabError::Ok(), Result);
                    if (OnComplete) OnComplete(FFabError::Ok(), Result);
                });

            DlReq->ProcessRequest();
        });
}

void UFabClientBridge::DownloadAsset(int32 AssetId, const FFabDownloadDelegate& OnComplete)
{
    FFabDownloadDelegate CaptCb = OnComplete;
    DownloadAssetEx(AssetId,
        [CaptCb](const FFabError& Err, const FFabDownloadResult& Result)
        {
            CaptCb.ExecuteIfBound(Err, Result);
        });
}

void UFabClientBridge::UploadAssetEx(
    const FFabUploadRequest& Request,
    TFunction<void(const FFabError&, const FFabAssetItem&)> OnComplete)
{
    if (Request.LocalFilePath.IsEmpty() || !FPaths::FileExists(Request.LocalFilePath))
    {
        FFabError E; E.HttpCode = 0; E.BizCode = 3003;
        E.Message = TEXT("本地文件不存在");
        if (OnComplete) OnComplete(E, FFabAssetItem{});
        return;
    }
    if (Request.Name.IsEmpty())
    {
        FFabError E; E.HttpCode = 0; E.BizCode = 1001;
        E.Message = TEXT("name 为空");
        if (OnComplete) OnComplete(E, FFabAssetItem{});
        return;
    }

    TArray<uint8> FileBytes;
    if (!FFileHelper::LoadFileToArray(FileBytes, *Request.LocalFilePath))
    {
        FFabError E; E.HttpCode = 0; E.BizCode = 1001;
        E.Message = TEXT("读取本地文件失败");
        if (OnComplete) OnComplete(E, FFabAssetItem{});
        return;
    }

    const FString TypeStr = AssetTypeToStr(Request.AssetType);
    if (TypeStr.IsEmpty())
    {
        FFabError E; E.HttpCode = 0; E.BizCode = 3008;
        E.Message = TEXT("asset_type 非法");
        if (OnComplete) OnComplete(E, FFabAssetItem{});
        return;
    }

    const FString Boundary = FString::Printf(TEXT("----UEFabClientBoundary%s"),
        *FGuid::NewGuid().ToString(EGuidFormats::Short));
    const FString ContentType = FString::Printf(TEXT("multipart/form-data; boundary=%s"), *Boundary);

    auto AppendStr = [](TArray<uint8>& Buf, const FString& S)
    {
        const FTCHARToUTF8 Conv(*S);
        Buf.Append(reinterpret_cast<const uint8*>(Conv.Get()), Conv.Length());
    };
    auto AppendField = [&](TArray<uint8>& Buf, const FString& Field, const FString& Value)
    {
        AppendStr(Buf, FString::Printf(TEXT("--%s\r\n"), *Boundary));
        AppendStr(Buf, FString::Printf(
            TEXT("Content-Disposition: form-data; name=\"%s\"\r\n\r\n"), *Field));
        AppendStr(Buf, Value);
        AppendStr(Buf, TEXT("\r\n"));
    };

    TArray<uint8> Body;
    Body.Reserve(FileBytes.Num() + 1024);

    AppendField(Body, TEXT("name"),       Request.Name);
    AppendField(Body, TEXT("asset_type"), TypeStr);
    if (!Request.Description.IsEmpty())
    {
        AppendField(Body, TEXT("description"), Request.Description);
    }
    if (Request.Tags.Num() > 0)
    {
        AppendField(Body, TEXT("tags"), FString::Join(Request.Tags, TEXT(",")));
    }

    const FString FileName = FPaths::GetCleanFilename(Request.LocalFilePath);
    const FString FileContentType = FileName.EndsWith(TEXT(".zip"))
        ? TEXT("application/zip")
        : TEXT("model/gltf-binary");

    AppendStr(Body, FString::Printf(TEXT("--%s\r\n"), *Boundary));
    AppendStr(Body, FString::Printf(
        TEXT("Content-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"), *FileName));
    AppendStr(Body, FString::Printf(TEXT("Content-Type: %s\r\n\r\n"), *FileContentType));
    Body.Append(FileBytes);
    AppendStr(Body, TEXT("\r\n"));

    AppendStr(Body, FString::Printf(TEXT("--%s--\r\n"), *Boundary));

    const float Timeout = GetConfig() ? GetConfig()->UploadTimeoutSec : 300.f;

    SendAuthedRaw(TEXT("POST"), TEXT("/api/v1/assets"),
                  Body, ContentType, Timeout, Request.LocalFilePath,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            FFabAssetItem Item;
            if (!Err.IsOk() || !Data.IsValid())
            {
                if (OnComplete) OnComplete(Err, Item);
                return;
            }
            ParseAsset(Data, Item);
            if (OnComplete) OnComplete(FFabError::Ok(), Item);
        });
}

void UFabClientBridge::UploadAsset(const FFabUploadRequest& Request,
                                   const FFabAssetItemDelegate& OnComplete)
{
    FFabAssetItemDelegate CaptCb = OnComplete;
    UploadAssetEx(Request,
        [CaptCb](const FFabError& Err, const FFabAssetItem& Item)
        {
            CaptCb.ExecuteIfBound(Err, Item);
        });
}

void UFabClientBridge::UploadModelSimple(const FString& Name,
                                         const FString& LocalFilePath,
                                         const FString& Description,
                                         const FString& TagsCsv)
{
    FFabUploadRequest Request;
    Request.Name = Name;
    Request.AssetType = EFabAssetType::Model;
    Request.LocalFilePath = LocalFilePath;
    Request.Description = Description;
    Request.Tags = SplitCsvTags(TagsCsv);

    UploadAssetEx(Request,
        [this](const FFabError& Err, const FFabAssetItem& Item)
        {
            if (IsFabOk(Err))
            {
                UE_LOG(LogFabClient, Log, TEXT("upload completed: asset_id=%d name=%s"),
                    Item.Id, *Item.Name);
            }
            else
            {
                UE_LOG(LogFabClient, Warning, TEXT("upload failed: http=%d biz=%d %s"),
                    Err.HttpCode, Err.BizCode, *Err.Message);
            }
            OnUploadCompleted.Broadcast(Err, Item);
        });
}

void UFabClientBridge::UpdateAssetEx(
    int32 AssetId, const FFabAssetPatch& Patch,
    TFunction<void(const FFabError&, const FFabAssetItem&)> OnComplete)
{
    TSharedPtr<FJsonObject> Body = MakeShared<FJsonObject>();
    if (Patch.bSetName)        { Body->SetStringField(TEXT("name"), Patch.Name); }
    if (Patch.bSetDescription) { Body->SetStringField(TEXT("description"), Patch.Description); }
    if (Patch.bSetTags)
    {
        TArray<TSharedPtr<FJsonValue>> Arr;
        for (const FString& T : Patch.Tags) { Arr.Add(MakeShared<FJsonValueString>(T)); }
        Body->SetArrayField(TEXT("tags"), Arr);
    }

    const FString Path = FString::Printf(TEXT("/api/v1/assets/%d"), AssetId);
    SendAuthed(TEXT("PATCH"), Path, Body,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            FFabAssetItem Item;
            if (!Err.IsOk() || !Data.IsValid())
            {
                if (OnComplete) OnComplete(Err, Item);
                return;
            }
            ParseAsset(Data, Item);
            if (OnComplete) OnComplete(FFabError::Ok(), Item);
        });
}

void UFabClientBridge::UpdateAsset(int32 AssetId, const FFabAssetPatch& Patch,
                                   const FFabAssetItemDelegate& OnComplete)
{
    FFabAssetItemDelegate CaptCb = OnComplete;
    UpdateAssetEx(AssetId, Patch,
        [CaptCb](const FFabError& Err, const FFabAssetItem& Item)
        {
            CaptCb.ExecuteIfBound(Err, Item);
        });
}

void UFabClientBridge::DeleteAssetEx(
    int32 AssetId,
    TFunction<void(const FFabError&)> OnComplete)
{
    const FString Path = FString::Printf(TEXT("/api/v1/assets/%d"), AssetId);
    SendAuthed(TEXT("DELETE"), Path, nullptr,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& /*Data*/)
        {
            if (OnComplete) OnComplete(Err);
        });
}

void UFabClientBridge::DeleteAsset(int32 AssetId, const FFabSimpleDelegate& OnComplete)
{
    FFabSimpleDelegate CaptCb = OnComplete;
    DeleteAssetEx(AssetId,
        [CaptCb](const FFabError& Err)
        {
            CaptCb.ExecuteIfBound(Err);
        });
}

//=============================================================================
// AI 端点
//=============================================================================

void UFabClientBridge::CreateAiTextTaskEx(
    const FString& Prompt, const FString& Mode,
    TFunction<void(const FFabError&, const FFabAiTask&)> OnComplete)
{
    TSharedPtr<FJsonObject> Body = MakeShared<FJsonObject>();
    Body->SetStringField(TEXT("input_text"), Prompt);
    if (!Mode.IsEmpty())
    {
        Body->SetStringField(TEXT("mode"), Mode);
    }

    SendAuthed(TEXT("POST"), TEXT("/api/v1/ai/text-to-model"), Body,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            FFabAiTask T;
            if (!Err.IsOk() || !Data.IsValid())
            {
                if (OnComplete) OnComplete(Err, T);
                return;
            }
            ParseAiTask(Data, T);
            if (OnComplete) OnComplete(FFabError::Ok(), T);
        });
}

void UFabClientBridge::CreateAiTextTask(const FString& Prompt, const FString& Mode,
                                        const FFabAiTaskDelegate& OnComplete)
{
    FFabAiTaskDelegate CaptCb = OnComplete;
    CreateAiTextTaskEx(Prompt, Mode,
        [CaptCb](const FFabError& Err, const FFabAiTask& T)
        {
            CaptCb.ExecuteIfBound(Err, T);
        });
}

void UFabClientBridge::CreateAiTextTaskSimple(const FString& Prompt, const FString& Mode)
{
    CreateAiTextTaskEx(Prompt, Mode,
        [this](const FFabError& Err, const FFabAiTask& Task)
        {
            if (IsFabOk(Err))
            {
                UE_LOG(LogFabClient, Log, TEXT("ai text task created: task_id=%d status=%d progress=%d"),
                    Task.Id, (int32)Task.Status, Task.Progress);
            }
            else
            {
                UE_LOG(LogFabClient, Warning, TEXT("ai text task failed: http=%d biz=%d %s"),
                    Err.HttpCode, Err.BizCode, *Err.Message);
            }
            OnAiTaskCompleted.Broadcast(Err, Task);
        });
}

void UFabClientBridge::CreateAiImageTaskEx(
    const FString& ImageUrl, const FString& Mode,
    TFunction<void(const FFabError&, const FFabAiTask&)> OnComplete)
{
    TSharedPtr<FJsonObject> Body = MakeShared<FJsonObject>();
    Body->SetStringField(TEXT("input_image_url"), ImageUrl);
    if (!Mode.IsEmpty())
    {
        Body->SetStringField(TEXT("mode"), Mode);
    }

    SendAuthed(TEXT("POST"), TEXT("/api/v1/ai/image-to-model"), Body,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            FFabAiTask T;
            if (!Err.IsOk() || !Data.IsValid())
            {
                if (OnComplete) OnComplete(Err, T);
                return;
            }
            ParseAiTask(Data, T);
            if (OnComplete) OnComplete(FFabError::Ok(), T);
        });
}

void UFabClientBridge::CreateAiImageTask(const FString& ImageUrl, const FString& Mode,
                                         const FFabAiTaskDelegate& OnComplete)
{
    FFabAiTaskDelegate CaptCb = OnComplete;
    CreateAiImageTaskEx(ImageUrl, Mode,
        [CaptCb](const FFabError& Err, const FFabAiTask& T)
        {
            CaptCb.ExecuteIfBound(Err, T);
        });
}

void UFabClientBridge::CreateAiImageTaskSimple(const FString& ImageUrl, const FString& Mode)
{
    CreateAiImageTaskEx(ImageUrl, Mode,
        [this](const FFabError& Err, const FFabAiTask& Task)
        {
            if (IsFabOk(Err))
            {
                UE_LOG(LogFabClient, Log, TEXT("ai image task created: task_id=%d status=%d progress=%d"),
                    Task.Id, (int32)Task.Status, Task.Progress);
            }
            else
            {
                UE_LOG(LogFabClient, Warning, TEXT("ai image task failed: http=%d biz=%d %s"),
                    Err.HttpCode, Err.BizCode, *Err.Message);
            }
            OnAiTaskCompleted.Broadcast(Err, Task);
        });
}

void UFabClientBridge::ListAiTasksEx(
    int32 StatusFilter, int32 Page, int32 PageSize,
    TFunction<void(const FFabError&, const FFabAiTaskListResult&)> OnComplete)
{
    FString QS = FString::Printf(TEXT("?page=%d&page_size=%d"),
        Page < 1 ? 1 : Page,
        PageSize < 1 ? 20 : PageSize);
    if (StatusFilter >= 0 && StatusFilter <= 3)
    {
        QS += FString::Printf(TEXT("&status=%d"), StatusFilter);
    }

    SendAuthed(TEXT("GET"), TEXT("/api/v1/ai/tasks") + QS, nullptr,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            FFabAiTaskListResult Result;
            if (!Err.IsOk() || !Data.IsValid())
            {
                if (OnComplete) OnComplete(Err, Result);
                return;
            }

            int32 IntTmp = 0; double DblTmp = 0.0;
            if (Data->TryGetNumberField(TEXT("total"),     IntTmp)) { Result.Total    = IntTmp; }
            else if (Data->TryGetNumberField(TEXT("total"), DblTmp)) { Result.Total    = (int32)DblTmp; }
            if (Data->TryGetNumberField(TEXT("page"),      IntTmp)) { Result.Page     = IntTmp; }
            else if (Data->TryGetNumberField(TEXT("page"),  DblTmp)) { Result.Page     = (int32)DblTmp; }
            if (Data->TryGetNumberField(TEXT("page_size"), IntTmp)) { Result.PageSize = IntTmp; }
            else if (Data->TryGetNumberField(TEXT("page_size"), DblTmp)) { Result.PageSize = (int32)DblTmp; }

            const TArray<TSharedPtr<FJsonValue>>* ItemsArr = nullptr;
            if (Data->TryGetArrayField(TEXT("items"), ItemsArr) && ItemsArr)
            {
                Result.Items.Reserve(ItemsArr->Num());
                for (const TSharedPtr<FJsonValue>& V : *ItemsArr)
                {
                    const TSharedPtr<FJsonObject>* Obj = nullptr;
                    if (V.IsValid() && V->TryGetObject(Obj) && Obj && (*Obj).IsValid())
                    {
                        FFabAiTask T;
                        ParseAiTask(*Obj, T);
                        Result.Items.Add(MoveTemp(T));
                    }
                }
            }
            if (OnComplete) OnComplete(FFabError::Ok(), Result);
        });
}

void UFabClientBridge::ListAiTasks(int32 StatusFilter, int32 Page, int32 PageSize,
                                   const FFabAiTaskListDelegate& OnComplete)
{
    FFabAiTaskListDelegate CaptCb = OnComplete;
    ListAiTasksEx(StatusFilter, Page, PageSize,
        [CaptCb](const FFabError& Err, const FFabAiTaskListResult& Result)
        {
            CaptCb.ExecuteIfBound(Err, Result);
        });
}

void UFabClientBridge::GetAiTaskEx(
    int32 TaskId,
    TFunction<void(const FFabError&, const FFabAiTask&)> OnComplete)
{
    const FString Path = FString::Printf(TEXT("/api/v1/ai/tasks/%d"), TaskId);
    SendAuthed(TEXT("GET"), Path, nullptr,
        [OnComplete](const FFabError& Err, const TSharedPtr<FJsonObject>& Data)
        {
            FFabAiTask T;
            if (!Err.IsOk() || !Data.IsValid())
            {
                if (OnComplete) OnComplete(Err, T);
                return;
            }
            ParseAiTask(Data, T);
            if (OnComplete) OnComplete(FFabError::Ok(), T);
        });
}

void UFabClientBridge::GetAiTask(int32 TaskId, const FFabAiTaskDelegate& OnComplete)
{
    FFabAiTaskDelegate CaptCb = OnComplete;
    GetAiTaskEx(TaskId,
        [CaptCb](const FFabError& Err, const FFabAiTask& T)
        {
            CaptCb.ExecuteIfBound(Err, T);
        });
}

void UFabClientBridge::GetAiTaskSimple(int32 TaskId)
{
    GetAiTaskEx(TaskId,
        [this](const FFabError& Err, const FFabAiTask& Task)
        {
            if (IsFabOk(Err))
            {
                UE_LOG(LogFabClient, Log, TEXT("ai task: task_id=%d status=%d progress=%d asset_id=%d error=%s"),
                    Task.Id, (int32)Task.Status, Task.Progress, Task.AssetId, *Task.ErrorMessage);
            }
            else
            {
                UE_LOG(LogFabClient, Warning, TEXT("get ai task failed: http=%d biz=%d %s"),
                    Err.HttpCode, Err.BizCode, *Err.Message);
            }
            OnAiTaskCompleted.Broadcast(Err, Task);
        });
}
