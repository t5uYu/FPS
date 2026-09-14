// UGCPCGBridge.h — PCG 过程化生成桥接组件（2026-04-16）
//
// 将 UE5 PCG（Procedural Content Generation）能力封装为 Lua 白名单函数，
// 供 UGCFunctionRegistry.lua 和 LLM Function Calling 调用。
//
// 设计：
//   - 在指定位置 Spawn 一个持有 PCGComponent 的 Actor
//   - 设置 PCG Graph 的参数（seed / density / bounds）
//   - 触发 Generate / Cleanup
//   - 生成结果归入 UGCSceneData 管理（TODO: Day N）

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "UGCPCGBridge.generated.h"

class UPCGComponent;
class UPCGGraphInterface;

/**
 * UUGCPCGBridge
 *
 * 挂载在 UGCPlayerController 上，提供 PCG 过程化内容生成能力。
 * Lua 通过 pcg_generate / pcg_clear 调用。
 */
UCLASS(ClassGroup = "UGC", meta = (BlueprintSpawnableComponent))
class FPS_API UUGCPCGBridge : public UActorComponent
{
    GENERATED_BODY()

public:
    UUGCPCGBridge();

    //-------------------------------------------------------------------
    // 配置
    //-------------------------------------------------------------------

    /** 默认 PCG Graph 资产路径（可在蓝图 Defaults 里覆盖） */
    UPROPERTY(EditDefaultsOnly, BlueprintReadWrite, Category = "UGC|PCG")
    TSoftObjectPtr<UPCGGraphInterface> DefaultPCGGraph;

    /** 生成范围半径（cm），PCG 会在此范围内散布内容 */
    UPROPERTY(EditDefaultsOnly, BlueprintReadWrite, Category = "UGC|PCG")
    float DefaultRadius = 1000.f;

    /** 默认随机种子（0 = 每次随机） */
    UPROPERTY(EditDefaultsOnly, BlueprintReadWrite, Category = "UGC|PCG")
    int32 DefaultSeed = 0;

    //-------------------------------------------------------------------
    // Lua 可调用接口
    //-------------------------------------------------------------------

    /**
     * 在指定位置执行 PCG 过程化生成
     * @param Location  生成中心点（世界坐标）
     * @param Radius    生成半径（cm），0 = 使用默认值
     * @param Seed      随机种子，0 = 随机
     * @param GraphPath 保留兼容参数；必须为空，仅允许使用审核过的 DefaultPCGGraph
     * @return 生成的根 Actor，失败返回 nullptr
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|PCG")
    AActor* Generate(FVector Location, float Radius = 0.f, int32 Seed = 0, const FString& GraphPath = TEXT(""));

    /**
     * 清除指定 PCG Actor 的所有生成内容
     * @param PCGActor  之前 Generate 返回的 Actor
     * @return 清除成功返回 true
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|PCG")
    bool Cleanup(AActor* PCGActor);

    /**
     * 清除所有由本 Bridge 生成的 PCG 内容
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|PCG")
    void CleanupAll();

    /** 当前已生成的 PCG Actor 数量 */
    UFUNCTION(BlueprintCallable, Category = "UGC|PCG")
    int32 GetActiveCount() const { return ActivePCGActors.Num(); }

private:
    /** 追踪所有由本 Bridge 生成的 PCG Actor */
    UPROPERTY()
    TArray<AActor*> ActivePCGActors;
};
