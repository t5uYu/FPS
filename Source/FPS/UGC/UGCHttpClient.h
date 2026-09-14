// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "Interfaces/IHttpRequest.h"
#include "UGCHttpClient.generated.h"

/** 可选的 LLM 模型（下拉单选，BuildRequestBody 负责转成实际 model string） */
UENUM(BlueprintType)
enum class EUGCLLMModel : uint8
{
    DeepSeek_Chat      UMETA(DisplayName = "DeepSeek Chat"),
    DeepSeek_Reasoner  UMETA(DisplayName = "DeepSeek Reasoner"),
    Qwen_Plus          UMETA(DisplayName = "Qwen Plus"),
    Qwen_Turbo         UMETA(DisplayName = "Qwen Turbo"),
    Qwen_Max           UMETA(DisplayName = "Qwen Max"),
};

/**
 * UUGCHttpClient
 *
 * OpenAI-compatible LLM HTTP client attached to the UGC PlayerController.
 * Authentication is resolved at runtime from FPS_UGC_LLM_API_KEY. A transient
 * override exists only for local developer sessions and is never serialized.
 */
UCLASS(ClassGroup = "UGC", meta = (BlueprintSpawnableComponent))
class FPS_API UUGCHttpClient : public UActorComponent
{
    GENERATED_BODY()

public:
    UUGCHttpClient();

    //-------------------------------------------------------------------
    // Configuration
    //-------------------------------------------------------------------

    /** Optional process-local override for development. Never saved to assets. */
    UPROPERTY(Transient, BlueprintReadWrite, Category = "UGC|LLM|Development",
        meta = (DisplayName = "API Key Override (Transient)"))
    FString APIKeyOverride;

    /** 使用的模型（下拉选择） */
    UPROPERTY(EditDefaultsOnly, BlueprintReadWrite, Category = "UGC|LLM|Config")
    EUGCLLMModel Model = EUGCLLMModel::DeepSeek_Chat;

    /** 最大输出 Token 数 */
    UPROPERTY(EditDefaultsOnly, BlueprintReadWrite, Category = "UGC|LLM|Config")
    int32 MaxTokens = 1024;

    /** 系统提示词（设定 LLM 角色） */
    UPROPERTY(EditDefaultsOnly, BlueprintReadWrite, Category = "UGC|LLM|Config",
        meta = (MultiLine = true))
    FString SystemPrompt = TEXT(
        "你是一个游戏内的 UGC 关卡编辑助手。玩家可以用自然语言让你操作游戏场景。\n"
        "你拥有以下能力：\n"
        "- 场景操作：place_object（放置预制体）、move_object（移动 Actor）、delete_object（删除 Actor）、list_objects（列出场景内容）\n"
        "- 角色属性：set_attribute / get_attribute（Health / MaxHealth / Armor / MovementSpeed / Stamina）\n"
        "- 游戏规则：set_rule / get_rule（RoundTime / RespawnDelay / FriendlyFire / GravityScale）\n"
        "- 武器：spawn_weapon（在指定坐标生成武器拾取物）\n"
        "- GAS 技能：grant_ability / remove_ability\n"
        "规则：\n"
        "1. 优先使用函数调用完成任务，不要只用文字描述。\n"
        "2. 坐标单位是厘米（cm），100 cm = 1 米。\n"
        "3. 不确定 scene_id 时先调用 list_objects 查询。\n"
        "4. 只有确实无法用函数实现时才纯文字回复。"
    );

    //-------------------------------------------------------------------
    // 发送请求（Lua 调用）
    //-------------------------------------------------------------------

    /**
     * 向 LLM 发送单条消息（无对话历史），携带 UGC 函数 Schema
     * @param UserMessage  用户输入的自然语言
     * @param ToolsJSON    UGCFunctionRegistry:GetSchemas() 返回的 JSON 字符串
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|LLM")
    void SendMessage(const FString& UserMessage, const FString& ToolsJSON);

    /**
     * 向 LLM 发送带完整对话历史的请求（多轮对话）
     * @param MessagesJSON  完整的 messages 数组 JSON，如 [{"role":"user","content":"..."},{"role":"assistant",...}]
     *                      由 Lua 层维护历史并序列化
     * @param ToolsJSON     UGCFunctionRegistry:GetSchemas() 返回的 JSON 字符串
     */
    UFUNCTION(BlueprintCallable, Category = "UGC|LLM")
    void SendMessageWithHistory(const FString& MessagesJSON, const FString& ToolsJSON);

    /** 取消当前进行中的请求 */
    UFUNCTION(BlueprintCallable, Category = "UGC|LLM")
    void CancelRequest();

    /** 是否有请求正在进行 */
    UFUNCTION(BlueprintCallable, Category = "UGC|LLM")
    bool IsRequestInProgress() const { return bRequestInProgress; }

    //-------------------------------------------------------------------
    // 回调（Lua 通过 BlueprintNativeEvent 覆盖）
    //-------------------------------------------------------------------

    /**
     * 请求成功完成
     * @param ResponseJSON  Claude 返回的完整 JSON 字符串，Lua 负责解析
     */
    UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "UGC|LLM")
    void OnMessageComplete(const FString& ResponseJSON);
    virtual void OnMessageComplete_Implementation(const FString& ResponseJSON);

    /**
     * 请求失败（网络错误 / 非 2xx 状态码）
     * @param ErrorMessage  错误描述
     */
    UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "UGC|LLM")
    void OnMessageError(const FString& ErrorMessage);
    virtual void OnMessageError_Implementation(const FString& ErrorMessage);

private:
    /** 构建请求体 JSON（单条用户消息，自动注入 system prompt） */
    FString BuildRequestBody(const FString& UserMessage, const FString& ToolsJSON) const;

    /** 构建请求体 JSON（完整 messages 数组，由调用方提供历史） */
    FString BuildRequestBodyWithMessages(const FString& MessagesJSON, const FString& ToolsJSON) const;

    /** Resolve credentials and provider endpoint without asset-configured secrets/hosts. */
    FString ResolveAPIKey() const;
    FString ResolveAPIEndpoint() const;

    /** HTTP 响应回调 */
    void OnHttpResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess);

    /** 当前请求是否进行中 */
    bool bRequestInProgress = false;

    /** 当前进行中的请求（用于取消） */
    TSharedPtr<IHttpRequest, ESPMode::ThreadSafe> ActiveRequest;
};
