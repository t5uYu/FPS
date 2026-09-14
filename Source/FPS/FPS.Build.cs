// Copyright Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;

public class FPS : ModuleRules
{
	public FPS(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		// Public：本模块的公开头文件会把这些模块的类型暴露出去（UUserWidget / GAS / EnhancedInput /
		// IGenericTeamAgentInterface / UnLua 接口），所以任何包含 FPS 头的模块都能看到它们。
		PublicDependencyModuleNames.AddRange(new string[] {
			"Core",
			"CoreUObject",
			"Engine",
			"InputCore",        // UGCEditorBridge.cpp 使用 FKey；FPSCharacter.h 暴露输入相关类型
			"EnhancedInput",    // FPSCharacter.h / FPSPlayerController.h 的 UPROPERTY 暴露 UInputAction*、UInputMappingContext*
			"UMG",              // UI/FPSCrosshairWidget.h、UI/Menu/*、Inventory/Public/*Widget.h 暴露 UUserWidget
			"Slate",            // UGC/UGCWireOverlay.h、UGCEditorBridge.cpp 使用 Slate 控件与窗口
			"SlateCore",
			"GameplayAbilities", // GAS/、Weapon/FPSWeaponBase.h 暴露 UAbilitySystemComponent
			"GameplayTags",
			"GameplayTasks",
			"UnLua",            // Armor/GAS/Weapon 的公开头文件实现 IUnLuaInterface
			"AIModule"          // FPSCharacter.h 暴露 IGenericTeamAgentInterface
		});

		// Private：只在 .cpp 内部使用的模块。放在这里同样是"依赖瘦身"的一部分——
		// 它们不会成为本模块公开接口的一部分，将来拆分 UGC 插件（T11）时可以整块搬走。
		PrivateDependencyModuleNames.AddRange(new string[] {
			"HTTP",             // UGC/UGCHttpClient.cpp：LLM 请求
			"Json",             // UGC/UGCHttpClient.cpp：请求/响应体构造
			"PCG",              // UGC/UGCPCGBridge.cpp：PCGComponent / PCGGraph
		});

		// 编辑器专用：DesktopPlatform 只在 WITH_EDITOR 的资产对话框路径里出现
		// （UGC/UGCEditorBridge.cpp 已被 #if WITH_EDITOR 包住），Shipping 不链接它。
		if (Target.bBuildEditor)
		{
			PrivateDependencyModuleNames.Add("DesktopPlatform");
		}

		// 已移除：Niagara（全模块无任何符号引用）、ApplicationCore（无直接引用，
		// Slate/UMG 自身已公开传递该依赖）。若将来新增引用请重新加入对应列表。
	}
}