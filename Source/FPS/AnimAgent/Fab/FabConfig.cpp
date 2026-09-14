// Copyright Epic Games, Inc. All Rights Reserved.

#include "FabConfig.h"

#include "Misc/Paths.h"
#include "Misc/FileHelper.h"
#include "HAL/FileManager.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"

DEFINE_LOG_CATEGORY_STATIC(LogFabConfig, Log, All);

TWeakObjectPtr<UFabConfig> UFabConfig::GCached;

UFabConfig::UFabConfig()
    : BaseUrl(TEXT("http://111.229.172.143:8765"))
{
}

FString UFabConfig::GetConfigFilePath()
{
    return FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("Fab"), TEXT("config.json"));
}

UFabConfig* UFabConfig::Get()
{
    if (GCached.IsValid())
    {
        return GCached.Get();
    }
    return Reload();
}

UFabConfig* UFabConfig::Reload()
{
    UFabConfig* Cfg = NewObject<UFabConfig>(GetTransientPackage(), UFabConfig::StaticClass());
    Cfg->AddToRoot();  // 跨 GC 保活；进程结束释放
    GCached = Cfg;

    const FString Path = GetConfigFilePath();
    FString Raw;
    if (FFileHelper::LoadFileToString(Raw, *Path))
    {
        Cfg->LoadFromJsonString(Raw);
        UE_LOG(LogFabConfig, Log, TEXT("loaded config from %s, base_url=%s"), *Path, *Cfg->BaseUrl);
    }
    else
    {
        const FString Dir = FPaths::GetPath(Path);
        IFileManager::Get().MakeDirectory(*Dir, /*Tree*/true);
        const FString DefaultJson = Cfg->ToJsonString();
        FFileHelper::SaveStringToFile(DefaultJson, *Path, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
        UE_LOG(LogFabConfig, Log, TEXT("config.json not found, wrote defaults to %s"), *Path);
    }

    return Cfg;
}

FString UFabConfig::Url(const FString& RelativePath) const
{
    FString Base = BaseUrl;
    while (Base.EndsWith(TEXT("/")))
    {
        Base.LeftChopInline(1);
    }

    FString Rel = RelativePath;
    if (!Rel.StartsWith(TEXT("/")))
    {
        Rel = TEXT("/") + Rel;
    }
    return Base + Rel;
}

void UFabConfig::LoadFromJsonString(const FString& Json)
{
    TSharedPtr<FJsonObject> Root;
    const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Json);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid())
    {
        UE_LOG(LogFabConfig, Warning, TEXT("config.json parse failed, keeping defaults"));
        return;
    }

    FString StrTmp;
    double  NumTmp = 0.0;
    bool    BoolTmp = false;
    int32   IntTmp = 0;

    if (Root->TryGetStringField(TEXT("base_url"), StrTmp) && !StrTmp.IsEmpty())
    {
        BaseUrl = StrTmp;
    }
    if (Root->TryGetNumberField(TEXT("request_timeout_sec"),    NumTmp)) { RequestTimeoutSec    = (float)NumTmp; }
    if (Root->TryGetNumberField(TEXT("download_timeout_sec"),   NumTmp)) { DownloadTimeoutSec   = (float)NumTmp; }
    if (Root->TryGetNumberField(TEXT("upload_timeout_sec"),     NumTmp)) { UploadTimeoutSec     = (float)NumTmp; }
    if (Root->TryGetNumberField(TEXT("ai_poll_interval_sec"),   NumTmp)) { AiPollIntervalSec    = (float)NumTmp; }
    if (Root->TryGetNumberField(TEXT("ai_poll_max_interval_sec"),NumTmp)) { AiPollMaxIntervalSec = (float)NumTmp; }
    if (Root->TryGetNumberField(TEXT("token_refresh_leeway_sec"), IntTmp))
    {
        TokenRefreshLeewaySec = IntTmp;
    }
    else if (Root->TryGetNumberField(TEXT("token_refresh_leeway_sec"), NumTmp))
    {
        TokenRefreshLeewaySec = (int32)NumTmp;
    }
    if (Root->TryGetBoolField(TEXT("verbose_log"), BoolTmp))
    {
        bVerboseLog = BoolTmp;
    }
}

FString UFabConfig::ToJsonString() const
{
    TSharedRef<FJsonObject> Root = MakeShared<FJsonObject>();
    Root->SetStringField(TEXT("base_url"), BaseUrl);
    Root->SetNumberField(TEXT("request_timeout_sec"),     RequestTimeoutSec);
    Root->SetNumberField(TEXT("download_timeout_sec"),    DownloadTimeoutSec);
    Root->SetNumberField(TEXT("upload_timeout_sec"),      UploadTimeoutSec);
    Root->SetNumberField(TEXT("ai_poll_interval_sec"),    AiPollIntervalSec);
    Root->SetNumberField(TEXT("ai_poll_max_interval_sec"),AiPollMaxIntervalSec);
    Root->SetNumberField(TEXT("token_refresh_leeway_sec"),TokenRefreshLeewaySec);
    Root->SetBoolField(TEXT("verbose_log"), bVerboseLog);

    FString Out;
    const TSharedRef<TJsonWriter<TCHAR, TPrettyJsonPrintPolicy<TCHAR>>> Writer =
        TJsonWriterFactory<TCHAR, TPrettyJsonPrintPolicy<TCHAR>>::Create(&Out);
    FJsonSerializer::Serialize(Root, Writer);
    return Out;
}
