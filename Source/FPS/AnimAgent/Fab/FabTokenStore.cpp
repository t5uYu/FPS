// Copyright Epic Games, Inc. All Rights Reserved.

#include "FabTokenStore.h"

#include "Misc/Paths.h"
#include "Misc/FileHelper.h"
#include "Misc/Base64.h"
#include "Misc/DateTime.h"
#include "HAL/FileManager.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"

DEFINE_LOG_CATEGORY_STATIC(LogFabTokenStore, Log, All);

namespace
{
    // 简易 XOR 混淆；仅阻止"双击文本编辑器直接读到 JWT"，不是加密
    constexpr uint8 kXorKey[] = {
        0x5A, 0x7C, 0x11, 0xA3, 0xB4, 0xEE, 0x02, 0x9D,
        0x45, 0x61, 0x7B, 0xCD, 0x38, 0x72, 0xF1, 0x08
    };
    constexpr int32 kXorKeyLen = sizeof(kXorKey);

    void XorInPlace(TArray<uint8>& Bytes)
    {
        for (int32 i = 0; i < Bytes.Num(); ++i)
        {
            Bytes[i] ^= kXorKey[i % kXorKeyLen];
        }
    }

    FString SerializeToJson(const FFabTokenRecord& R)
    {
        TSharedRef<FJsonObject> Root = MakeShared<FJsonObject>();
        Root->SetStringField(TEXT("access_token"),  R.AccessToken);
        Root->SetStringField(TEXT("refresh_token"), R.RefreshToken);
        Root->SetNumberField(TEXT("access_issued_at"),  (double)R.AccessIssuedAtSec);
        Root->SetNumberField(TEXT("access_expires_at"), (double)R.AccessExpiresAtSec);
        Root->SetNumberField(TEXT("saved_at"),          (double)R.SavedAtSec);

        TSharedRef<FJsonObject> U = MakeShared<FJsonObject>();
        U->SetNumberField(TEXT("id"), R.User.Id);
        U->SetStringField(TEXT("user_account"), R.User.UserAccount);
        U->SetStringField(TEXT("user_name"),    R.User.UserName);
        U->SetStringField(TEXT("user_role"),
            R.User.UserRole == EFabUserRole::Admin ? TEXT("admin") : TEXT("player"));
        U->SetNumberField(TEXT("ai_quota"), R.User.AiQuota);
        U->SetNumberField(TEXT("ai_used"),  R.User.AiUsed);
        U->SetStringField(TEXT("avatar_url"), R.User.AvatarUrl);
        Root->SetObjectField(TEXT("user"), U);

        FString Out;
        const TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Out);
        FJsonSerializer::Serialize(Root, Writer);
        return Out;
    }

    bool DeserializeFromJson(const FString& Json, FFabTokenRecord& Out)
    {
        TSharedPtr<FJsonObject> Root;
        const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Json);
        if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid())
        {
            return false;
        }

        Out.AccessToken  = Root->GetStringField(TEXT("access_token"));
        Out.RefreshToken = Root->GetStringField(TEXT("refresh_token"));

        double NumTmp = 0.0;
        if (Root->TryGetNumberField(TEXT("access_issued_at"),  NumTmp)) { Out.AccessIssuedAtSec  = (int64)NumTmp; }
        if (Root->TryGetNumberField(TEXT("access_expires_at"), NumTmp)) { Out.AccessExpiresAtSec = (int64)NumTmp; }
        if (Root->TryGetNumberField(TEXT("saved_at"),          NumTmp)) { Out.SavedAtSec         = (int64)NumTmp; }

        const TSharedPtr<FJsonObject>* U = nullptr;
        if (Root->TryGetObjectField(TEXT("user"), U) && U && (*U).IsValid())
        {
            const TSharedPtr<FJsonObject>& UO = *U;
            int32 IntTmp = 0;
            double DblTmp = 0.0;
            FString StrTmp;

            if (UO->TryGetNumberField(TEXT("id"), IntTmp))     { Out.User.Id = IntTmp; }
            else if (UO->TryGetNumberField(TEXT("id"), DblTmp)){ Out.User.Id = (int32)DblTmp; }

            UO->TryGetStringField(TEXT("user_account"), Out.User.UserAccount);
            UO->TryGetStringField(TEXT("user_name"),    Out.User.UserName);

            if (UO->TryGetStringField(TEXT("user_role"), StrTmp))
            {
                Out.User.UserRole = (StrTmp == TEXT("admin")) ? EFabUserRole::Admin : EFabUserRole::Player;
            }
            if (UO->TryGetNumberField(TEXT("ai_quota"), IntTmp))     { Out.User.AiQuota = IntTmp; }
            else if (UO->TryGetNumberField(TEXT("ai_quota"), DblTmp)){ Out.User.AiQuota = (int32)DblTmp; }

            if (UO->TryGetNumberField(TEXT("ai_used"), IntTmp))     { Out.User.AiUsed = IntTmp; }
            else if (UO->TryGetNumberField(TEXT("ai_used"), DblTmp)){ Out.User.AiUsed = (int32)DblTmp; }

            UO->TryGetStringField(TEXT("avatar_url"), Out.User.AvatarUrl);
        }

        return !Out.AccessToken.IsEmpty();
    }

    /** 把 JWT 的 base64url payload 段还原出来（不解码 header / signature） */
    FString Base64UrlToBase64(FString In)
    {
        In.ReplaceInline(TEXT("-"), TEXT("+"));
        In.ReplaceInline(TEXT("_"), TEXT("/"));
        // 补齐 padding
        const int32 Rem = In.Len() % 4;
        if (Rem != 0)
        {
            In.Append(FString::ChrN(4 - Rem, TCHAR('=')));
        }
        return In;
    }
}

FString UFabTokenStore::GetTokenFilePath()
{
    return FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("Fab"), TEXT("token.dat"));
}

bool UFabTokenStore::Load(FFabTokenRecord& OutRecord)
{
    const FString Path = GetTokenFilePath();
    TArray<uint8> Raw;
    if (!FFileHelper::LoadFileToArray(Raw, *Path))
    {
        return false;
    }
    if (Raw.Num() == 0)
    {
        return false;
    }

    // base64 → bytes → XOR → JSON
    FString B64;
    if (!FFileHelper::LoadFileToString(B64, *Path))
    {
        return false;
    }

    TArray<uint8> Decoded;
    if (!FBase64::Decode(B64, Decoded) || Decoded.Num() == 0)
    {
        UE_LOG(LogFabTokenStore, Warning, TEXT("token.dat base64 decode failed, ignoring"));
        return false;
    }

    XorInPlace(Decoded);

    // JSON UTF-8 → FString
    FUTF8ToTCHAR Conv(reinterpret_cast<const ANSICHAR*>(Decoded.GetData()), Decoded.Num());
    const FString Json(Conv.Length(), Conv.Get());

    if (!DeserializeFromJson(Json, OutRecord))
    {
        UE_LOG(LogFabTokenStore, Warning, TEXT("token.dat json deserialize failed, ignoring"));
        return false;
    }
    return true;
}

bool UFabTokenStore::Save(const FFabTokenRecord& Record)
{
    FFabTokenRecord R = Record;
    R.SavedAtSec = FDateTime::UtcNow().ToUnixTimestamp();

    const FString Json = SerializeToJson(R);
    const FTCHARToUTF8 Conv(*Json);
    TArray<uint8> Bytes;
    Bytes.Append(reinterpret_cast<const uint8*>(Conv.Get()), Conv.Length());

    XorInPlace(Bytes);
    const FString B64 = FBase64::Encode(Bytes);

    const FString Path = GetTokenFilePath();
    const FString Dir  = FPaths::GetPath(Path);
    IFileManager::Get().MakeDirectory(*Dir, /*Tree*/true);

    if (!FFileHelper::SaveStringToFile(B64, *Path, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM))
    {
        UE_LOG(LogFabTokenStore, Error, TEXT("failed to write token.dat: %s"), *Path);
        return false;
    }
    return true;
}

bool UFabTokenStore::Clear()
{
    const FString Path = GetTokenFilePath();
    if (!FPaths::FileExists(Path))
    {
        return true;
    }
    return IFileManager::Get().Delete(*Path, /*RequireExists*/false, /*EvenReadOnly*/true);
}

int64 UFabTokenStore::ExtractJwtExpSec(const FString& Jwt)
{
    if (Jwt.IsEmpty())
    {
        return 0;
    }

    TArray<FString> Parts;
    Jwt.ParseIntoArray(Parts, TEXT("."), /*CullEmpty*/false);
    if (Parts.Num() < 2)
    {
        return 0;
    }

    const FString B64 = Base64UrlToBase64(Parts[1]);
    FString Json;
    if (!FBase64::Decode(B64, Json))
    {
        return 0;
    }

    TSharedPtr<FJsonObject> Root;
    const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Json);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid())
    {
        return 0;
    }

    double ExpNum = 0.0;
    if (Root->TryGetNumberField(TEXT("exp"), ExpNum))
    {
        return (int64)ExpNum;
    }
    return 0;
}
