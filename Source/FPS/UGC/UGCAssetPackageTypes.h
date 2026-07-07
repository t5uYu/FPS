// Copyright Epic Games, Inc. All Rights Reserved.
// Runtime UGC package metadata shared by C++ and Lua-facing systems.

#pragma once

#include "CoreMinimal.h"
#include "UGCAssetPackageTypes.generated.h"

UENUM(BlueprintType)
enum class EUGCRuntimeAssetSourceType : uint8
{
    Unknown UMETA(DisplayName = "Unknown"),
    GLB     UMETA(DisplayName = "GLB"),
    GLTF    UMETA(DisplayName = "GLTF"),
    Zip     UMETA(DisplayName = "Zip"),
    Package UMETA(DisplayName = "UGC Package"),
};

USTRUCT(BlueprintType)
struct FUGCRuntimeAssetManifest
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly)
    FString PackageId;

    UPROPERTY(BlueprintReadOnly)
    FString AssetId;

    UPROPERTY(BlueprintReadOnly)
    FString Name;

    UPROPERTY(BlueprintReadOnly)
    FString SourceType;

    /** Absolute path to Saved/UGC/Packages/{package_id}. */
    UPROPERTY(BlueprintReadOnly)
    FString PackageDir;

    /** Absolute path to manifest.json. */
    UPROPERTY(BlueprintReadOnly)
    FString ManifestPath;

    /** Relative path under PackageDir, e.g. payload/model.glb. */
    UPROPERTY(BlueprintReadOnly)
    FString ModelRelativePath;

    UPROPERTY(BlueprintReadOnly)
    FString OriginalPath;

    UPROPERTY(BlueprintReadOnly)
    FString OriginalName;

    UPROPERTY(BlueprintReadOnly)
    FString Provider;

    UPROPERTY(BlueprintReadOnly)
    FString ThumbnailRelativePath;

    UPROPERTY(BlueprintReadOnly)
    FString ContentHash;

    UPROPERTY(BlueprintReadOnly)
    int64 CreatedAtSeconds = 0;
};
