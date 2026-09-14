// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCHttpClient.h"
#include "UGCPlayerController.h"
#include "HttpModule.h"
#include "Interfaces/IHttpResponse.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonWriter.h"
#include "Serialization/JsonSerializer.h"
#include "HAL/PlatformMisc.h"

UUGCHttpClient::UUGCHttpClient()
{
    PrimaryComponentTick.bCanEverTick = false;
}

// -----------------------------------------------------------------------
// Request dispatch
// -----------------------------------------------------------------------

FString UUGCHttpClient::ResolveAPIKey() const
{
    if (!APIKeyOverride.IsEmpty())
    {
        return APIKeyOverride;
    }
    return FPlatformMisc::GetEnvironmentVariable(TEXT("FPS_UGC_LLM_API_KEY"));
}

FString UUGCHttpClient::ResolveAPIEndpoint() const
{
    switch (Model)
    {
        case EUGCLLMModel::Qwen_Plus:
        case EUGCLLMModel::Qwen_Turbo:
        case EUGCLLMModel::Qwen_Max:
            return TEXT("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions");
        default:
            return TEXT("https://api.deepseek.com/v1/chat/completions");
    }
}

void UUGCHttpClient::SendMessage(const FString& UserMessage, const FString& ToolsJSON)
{
    const FString APIKey = ResolveAPIKey();
    if (APIKey.IsEmpty())
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCHttpClient] FPS_UGC_LLM_API_KEY 未配置"));
        OnMessageError(TEXT("LLM API Key 未配置（请设置环境变量 FPS_UGC_LLM_API_KEY）"));
        return;
    }

    if (bRequestInProgress)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCHttpClient] 上一个请求尚未完成"));
        return;
    }

    FString Body = BuildRequestBody(UserMessage, ToolsJSON);

    TSharedRef<IHttpRequest, ESPMode::ThreadSafe> Request = FHttpModule::Get().CreateRequest();
    Request->SetURL(ResolveAPIEndpoint());
    Request->SetVerb(TEXT("POST"));
    Request->SetHeader(TEXT("Content-Type"),  TEXT("application/json"));
    Request->SetHeader(TEXT("Authorization"), FString::Printf(TEXT("Bearer %s"), *APIKey));
    Request->SetContentAsString(Body);

    Request->OnProcessRequestComplete().BindUObject(this, &UUGCHttpClient::OnHttpResponse);

    if (Request->ProcessRequest())
    {
        ActiveRequest = Request;
        bRequestInProgress = true;
        UE_LOG(LogTemp, Log, TEXT("[UGCHttpClient] 请求已发送: %s"), *UserMessage);
    }
    else
    {
        UE_LOG(LogTemp, Error, TEXT("[UGCHttpClient] 请求发送失败"));
        OnMessageError(TEXT("请求发送失败"));
    }
}

void UUGCHttpClient::SendMessageWithHistory(const FString& MessagesJSON, const FString& ToolsJSON)
{
    const FString APIKey = ResolveAPIKey();
    if (APIKey.IsEmpty())
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCHttpClient] FPS_UGC_LLM_API_KEY 未配置"));
        OnMessageError(TEXT("LLM API Key 未配置（请设置环境变量 FPS_UGC_LLM_API_KEY）"));
        return;
    }

    if (bRequestInProgress)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCHttpClient] 上一个请求尚未完成"));
        return;
    }

    FString Body = BuildRequestBodyWithMessages(MessagesJSON, ToolsJSON);

    TSharedRef<IHttpRequest, ESPMode::ThreadSafe> Request = FHttpModule::Get().CreateRequest();
    Request->SetURL(ResolveAPIEndpoint());
    Request->SetVerb(TEXT("POST"));
    Request->SetHeader(TEXT("Content-Type"),  TEXT("application/json"));
    Request->SetHeader(TEXT("Authorization"), FString::Printf(TEXT("Bearer %s"), *APIKey));
    Request->SetContentAsString(Body);

    Request->OnProcessRequestComplete().BindUObject(this, &UUGCHttpClient::OnHttpResponse);

    if (Request->ProcessRequest())
    {
        ActiveRequest = Request;
        bRequestInProgress = true;
        UE_LOG(LogTemp, Log, TEXT("[UGCHttpClient] 多轮对话请求已发送（%d chars）"), MessagesJSON.Len());
    }
    else
    {
        UE_LOG(LogTemp, Error, TEXT("[UGCHttpClient] 请求发送失败"));
        OnMessageError(TEXT("请求发送失败"));
    }
}

void UUGCHttpClient::CancelRequest()
{
    if (ActiveRequest.IsValid())
    {
        ActiveRequest->CancelRequest();
        ActiveRequest.Reset();
    }
    bRequestInProgress = false;
}

// -----------------------------------------------------------------------
// 构建请求体
// -----------------------------------------------------------------------

static FString GetModelString(EUGCLLMModel InModel)
{
    switch (InModel)
    {
        case EUGCLLMModel::DeepSeek_Chat:     return TEXT("deepseek-chat");
        case EUGCLLMModel::DeepSeek_Reasoner: return TEXT("deepseek-reasoner");
        case EUGCLLMModel::Qwen_Plus:         return TEXT("qwen-plus");
        case EUGCLLMModel::Qwen_Turbo:        return TEXT("qwen-turbo");
        case EUGCLLMModel::Qwen_Max:          return TEXT("qwen-max");
        default:                              return TEXT("deepseek-chat");
    }
}

FString UUGCHttpClient::BuildRequestBody(const FString& UserMessage, const FString& ToolsJSON) const
{
    // OpenAI 兼容格式（DeepSeek / Qwen 等均支持）
    // 结构：{ model, max_tokens, messages: [{system},{user}], tools: [...] }

    // 顺序重要：先转义反斜杠本身，再转义其他字符
    auto EscapeJSON = [](const FString& In) -> FString
    {
        return In
            .Replace(TEXT("\\"), TEXT("\\\\"))
            .Replace(TEXT("\""), TEXT("\\\""))
            .Replace(TEXT("\n"), TEXT("\\n"))
            .Replace(TEXT("\r"), TEXT("\\r"))
            .Replace(TEXT("\t"), TEXT("\\t"));
    };
    FString SafeUserMsg = EscapeJSON(UserMessage);
    FString SafeSystem  = EscapeJSON(SystemPrompt);
    FString ModelStr    = GetModelString(Model);

    FString ToolsPart = ToolsJSON.IsEmpty() ? TEXT("") :
        FString::Printf(TEXT(",\"tools\":%s,\"tool_choice\":\"auto\""), *ToolsJSON);

    FString Body = FString::Printf(
        TEXT("{")
        TEXT("\"model\":\"%s\",")
        TEXT("\"max_tokens\":%d,")
        TEXT("\"messages\":[")
            TEXT("{\"role\":\"system\",\"content\":\"%s\"},")
            TEXT("{\"role\":\"user\",\"content\":\"%s\"}")
        TEXT("]")
        TEXT("%s")
        TEXT("}"),
        *ModelStr,
        MaxTokens,
        *SafeSystem,
        *SafeUserMsg,
        *ToolsPart
    );

    return Body;
}

FString UUGCHttpClient::BuildRequestBodyWithMessages(const FString& MessagesJSON, const FString& ToolsJSON) const
{
    // MessagesJSON 由 Lua 层拼好，已包含 system + 完整历史 + 最新 user message
    // 格式: [{"role":"system","content":"..."},{"role":"user","content":"..."},...]
    FString ModelStr = GetModelString(Model);

    FString ToolsPart = ToolsJSON.IsEmpty() ? TEXT("") :
        FString::Printf(TEXT(",\"tools\":%s,\"tool_choice\":\"auto\""), *ToolsJSON);

    FString Body = FString::Printf(
        TEXT("{")
        TEXT("\"model\":\"%s\",")
        TEXT("\"max_tokens\":%d,")
        TEXT("\"messages\":%s")
        TEXT("%s")
        TEXT("}"),
        *ModelStr,
        MaxTokens,
        *MessagesJSON,
        *ToolsPart
    );

    return Body;
}

// -----------------------------------------------------------------------
// HTTP 响应处理
// -----------------------------------------------------------------------

void UUGCHttpClient::OnHttpResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess)
{
    bRequestInProgress = false;
    ActiveRequest.Reset();

    if (!bSuccess || !Response.IsValid())
    {
        FString Err = TEXT("网络请求失败");
        UE_LOG(LogTemp, Error, TEXT("[UGCHttpClient] %s"), *Err);
        OnMessageError(Err);
        return;
    }

    int32 StatusCode = Response->GetResponseCode();
    FString ResponseBody = Response->GetContentAsString();

    UE_LOG(LogTemp, Log, TEXT("[UGCHttpClient] 响应状态: %d"), StatusCode);

    if (StatusCode < 200 || StatusCode >= 300)
    {
        FString Err = FString::Printf(TEXT("HTTP %d: %s"), StatusCode, *ResponseBody);
        UE_LOG(LogTemp, Error, TEXT("[UGCHttpClient] %s"), *Err);
        // 通过 PC NativeEvent 路由，UnLua 会拦截并调用 Lua 覆盖
        if (AUGCPlayerController* PC = Cast<AUGCPlayerController>(GetOwner()))
        {
            PC->OnLLMError(Err);
        }
        return;
    }

    // 成功：路由到 PC NativeEvent，Lua UGCPlayerController 负责转发给 LLMGateway
    if (AUGCPlayerController* PC = Cast<AUGCPlayerController>(GetOwner()))
    {
        PC->OnLLMResponse(ResponseBody);
    }
}

// -----------------------------------------------------------------------
// BlueprintNativeEvent 默认实现（Lua 会覆盖）
// -----------------------------------------------------------------------

void UUGCHttpClient::OnMessageComplete_Implementation(const FString& ResponseJSON)
{
    UE_LOG(LogTemp, Log, TEXT("[UGCHttpClient] OnMessageComplete（C++ 默认，应由 Lua 覆盖）"));
}

void UUGCHttpClient::OnMessageError_Implementation(const FString& ErrorMessage)
{
    UE_LOG(LogTemp, Warning, TEXT("[UGCHttpClient] OnMessageError: %s"), *ErrorMessage);
}
