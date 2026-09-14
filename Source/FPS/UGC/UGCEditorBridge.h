// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "UGCEditorBridge.generated.h"

/**
 * UUGCEditorBridge
 *
 * UGC 编辑器的 C++ 原子操作层，挂载在 UGCPlayerController 上。
 * 职责极简：只提供引擎层无法在 Lua 直接完成的操作：
 *   1. 按 Blueprint 类路径动态 Spawn Actor
 *   2. Destroy Actor
 *   3. 屏幕坐标射线检测（点击选中）
 *   4. 设置 Actor 选中高亮
 *
 * 所有业务逻辑（选中状态、撤销栈、序列化）均在 Lua 层完成。
 */
UCLASS(ClassGroup = "UGC", meta = (BlueprintSpawnableComponent))
class FPS_API UUGCEditorBridge : public UActorComponent
{
    GENERATED_BODY()

public:
    UUGCEditorBridge();

    /**
     * 在世界中生成一个可放置 Actor
     * @param BlueprintPath  蓝图类资产路径，如 "/Game/_UGC/Placeables/BP_Placeable_Box"
     * @param Location       世界坐标
     * @param Rotation       旋转
     * @return 生成的 Actor，失败返回 nullptr
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    AActor* SpawnPlaceable(const FString& BlueprintPath, FVector Location, FRotator Rotation);

    /**
     * 销毁一个 Actor
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    void DestroyActor(AActor* Actor);

    /** 与旧 void API 并存，供命令层获取删除是否真正成功。 */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    bool TryDestroyActor(AActor* Actor);

    /**
     * 从屏幕坐标发射射线，返回命中的第一个 Actor
     * 用于鼠标点击选中
     * @param ScreenX / ScreenY  屏幕坐标（像素）
     * @return 命中的 Actor，未命中返回 nullptr
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    AActor* LineTraceScreen(float ScreenX, float ScreenY);

    /** 同 LineTraceScreen，但返回命中的世界坐标（未命中返回 ZeroVector）
     *  ActorToIgnore：额外忽略的 Actor（如 Ghost 预览体），传 nullptr 不忽略 */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    FVector LineTraceScreenPosition(float ScreenX, float ScreenY, AActor* ActorToIgnore);

    /** 同 LineTraceScreenPosition，但可忽略多个 Actor（用于拖拽时同时排除 Actor 本身和 Gizmo 箭头） */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    FVector LineTraceScreenPositionMulti(float ScreenX, float ScreenY, const TArray<AActor*>& ActorsToIgnore);

    /**
     * 设置 Actor 的选中高亮（描边）
     * @param Actor   目标 Actor
     * @param bEnable true=高亮，false=取消
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    void SetActorHighlight(AActor* Actor, bool bEnable);

    /**
     * 获取 Actor 的世界 Transform（供 Lua 读取序列化）
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    FTransform GetActorTransform(AActor* Actor) const;

    /**
     * 设置 Actor 的世界 Transform
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    void SetActorTransform(AActor* Actor, const FTransform& NewTransform);

    /** 与旧 void API 并存，供命令层获取 Transform 是否真正应用。 */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    bool TrySetActorTransform(AActor* Actor, const FTransform& NewTransform);

    /**
     * 设置 Actor 下所有 PrimitiveComponent 的 Translucency Sort Priority。
     * 主要用于让 Gizmo 这类半透明编辑器控件拥有更高的渲染排序。
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    void SetActorTranslucencySortPriority(AActor* Actor, int32 Priority);

    /**
     * 设置 Actor 下所有 PrimitiveComponent 的深度优先级组。
     * bForeground=true 时会尝试以前景层绘制，减少被场景几何遮挡。
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    void SetActorDepthPriorityForeground(AActor* Actor, bool bForeground);

    /**
     * 读取 Actor 本地包围盒的最小 Z。
     * 用于像 Gizmo 这类“默认沿本地 +Z 朝前”的资产，计算根部到 Actor 原点的真实偏移。
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    float GetActorLocalBoundsMinZ(AActor* Actor) const;

    /**
     * 枚举目录下匹配通配符的文件，返回完整绝对路径数组
     * 仅在 Editor 构建可用；打包运行时返回空数组并使用 Catalog。
     * Directory 示例：FPaths::ProjectContentDir() + "_UGC/Placeables/"
     * WildCard  示例："*.uasset"
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    TArray<FString> FindFilesInDirectory(const FString& Directory, const FString& WildCard);

    /** 在 Actor 位置绘制持久调试坐标轴（X=红 Y=绿 Z=蓝） */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    void DrawActorAxes(AActor* Actor, float AxisLength);

    /** 清除之前绘制的调试坐标轴 */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    void ClearDebugAxes();

    /** 检测鼠标左键当前是否处于按下状态（供 Lua 拖拽检测使用） */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    bool IsMouseButtonDown();

    /** 检测 Escape 键当前是否处于按下状态（供 Lua 取消放置模式使用） */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    bool IsEscapeDown();

    /**
     * 弹出系统原生「另存为」对话框，返回用户选择的完整路径；取消返回空字符串
     * DefaultPath：初始目录；DefaultFile：默认文件名；FileType 示例："JSON 文件|*.json"
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    FString ShowSaveFileDialog(const FString& Title, const FString& DefaultPath, const FString& DefaultFile, const FString& FileType);

    /**
     * 弹出系统原生「打开文件」对话框，返回用户选择的完整路径；取消返回空字符串
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Editor")
    FString ShowOpenFileDialog(const FString& Title, const FString& DefaultPath, const FString& FileType);

    UFUNCTION(BlueprintPure, Category = "UGC|Editor")
    bool SupportsNativeFileDialogs() const;

private:
    APlayerController* GetPC() const;

    UPROPERTY()
    TSet<TObjectPtr<AActor>> SpawnedActors;
};
