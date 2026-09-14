#include "LuaAssetContextMenu.h"

#include "AssetRegistry/AssetData.h"
#include "ContentBrowserMenuContexts.h"
#include "Engine/Blueprint.h"
#include "UObject/UnrealType.h"
#include "UObject/StructOnScope.h"
#include "Framework/Notifications/NotificationManager.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformProcess.h"
#include "MCPLogCapture.h"
#include "Actions/EditorAction.h"
#include "Misc/Paths.h"
#include "SourceCodeNavigation.h"
#include "ToolMenus.h"
#include "Widgets/Notifications/SNotificationList.h"

#define LOCTEXT_NAMESPACE "UEEditorMCPLuaAssetMenu"

namespace UEEditorMCPLuaAssetMenu
{
	static const FName OwnerName(TEXT("UEEditorMCP.LuaAssetContextMenu"));
	static FDelegateHandle StartupCallbackHandle;

	static void ShowNotification(const FString& Message, SNotificationItem::ECompletionState State)
	{
		FNotificationInfo Info(FText::FromString(Message));
		Info.ExpireDuration = 4.0f;
		Info.bUseLargeFont = false;

		if (TSharedPtr<SNotificationItem> Item = FSlateNotificationManager::Get().AddNotification(Info))
		{
			Item->SetCompletionState(State);
		}
	}

	static bool TryGetLuaModuleName(const UBlueprint* Blueprint, FString& OutModuleName)
	{
		OutModuleName.Reset();
		if (!Blueprint || !Blueprint->GeneratedClass)
		{
			return false;
		}

		UObject* ClassDefaultObject = Blueprint->GeneratedClass->GetDefaultObject();
		if (!ClassDefaultObject)
		{
			return false;
		}

		// Avoid a hard module dependency on UnLua. Its interface method is a normal
		// reflected UFunction on bound Blueprint classes, so invoke it by name.
		UFunction* GetModuleNameFunction = ClassDefaultObject->FindFunction(TEXT("GetModuleName"));
		if (!GetModuleNameFunction || GetModuleNameFunction->NumParms != 1)
		{
			return false;
		}

		FStrProperty* ReturnProperty = nullptr;
		for (TFieldIterator<FProperty> It(GetModuleNameFunction); It; ++It)
		{
			FProperty* Property = *It;
			if (Property->HasAllPropertyFlags(CPF_Parm | CPF_ReturnParm))
			{
				ReturnProperty = CastField<FStrProperty>(Property);
				break;
			}
		}
		if (!ReturnProperty)
		{
			return false;
		}

		FStructOnScope Params(GetModuleNameFunction);
		ClassDefaultObject->ProcessEvent(GetModuleNameFunction, Params.GetStructMemory());
		const FString* ReturnValue = ReturnProperty->ContainerPtrToValuePtr<FString>(Params.GetStructMemory());
		OutModuleName = ReturnValue ? ReturnValue->TrimStartAndEnd() : FString();
		return !OutModuleName.IsEmpty();
	}

	static bool ResolveLuaFile(const UBlueprint* Blueprint, FString& OutModuleName, FString& OutAbsolutePath)
	{
		OutAbsolutePath.Reset();
		if (!TryGetLuaModuleName(Blueprint, OutModuleName))
		{
			return false;
		}

		FString RelativeModulePath = OutModuleName;
		RelativeModulePath.ReplaceInline(TEXT("\\"), TEXT("/"));
		if (RelativeModulePath.EndsWith(TEXT(".lua"), ESearchCase::IgnoreCase))
		{
			RelativeModulePath.LeftChopInline(4);
		}
		RelativeModulePath.ReplaceInline(TEXT("."), TEXT("/"));
		while (RelativeModulePath.StartsWith(TEXT("/")))
		{
			RelativeModulePath.RightChopInline(1);
		}

		TArray<FString> CandidateRelativePaths;
		CandidateRelativePaths.Add(RelativeModulePath + TEXT(".lua"));
		if (RelativeModulePath.EndsWith(TEXT("_C")))
		{
			CandidateRelativePaths.Add(RelativeModulePath.LeftChop(2) + TEXT(".lua"));
		}

		const FString ScriptRoot = FPaths::ConvertRelativePathToFull(FPaths::ProjectContentDir() / TEXT("Script/"));
		for (const FString& CandidateRelativePath : CandidateRelativePaths)
		{
			const FString Candidate = FPaths::ConvertRelativePathToFull(
				FPaths::Combine(ScriptRoot, CandidateRelativePath));
			if (IFileManager::Get().FileExists(*Candidate))
			{
				OutAbsolutePath = Candidate;
				return true;
			}
		}

		return false;
	}

	static void OpenBoundLuaFiles(const FToolMenuContext& MenuContext)
	{
		const UContentBrowserAssetContextMenuContext* Context =
			UContentBrowserAssetContextMenuContext::FindContextWithAssets(MenuContext);
		if (!Context)
		{
			return;
		}

		TSet<FString> OpenedPaths;
		TArray<FString> MissingBindings;
		int32 OpenedCount = 0;

		for (UBlueprint* Blueprint : Context->LoadSelectedObjects<UBlueprint>())
		{
			FString ModuleName;
			FString LuaPath;
			if (!ResolveLuaFile(Blueprint, ModuleName, LuaPath))
			{
				MissingBindings.Add(Blueprint ? Blueprint->GetName() : TEXT("<invalid blueprint>"));
				continue;
			}

			if (OpenedPaths.Contains(LuaPath))
			{
				continue;
			}
			OpenedPaths.Add(LuaPath);

			if (!FSourceCodeNavigation::OpenSourceFile(LuaPath))
			{
				FPlatformProcess::LaunchFileInDefaultExternalApplication(
					*LuaPath, nullptr, ELaunchVerb::Edit);
			}

			++OpenedCount;
			UE_LOG(LogMCP, Log, TEXT("Open Lua File: %s [%s] -> %s"),
				*Blueprint->GetName(), *ModuleName, *LuaPath);
		}

		if (OpenedCount > 0)
		{
			ShowNotification(
				FString::Printf(TEXT("已打开 %d 个 Lua 文件"), OpenedCount),
				SNotificationItem::CS_Success);
		}

		if (MissingBindings.Num() > 0)
		{
			const FString Names = FString::Join(MissingBindings, TEXT(", "));
			ShowNotification(
				FString::Printf(TEXT("未找到 UnLua 绑定或对应文件：%s"), *Names),
				SNotificationItem::CS_Fail);
			UE_LOG(LogMCP, Warning, TEXT("Open Lua File: no valid UnLua module/file for %s"), *Names);
		}
	}

	static void PopulateMenu(FToolMenuSection& Section)
	{
		const UContentBrowserAssetContextMenuContext* Context =
			UContentBrowserAssetContextMenuContext::FindContextWithAssets(Section);
		if (!Context || Context->SelectedAssets.IsEmpty())
		{
			return;
		}

		FToolUIAction UIAction;
		UIAction.ExecuteAction = FToolMenuExecuteAction::CreateStatic(&OpenBoundLuaFiles);

		Section.AddMenuEntry(
			TEXT("UEEditorMCP.OpenBoundLuaFile"),
			LOCTEXT("OpenBoundLuaFile", "打开对应 Lua 文件"),
			LOCTEXT("OpenBoundLuaFileTooltip", "读取 Blueprint 的 UnLua GetModuleName，并打开 Content/Script 下对应的 .lua 文件。支持多选。"),
			FSlateIcon(),
			UIAction);
	}

	static void RegisterMenus()
	{
		FToolMenuOwnerScoped OwnerScoped(OwnerName);
		if (UToolMenu* Menu = UE::ContentBrowser::ExtendToolMenu_AssetContextMenu(UBlueprint::StaticClass()))
		{
			FToolMenuSection& Section = Menu->FindOrAddSection(TEXT("GetAssetActions"));
			Section.AddDynamicEntry(
				TEXT("UEEditorMCP.OpenBoundLuaFile.Dynamic"),
				FNewToolMenuSectionDelegate::CreateStatic(&PopulateMenu));
		}
	}

	void Install()
	{
		if (UToolMenus::IsToolMenuUIEnabled())
		{
			StartupCallbackHandle = UToolMenus::RegisterStartupCallback(
				FSimpleMulticastDelegate::FDelegate::CreateStatic(&RegisterMenus));
		}
	}

	void Remove()
	{
		if (StartupCallbackHandle.IsValid())
		{
			UToolMenus::UnRegisterStartupCallback(StartupCallbackHandle);
			StartupCallbackHandle.Reset();
		}
		UToolMenus::UnregisterOwner(OwnerName);
	}
}

#undef LOCTEXT_NAMESPACE


