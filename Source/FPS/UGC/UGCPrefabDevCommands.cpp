// Copyright Epic Games, Inc. All Rights Reserved.

/**
 * UGCPrefabDevCommands.cpp（T5 迁移工具，Editor-only）
 *
 * 用途：把 Content/_UGC/Placeables 下「还没有 UUGCPrefabDefinition」的 Placeable 资产
 * 一次性补齐定义资产，把 Lua 里硬编码的 Catalog 真正搬到资产侧。
 *
 * 为什么做成控制台命令而不是手工点：迁移必须可复现、可在 CI/无头编辑器里重跑，
 * 而且这里要读 placeable_manifest.json 的语义（label/category/description/tags）做回填。
 *
 * 用法（无头）：
 *   UnrealEditor-Cmd.exe <project>.uproject -ExecCmds="UGC.CreatePrefabDefinitions" -unattended -nosplash -NullRHI -log
 * 用法（编辑器内）：控制台输入 UGC.CreatePrefabDefinitions
 *
 * 幂等：已存在的定义资产只做字段回填（不重复创建），不动用户手改过的非空字段以外的东西。
 */

#include "CoreMinimal.h"

#if WITH_EDITOR

#include "UGCPrefabDefinition.h"
#include "AssetRegistry/AssetRegistryModule.h"
#include "Engine/Blueprint.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformFileManager.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "UObject/Package.h"
#include "UObject/SavePackage.h"
#include "Misc/PackageName.h"
#include "Dom/JsonObject.h"
#include "Dom/JsonValue.h"
#include "Engine/AssetManager.h"

namespace
{
    const TCHAR* const PlaceablesDir = TEXT("/Game/_UGC/Placeables");
    const TCHAR* const DefinitionsDir = TEXT("/Game/_UGC/Prefabs");

    /** manifest 条目：id → { label, category, description, tags } */
    struct FManifestEntry
    {
        FString Label;
        FString Category;
        FString Description;
        TArray<FString> Tags;
    };

    bool LoadManifest(TMap<FString, FManifestEntry>& OutEntries)
    {
        const FString Path = FPaths::ProjectContentDir() / TEXT("_UGC/Placeables/placeable_manifest.json");
        FString Raw;
        if (!FFileHelper::LoadFileToString(Raw, *Path))
        {
            UE_LOG(LogTemp, Warning, TEXT("[UGCPrefabDevCommands] 读不到 manifest: %s"), *Path);
            return false;
        }

        TArray<TSharedPtr<FJsonValue>> Items;
        const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Raw);
        if (!FJsonSerializer::Deserialize(Reader, Items))
        {
            UE_LOG(LogTemp, Warning, TEXT("[UGCPrefabDevCommands] manifest 解析失败"));
            return false;
        }

        for (const TSharedPtr<FJsonValue>& Item : Items)
        {
            const TSharedPtr<FJsonObject>* Object = nullptr;
            if (!Item.IsValid() || !Item->TryGetObject(Object) || !Object)
            {
                continue;
            }
            FManifestEntry Entry;
            (*Object)->TryGetStringField(TEXT("label"), Entry.Label);
            (*Object)->TryGetStringField(TEXT("category"), Entry.Category);
            (*Object)->TryGetStringField(TEXT("description"), Entry.Description);
            const TArray<TSharedPtr<FJsonValue>>* Tags = nullptr;
            if ((*Object)->TryGetArrayField(TEXT("tags"), Tags) && Tags)
            {
                for (const TSharedPtr<FJsonValue>& Tag : *Tags)
                {
                    Entry.Tags.Add(Tag->AsString());
                }
            }
            FString Id;
            if ((*Object)->TryGetStringField(TEXT("id"), Id) && !Id.IsEmpty())
            {
                OutEntries.Add(Id, Entry);
            }
        }
        return true;
    }

    /** BA_Placeable_Box.uasset → "Box"；不匹配返回空串 */
    FString PrefabIdFromAssetName(const FString& AssetName)
    {
        FString Id;
        if (!AssetName.Split(TEXT("BA_Placeable_"), nullptr, &Id) && !AssetName.Split(TEXT("BP_Placeable_"), nullptr, &Id))
        {
            return FString();
        }
        return Id;
    }

    UUGCPrefabDefinition* FindOrCreateDefinition(const FString& Id, bool& bOutCreated)
    {
        const FString PackageName = FString::Printf(TEXT("%s/PDA_Prefab_%s"), DefinitionsDir, *Id);
        const FString ObjectPath = FString::Printf(TEXT("%s.PDA_Prefab_%s"), *PackageName, *Id);

        if (UUGCPrefabDefinition* Existing = LoadObject<UUGCPrefabDefinition>(nullptr, *ObjectPath))
        {
            bOutCreated = false;
            return Existing;
        }

        UPackage* Package = CreatePackage(*PackageName);
        if (!Package)
        {
            return nullptr;
        }
        const FName AssetName(*FString::Printf(TEXT("PDA_Prefab_%s"), *Id));
        UUGCPrefabDefinition* Definition = NewObject<UUGCPrefabDefinition>(
            Package, AssetName, RF_Public | RF_Standalone | RF_Transactional);
        if (Definition)
        {
            FAssetRegistryModule::AssetCreated(Definition);
            Package->MarkPackageDirty();
        }
        bOutCreated = true;
        return Definition;
    }

    void CreatePrefabDefinitionsFromPlaceables()
    {
        TMap<FString, FManifestEntry> Manifest;
        LoadManifest(Manifest);

        const FString DiskDir = FPaths::ProjectContentDir() / TEXT("_UGC/Placeables");
        TArray<FString> Files;
        IFileManager::Get().FindFiles(Files, *(DiskDir / TEXT("*.uasset")), true, false);

        int32 Created = 0;
        int32 Updated = 0;
        int32 Skipped = 0;
        TArray<UPackage*> PackagesToSave;

        for (const FString& File : Files)
        {
            const FString AssetName = FPaths::GetBaseFilename(File);
            const FString Id = PrefabIdFromAssetName(AssetName);
            if (Id.IsEmpty())
            {
                continue;
            }

            const FString BlueprintPath = FString::Printf(TEXT("%s/%s"), PlaceablesDir, *AssetName);
            UBlueprint* Blueprint = LoadObject<UBlueprint>(nullptr, *BlueprintPath);
            if (!Blueprint || !Blueprint->GeneratedClass)
            {
                UE_LOG(LogTemp, Warning, TEXT("[UGCPrefabDevCommands] 跳过 %s：不是蓝图或没有 GeneratedClass"), *AssetName);
                ++Skipped;
                continue;
            }

            bool bCreated = false;
            UUGCPrefabDefinition* Definition = FindOrCreateDefinition(Id, bCreated);
            if (!Definition)
            {
                UE_LOG(LogTemp, Warning, TEXT("[UGCPrefabDevCommands] 创建定义失败：%s"), *Id);
                ++Skipped;
                continue;
            }

            Definition->PrefabId = FName(*Id);
            Definition->ActorClass = TSoftClassPtr<AActor>(Blueprint->GeneratedClass);
            Definition->Kind = EUGCPrefabKind::Blueprint;
            if (const FManifestEntry* Entry = Manifest.Find(Id))
            {
                if (!Entry->Label.IsEmpty()) { Definition->DisplayName = FText::FromString(Entry->Label); }
                if (!Entry->Category.IsEmpty()) { Definition->Category = FName(*Entry->Category); }
                if (!Entry->Description.IsEmpty()) { Definition->Description = Entry->Description; }
                if (Entry->Tags.Num() > 0)
                {
                    Definition->Tags.Reset();
                    for (const FString& Tag : Entry->Tags)
                    {
                        Definition->Tags.Add(FName(*Tag));
                    }
                }
            }
            if (Definition->DisplayName.IsEmpty())
            {
                Definition->DisplayName = FText::FromString(Id);
            }
            if (Definition->Category.IsNone())
            {
                Definition->Category = FName(TEXT("基础几何体"));
            }
            if (Definition->AllowedModes.Num() == 0)
            {
                Definition->AllowedModes.Add(FName(TEXT("Edit")));
                Definition->AllowedModes.Add(FName(TEXT("Play")));
            }

            Definition->MarkPackageDirty();
            PackagesToSave.Add(Definition->GetPackage());
            bCreated ? ++Created : ++Updated;
            UE_LOG(LogTemp, Display, TEXT("[UGCPrefabDevCommands] %s %s → %s"),
                bCreated ? TEXT("创建") : TEXT("回填"), *Id, *Definition->GetActorClassPath());
        }

        if (PackagesToSave.Num() > 0)
        {
            int32 SavedCount = 0;
            for (UPackage* Package : PackagesToSave)
            {
                if (!Package)
                {
                    continue;
                }
                const FString FileName = FPackageName::LongPackageNameToFilename(
                    Package->GetName(), FPackageName::GetAssetPackageExtension());
                FSavePackageArgs SaveArgs;
                SaveArgs.TopLevelFlags = RF_Public | RF_Standalone;
                SaveArgs.SaveFlags = SAVE_NoError;
                if (UPackage::SavePackage(Package, nullptr, *FileName, SaveArgs))
                {
                    ++SavedCount;
                }
                else
                {
                    UE_LOG(LogTemp, Warning, TEXT("[UGCPrefabDevCommands] 保存失败: %s"), *Package->GetName());
                }
            }
            UE_LOG(LogTemp, Display, TEXT("[UGCPrefabDevCommands] 保存 %d/%d 个包"),
                SavedCount, PackagesToSave.Num());
        }

        UE_LOG(LogTemp, Display,
            TEXT("[UGCPrefabDevCommands] 完成：新建 %d，回填 %d，跳过 %d（定义目录 %s）"),
            Created, Updated, Skipped, DefinitionsDir);
    }

    FAutoConsoleCommandWithWorldAndArgs GCreatePrefabDefinitionsCommand(
        TEXT("UGC.CreatePrefabDefinitions"),
        TEXT("为 Content/_UGC/Placeables 下缺少 UUGCPrefabDefinition 的资产创建/回填定义资产（T5 迁移工具）"),
        FConsoleCommandWithWorldAndArgsDelegate::CreateStatic(
            [](const TArray<FString>&, UWorld*)
            {
                CreatePrefabDefinitionsFromPlaceables();
            }));
}

#endif // WITH_EDITOR
