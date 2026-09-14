// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Engine/DataAsset.h"
#include "UObject/PrimaryAssetId.h"
#include "UGCPrefabDefinition.generated.h"

class AActor;

/**
 * 预制体种类
 *   与 Lua 侧 UGCPrefabRegistry.GetKind() 的取值一一对应（JSON 里输出同样的字符串）。
 */
UENUM(BlueprintType)
enum class EUGCPrefabKind : uint8
{
    /** 磁盘上的 Placeable 蓝图 / 蓝图 Actor 资产 */
    Blueprint      UMETA(DisplayName = "Blueprint Placeable"),
    /** UGC runtime package 资产（manifest 描述的导入内容） */
    RuntimeAsset   UMETA(DisplayName = "Runtime Package Asset"),
    /** AnimAgent 动态 glb 资产 */
    DynamicGLB     UMETA(DisplayName = "Dynamic GLB"),
};

/**
 * 预制体的扁平信息（Lua / UI / LLM 用的统一视图）。
 *
 * 为什么要有这一层：AssetManager 里的 UUGCPrefabDefinition 是权威来源，但 Lua 侧只需要一份
 * 扁平列表；同时运行时动态注册的定义要能和磁盘资产用同一个结构表达。
 */
USTRUCT(BlueprintType)
struct FUGCPlaceableInfo
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    FName Id;

    /** Actor 类路径（含 _C 后缀），Lua 侧直接交给 SpawnPlaceable */
    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    FString ClassPath;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    FString Label;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    FString Category;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    FString Description;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    TArray<FString> Tags;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    int32 Version = 1;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    float Cost = 0.f;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    FVector Bounds = FVector(100.f, 100.f, 100.f);

    /** 允许出现的模式（Edit / Play）；空表示不限制 */
    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    TArray<FString> AllowedModes;

    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    EUGCPrefabKind Kind = EUGCPrefabKind::Blueprint;

    /** "asset"（AssetManager 扫描到的磁盘资产）| "dynamic"（运行时注册） */
    UPROPERTY(BlueprintReadOnly, Category = "UGC|Prefab")
    FString Source;
};

/**
 * UUGCPrefabDefinition —— 预制体的资产化定义（T5）
 *
 * 替代 Lua 里硬编码的 UGCPlaceableConfig Catalog：AssetManager 按 PrimaryAssetType "UGCPrefab"
 * 扫描磁盘资产，运行时导入的 GLB / runtime package 也用同一个类型动态注册
 * （见 FUGCPrefabCatalog::RegisterRuntimeDefinition → UAssetManager::AddDynamicAsset），
 * 于是「磁盘资产」和「运行时资产」共用一套 PrimaryAssetId 空间。
 *
 * PrimaryAssetId 形如 `UGCPrefab:Box`；PrefabId 为空时回退到资产名（GetFName()）。
 */
UCLASS(BlueprintType)
class FPS_API UUGCPrefabDefinition : public UPrimaryDataAsset
{
    GENERATED_BODY()

public:
    /** PrimaryAssetType：磁盘扫描用，必须与 DefaultGame.ini 的 PrimaryAssetTypesToScan 里的 TypeName 一致 */
    static const FName PrefabAssetType;

    /**
     * PrimaryAssetType：运行时注册用（不参与磁盘扫描）。
     *
     * 为什么必须分两个类型：`UAssetManager::AddDynamicAsset` 内部 ensure
     * `TypeData.Info.bIsDynamicAsset`（AssetManager.cpp:1304），而「被扫描的类型」这条标志是 false
     * —— 引擎明确不允许一个类型既从磁盘扫描又是 dynamic。所以磁盘定义走 UGCPrefab，
     * 运行时导入（GLB / runtime package）走 UGCPrefabRuntime；两者对上层是同一个查询入口
     * （FUGCPrefabCatalog::GetDefinitions 合并后给 Lua 一份 id → info 的列表）。
     */
    static const FName RuntimePrefabAssetType;

    /** 稳定 ID（Lua 侧 Registry.Prefabs 的 key）。为空时用资产名 */
    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Identity")
    FName PrefabId;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Identity")
    FText DisplayName;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Identity")
    FName Category;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Content", meta = (ClampMin = "1"))
    int32 Version = 1;

    /** 生成的 Actor 类（软引用：目录查询时不加载，只有 Spawn 才解析） */
    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Content")
    TSoftClassPtr<AActor> ActorClass;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Content")
    FString Description;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Content")
    TArray<FName> Tags;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Placement")
    FVector Bounds = FVector(100.f, 100.f, 100.f);

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Placement", meta = (ClampMin = "0"))
    float Cost = 0.f;

    /** 允许出现的模式（Edit / Play）；空表示不限制 */
    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Placement")
    TArray<FName> AllowedModes;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Prefab|Placement")
    EUGCPrefabKind Kind = EUGCPrefabKind::Blueprint;

    /** `UGCPrefab:<PrefabId>`；PrefabId 为空时退回 GetFName() */
    virtual FPrimaryAssetId GetPrimaryAssetId() const override;

    /** 有效 ID（PrefabId 为空时用资产名） */
    UFUNCTION(BlueprintPure, Category = "UGC|Prefab")
    FName GetEffectiveId() const;

    /** 类路径字符串（含 _C），供 Lua 侧 SpawnPlaceable 使用；未设置时返回空串 */
    UFUNCTION(BlueprintPure, Category = "UGC|Prefab")
    FString GetActorClassPath() const;

    /** 转成扁平信息（Source 由调用方给出：asset / dynamic） */
    void ToPlaceableInfo(FUGCPlaceableInfo& OutInfo, const FString& InSource) const;
};
