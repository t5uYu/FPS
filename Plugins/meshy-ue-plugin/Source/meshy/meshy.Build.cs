// Copyright Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;
using System.IO;
using System;

public class meshy : ModuleRules
{
	public meshy(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;
		
		// 版本兼容性宏 - 支持 UE 5.6 和 5.7
		// 使用 ENGINE_MAJOR_VERSION 和 ENGINE_MINOR_VERSION 进行条件编译
		// 这些宏在引擎中已经定义，可以直接在 C++ 代码中使用
		
		PublicIncludePaths.AddRange(
			new string[] {
				"Runtime/Core/Public",
				"Runtime/CoreUObject/Public",
				"Runtime/Engine/Classes",
				"Runtime/Slate/Public",
				"Runtime/SlateCore/Public",
				"Runtime/AssetRegistry/Public",
				"Runtime/AssetTools/Public",
				"Runtime/Json/Public",
				"Runtime/JsonUtilities/Public",
				"Runtime/Networking/Public",
				"Runtime/Sockets/Public"
			}
		);
				
		
		PrivateIncludePaths.AddRange(
			new string[] {
				"Editor/UnrealEd/Public",
				"Editor/UnrealEd/Private",
				"Editor/EditorStyle/Public",
				"Editor/LevelEditor/Public",
				"Editor/LevelEditor/Private",
				"Editor/ToolMenus/Public",
				"Editor/ToolMenus/Private"
			}
		);
			
		
		PublicDependencyModuleNames.AddRange(
			new string[]
			{
				"Core",
				"Projects",
				"Json",
				"Sockets",
				"Networking",
				"HTTP",
				"PakFile",
				// UE 5.4 兼容性改动：删 zlib，改用 FileUtilities 模块的 FZipArchiveReader 解压 zip
				"FileUtilities",
                // 添加UI相关模块
                "SlateCore",
                "Slate",
                "UMG"
			}
		);
			
		
		PrivateDependencyModuleNames.AddRange(
			new string[]
			{
				"CoreUObject",
				"Engine",
				"Slate",
				"SlateCore",
				"InputCore",
				"UnrealEd",
				"AssetTools",
				"AssetRegistry",
				"LevelEditor",
				"EditorStyle",
				"ToolMenus", 
                "ApplicationCore" // 添加ApplicationCore以支持Slate UI相关功能
			}
		);

		// 添加插件依赖
		PrivateDependencyModuleNames.AddRange(
			new string[]
			{
				"UnrealEd",
				"AssetTools"
			}
		);

		// UE 5.4 兼容性：原 ConfigureMinizipSupport(Target) 已删除
		// UE 5.4 ThirdParty/zlib/1.3 没带 minizip（5.6+ 才有），改用 UE 自带的
		// FZipArchiveReader（FileUtilities 模块），编辑器构建可用，逻辑等价。
	}
}
