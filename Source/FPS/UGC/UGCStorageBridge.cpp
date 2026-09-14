// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCStorageBridge.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformFileManager.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"

UUGCStorageBridge::UUGCStorageBridge()
{
    PrimaryComponentTick.bCanEverTick = false;
}

bool UUGCStorageBridge::IsAllowedJsonPath(const FString& Path, FString& OutAbsolutePath) const
{
    OutAbsolutePath = FPaths::ConvertRelativePathToFull(Path);
    FPaths::NormalizeFilename(OutAbsolutePath);
    if (!FPaths::CollapseRelativeDirectories(OutAbsolutePath)) return false;
    FString SavedDirectory = FPaths::ConvertRelativePathToFull(FPaths::ProjectSavedDir());
    FPaths::NormalizeDirectoryName(SavedDirectory);
    SavedDirectory += TEXT("/");
    if (OutAbsolutePath.IsEmpty() || !OutAbsolutePath.StartsWith(SavedDirectory, ESearchCase::IgnoreCase))
    {
        return false;
    }

    // 允许的后缀：存档本体 <.json>，以及备份轮转用的一代/多代备份 <.bak> / <.bakN>。
    // 放宽到备份后缀是 T14 的需要：备份轮转由 Lua 侧用「读+原子写」完成，
    // 因此备份文件必须能通过这同一个边界写入；其余目录/后缀依旧被拒绝。
    if (OutAbsolutePath.EndsWith(TEXT(".json"), ESearchCase::IgnoreCase)) return true;
    if (OutAbsolutePath.EndsWith(TEXT(".bak"), ESearchCase::IgnoreCase)) return true;
    FString Suffix;
    OutAbsolutePath.Split(TEXT("."), nullptr, &Suffix, ESearchCase::IgnoreCase, ESearchDir::FromEnd);
    if (!Suffix.StartsWith(TEXT("bak"), ESearchCase::IgnoreCase)) return false;
    const FString Index = Suffix.RightChop(3);
    return !Index.IsEmpty() && Index.IsNumeric();
}

bool UUGCStorageBridge::FileExists(const FString& Path) const
{
    FString AbsolutePath;
    return IsAllowedJsonPath(Path, AbsolutePath) && FPaths::FileExists(AbsolutePath);
}

FString UUGCStorageBridge::ReadTextFile(const FString& Path) const
{
    FString AbsolutePath;
    FString Content;
    if (!IsAllowedJsonPath(Path, AbsolutePath) || !FFileHelper::LoadFileToString(Content, *AbsolutePath))
    {
        return TEXT("");
    }
    return Content;
}

bool UUGCStorageBridge::WriteTextFileAtomic(const FString& Path, const FString& Content) const
{
    FString AbsolutePath;
    if (!IsAllowedJsonPath(Path, AbsolutePath))
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCStorageBridge] Rejected non-JSON path: %s"), *Path);
        return false;
    }

    IPlatformFile& PlatformFile = FPlatformFileManager::Get().GetPlatformFile();
    const FString Directory = FPaths::GetPath(AbsolutePath);
    if (!Directory.IsEmpty() && !PlatformFile.CreateDirectoryTree(*Directory))
    {
        return false;
    }

    const FString TempPath = AbsolutePath + TEXT(".tmp");
    const FString BackupPath = AbsolutePath + TEXT(".bak");
    PlatformFile.DeleteFile(*TempPath);
    if (!FFileHelper::SaveStringToFile(Content, *TempPath, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM))
    {
        return false;
    }

    FString Verification;
    if (!FFileHelper::LoadFileToString(Verification, *TempPath) || Verification != Content)
    {
        PlatformFile.DeleteFile(*TempPath);
        return false;
    }

    PlatformFile.DeleteFile(*BackupPath);
    const bool bHadOriginal = PlatformFile.FileExists(*AbsolutePath);
    if (bHadOriginal && !PlatformFile.MoveFile(*BackupPath, *AbsolutePath))
    {
        PlatformFile.DeleteFile(*TempPath);
        return false;
    }

    if (!PlatformFile.MoveFile(*AbsolutePath, *TempPath))
    {
        PlatformFile.DeleteFile(*TempPath);
        if (bHadOriginal)
        {
            PlatformFile.MoveFile(*AbsolutePath, *BackupPath);
        }
        return false;
    }
    return true;
}
