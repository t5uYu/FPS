// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "FPS/FPSPlayerController.h"
#include "UGCEventRouterSubsystem.h"
#include "UGCPlayerController.generated.h"

class UUGCFunctionBridge;
class UUGCHttpClient;
class UUGCEditorBridge;
class UUGCPCGBridge;
class UUGCStorageBridge;

/**
 * AUGCPlayerController
 *
 * 继承自 AFPSPlayerController，附加 UGC 相关组件：
 *   - UUGCFunctionBridge : 原子操作白名单（GAS / 武器 / 规则）
 *   - UUGCHttpClient     : OpenAI-compatible LLM HTTP 客户端
 *   - UUGCStorageBridge  : 原子 JSON 存储边界
 *
 * 设计意图：
 *   保持基类 AFPSPlayerController 纯净（仅输入/菜单/会话）。
 *   在需要 UGC / LLM 能力的游戏模式里，将 GameMode 的 PlayerControllerClass
 *   设置为 BP_UGCPlayerController（继承本类的蓝图）即可。
 *
 * Lua 绑定：
 *   BP_UGCPlayerController → GetModuleName = "Gameplay.UGC.UGCPlayerController"
 */
UCLASS()
class FPS_API AUGCPlayerController : public AFPSPlayerController
{
    GENERATED_BODY()

public:
    AUGCPlayerController();

    //-------------------------------------------------------------------
    // UGC 组件访问（供 Lua 调用）
    //-------------------------------------------------------------------

    /** 获取 UGC 原子操作组件 */
    UFUNCTION(BlueprintCallable, Category = "UGC")
    UUGCFunctionBridge* GetUGCBridge() const { return UGCBridge; }

    /** 获取 LLM HTTP 客户端组件 */
    UFUNCTION(BlueprintCallable, Category = "UGC")
    UUGCHttpClient* GetUGCHttpClient() const { return UGCHttpClient; }

    /** 获取编辑器原子操作组件 */
    UFUNCTION(BlueprintCallable, Category = "UGC")
    UUGCEditorBridge* GetUGCEditorBridge() const { return EditorBridge; }

    /** 获取 PCG 过程化生成组件（2026-04-16 新增） */
    UFUNCTION(BlueprintCallable, Category = "UGC")
    UUGCPCGBridge* GetUGCPCGBridge() const { return PCGBridge; }

    /** 获取运行时安全的 UGC JSON 存储组件。 */
    UFUNCTION(BlueprintCallable, Category = "UGC")
    UUGCStorageBridge* GetUGCStorageBridge() const { return StorageBridge; }

    /** 从 Authoring Pawn 切换到独立 Gameplay Pawn；仅 Authority 执行。 */
    UFUNCTION(BlueprintCallable, Category = "UGC|Playtest")
    bool EnterPlaytestPawn();

    /** 销毁 Gameplay Pawn 并恢复 Authoring Pawn；仅 Authority 执行。 */
    UFUNCTION(BlueprintCallable, Category = "UGC|Playtest")
    bool ExitPlaytestPawn();

    /** 切换编辑器（F9），Lua 可覆盖 */
    UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "UGC")
    void ToggleEditor();
    virtual void ToggleEditor_Implementation() {}

    /** 复制文本到系统剪贴板（供 Lua Widget 调用） */
    UFUNCTION(BlueprintCallable, Category = "UGC|Utility")
    void CopyToClipboard(const FString& Text);

    //-------------------------------------------------------------------
    // T3：编辑器内 PIE 验收（冒烟测试）
    //-------------------------------------------------------------------

#if WITH_EDITOR
    /**
     * 是否要在 BeginPlay 时自动跑 7 项 UGC 冒烟验收。
     * 由编辑器启动参数 `-ExecCmds="UGC.SmokeTestEnable"` 打开（见 UGCSmokeTestCommands.cpp），
     * Lua 侧在 ReceiveBeginPlay 里查询它，避免用「人工去控制台敲命令」这种不可复现的步骤。
     * （WITH_EDITOR 守卫：实现只在编辑器构建里存在，Shipping 不链接这两个函数。）
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|Test")
    bool IsUGCSmokeTestEnabled() const;

    /** 手动触发冒烟验收（编辑器控制台 `UGC.SmokeTest` 也会调它）；Lua 实现 RunUGCSmokeTest */
    UFUNCTION(BlueprintCallable, Category = "UGC|Test")
    void RequestUGCSmokeTest();
#endif

    /** 冒烟验收主入口，Lua 实现（BlueprintImplementableEvent → UnLua 里写 M:RunUGCSmokeTest） */
    UFUNCTION(BlueprintImplementableEvent, Category = "UGC|Test")
    void RunUGCSmokeTest();

    /** 编辑模式鼠标左键点击，Lua 可覆盖 */
    UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "UGC")
    void EditorClick();
    virtual void EditorClick_Implementation() {}

    /**
     * Pawn 进入 TriggerZone 时由 AUGCTriggerZone 调用，Lua 可覆盖。
     * @param ProgramID  触发区域关联的程序 ID（"actor_prog_N"）
     */
    UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "UGC|TriggerZone")
    void OnTriggerZoneEnter(const FString& ProgramID);
    virtual void OnTriggerZoneEnter_Implementation(const FString& ProgramID) {}

    /**
     * Pawn 离开 TriggerZone 时由 AUGCTriggerZone 调用，Lua 可覆盖。
     * @param ProgramID  触发区域关联的程序 ID（"actor_prog_N"）
     */
    UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "UGC|TriggerZone")
    void OnTriggerZoneExit(const FString& ProgramID);
    virtual void OnTriggerZoneExit_Implementation(const FString& ProgramID) {}

    /** LLM 请求成功，ResponseJSON 为完整响应体，Lua 负责解析 */
    UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "UGC|LLM")
    void OnLLMResponse(const FString& ResponseJSON);
    virtual void OnLLMResponse_Implementation(const FString& ResponseJSON) {}

    /** LLM 请求失败 */
    UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "UGC|LLM")
    void OnLLMError(const FString& ErrorMessage);
    virtual void OnLLMError_Implementation(const FString& ErrorMessage) {}

protected:
    /** Playtest 时生成的 Gameplay Pawn 类；默认指向 BP_FPSPlayer。 */
    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "UGC|Playtest")
    TSubclassOf<APawn> PlaytestPawnClass;

    /** F9 → 切换编辑器 InputAction */
    UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Input|UGC")
    UInputAction* ToggleEditorAction;

    /** 编辑模式下鼠标左键点击（放置/选中 Actor） */
    UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Input|UGC")
    UInputAction* EditorClickAction;

    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;
    virtual void SetupInputComponent() override;

    UFUNCTION()
    void HandleUGCRuntimeEvent(const FUGCRuntimeEvent& Event);

    void HandleToggleEditorInput();
    void HandleEditorClickInput();

protected:
    /** UGC 原子操作组件 */
    UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "UGC")
    UUGCFunctionBridge* UGCBridge;

    /** OpenAI-compatible LLM HTTP 客户端组件 */
    UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "UGC")
    UUGCHttpClient* UGCHttpClient;

    /** 编辑器射线/生成/高亮原子操作组件 */
    UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "UGC")
    UUGCEditorBridge* EditorBridge;

    /** PCG 过程化生成组件（2026-04-16 新增） */
    UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "UGC")
    UUGCPCGBridge* PCGBridge;

    /** UGC 文档和本地 UI 状态的原子 JSON 存储。 */
    UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "UGC")
    UUGCStorageBridge* StorageBridge;

    UPROPERTY(Transient)
    TObjectPtr<APawn> AuthoringPawn;

    UPROPERTY(Transient)
    TObjectPtr<APawn> ActivePlaytestPawn;
};
