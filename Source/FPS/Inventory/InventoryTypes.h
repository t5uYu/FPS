// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Engine/DataTable.h"
#include "InventoryTypes.generated.h"

/**
 * 物品类型枚举
 * 用于分类管理不同类型的物品
 */
UENUM(BlueprintType)
enum class EItemType : uint8
{
	Weapon      UMETA(DisplayName = "武器"),
	Armor       UMETA(DisplayName = "防具"),
	Ammo        UMETA(DisplayName = "弹药"),
	Medical     UMETA(DisplayName = "医疗"),
	Container   UMETA(DisplayName = "容器"),
	Key         UMETA(DisplayName = "钥匙"),
	Consumable  UMETA(DisplayName = "消耗品"),
	Quest       UMETA(DisplayName = "任务物品"),
	Collectables UMETA(DisplayName = "收藏品"),
	Attachment  UMETA(DisplayName = "配件"),
	Misc        UMETA(DisplayName = "杂项")
};

/**
 * 物品定义行结构
 * 对应 DataTable 的每一行数据，定义了物品的基础属性
 *
 * 使用说明：
 * 1. 策划在 Excel 中编辑物品数据
 * 2. Python 工具将 Excel 转换为 CSV
 * 3. UE 导入 CSV 到 DataTable
 * 4. 运行时通过 ItemID 查询此结构
 */
USTRUCT(BlueprintType)
struct FItemDefinitionRow : public FTableRowBase
{
	GENERATED_BODY()

	/** 物品唯一ID（主键）- 格式: {类型前缀}_{子类型}_{名称} */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Item")
	FName ItemID;

	/** 物品显示名称（支持本地化） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Item")
	FText ItemName;

	/** 物品类型 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Item")
	EItemType ItemType;

	/** 物品在网格中的宽度（格子数） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Grid")
	int32 SizeX;

	/** 物品在网格中的高度（格子数） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Grid")
	int32 SizeY;

	/** 是否可以旋转（按R键旋转90度） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Grid")
	bool bCanRotate;

	/** 最大堆叠数量（1 = 不可堆叠） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Stack")
	int32 MaxStackSize;

	/** 基础重量（kg） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Properties")
	float BaseWeight;

	/** 购买价格（从商人处购买） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Economy")
	int32 BuyPrice;

	/** 出售价格（卖给商人） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Economy")
	int32 SellPrice;

	/** 商人库存数量（0 = 不在商店出售） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Economy")
	int32 TraderStock;

	/** 库存刷新间隔（秒，0 = 不刷新） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Economy")
	int32 RefreshInterval;

	/** 物品图标（UI显示） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Visual")
	TSoftObjectPtr<UTexture2D> Icon;

	/** 3D 模型路径（用于掉落物、装备显示） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Visual")
	TSoftClassPtr<AActor> MeshClass;

	/** 是否是容器（背包、战术背心等） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Container")
	bool bIsContainer;

	/** 作为容器时的内部网格宽度 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Container", meta = (EditCondition = "bIsContainer"))
	int32 ContainerGridSizeX;

	/** 作为容器时的内部网格高度 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Container", meta = (EditCondition = "bIsContainer"))
	int32 ContainerGridSizeY;

	/** 容器允许的物品类型（空数组 = 允许所有类型） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Container", meta = (EditCondition = "bIsContainer"))
	TArray<EItemType> AllowedItemTypes;

	/** Lua 脚本路径（特殊物品逻辑，如医疗包使用效果） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Script")
	FString LuaScriptPath;

	/** 物品描述（用于悬浮提示） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Item")
	FText ItemDescription;

	// 构造函数：设置默认值
	FItemDefinitionRow()
		: ItemType(EItemType::Misc)
		, SizeX(1)
		, SizeY(1)
		, bCanRotate(true)
		, MaxStackSize(1)
		, BaseWeight(0.0f)
		, BuyPrice(0)
		, SellPrice(0)
		, TraderStock(0)
		, RefreshInterval(0)
		, bIsContainer(false)
		, ContainerGridSizeX(0)
		, ContainerGridSizeY(0)
	{
	}
};

/**
 * 物品 Mesh 配置行
 * 分离 Mesh 数据到独立表，便于美术资源管理
 */
USTRUCT(BlueprintType)
struct FItemMeshRow : public FTableRowBase
{
	GENERATED_BODY()

	/** Mesh ID（主键，被 ItemDefinition 引用） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Mesh")
	FName MeshID;

	/** 骨骼网格体 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Mesh")
	TSoftObjectPtr<USkeletalMesh> SkeletalMesh;

	/** 静态网格体（二选一） */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Mesh")
	TSoftObjectPtr<UStaticMesh> StaticMesh;

	/** 物理资源 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Mesh")
	TSoftObjectPtr<UPhysicsAsset> PhysicsAsset;

	/** 材质覆盖 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Mesh")
	TArray<TSoftObjectPtr<UMaterialInterface>> Materials;
};

// ============================================================
// 已废弃的结构体（数据已合并到 FItemDefinitionRow）
// ============================================================
//
// FContainerConfigRow - 容器配置已合并到 FItemDefinitionRow
// FEconomyConfigRow - 经济数据已合并到 FItemDefinitionRow
//
// 如果你的代码中引用了这些结构体，请：
// 1. 容器配置 → 使用 FItemDefinitionRow 的 bIsContainer, ContainerGridSizeX, ContainerGridSizeY
// 2. 经济配置 → 使用 FItemDefinitionRow 的 BuyPrice, SellPrice, TraderStock, RefreshInterval
// ============================================================

/**
 * 物品实例
 * 运行时物品的具体实例（有耐久度、堆叠数等动态属性）
 */
USTRUCT(BlueprintType)
struct FInventoryItem
{
	GENERATED_BODY()

	/** 物品定义ID（指向 DataTable 的 ItemID） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Item")
	FName ItemDefID;

	/** 全局唯一实例ID（用于网络复制、防刷物品） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Item")
	FGuid InstanceID;

	/** 当前堆叠数量 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Stack")
	int32 StackCount;

	/** 耐久度（0-100） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Durability")
	float Durability;

	/** 自定义属性（Lua可访问，如弹药类型、附魔等） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Custom")
	TMap<FName, float> CustomProperties;

	FInventoryItem()
		: InstanceID(FGuid::NewGuid())
		, StackCount(1)
		, Durability(100.0f)
	{
	}
};

/**
 * 物品放置数据
 * 描述物品在网格中的位置和旋转状态
 */
USTRUCT(BlueprintType)
struct FInventoryItemPlacement
{
	GENERATED_BODY()

	/** 物品实例 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Placement")
	FInventoryItem Item;

	/** 网格位置（左上角） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Placement")
	FIntPoint GridPosition;

	/** 是否已旋转（90度） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Placement")
	bool bIsRotated;

	FInventoryItemPlacement()
		: GridPosition(FIntPoint::ZeroValue)
		, bIsRotated(false)
	{
	}
};

/**
 * 背包区域定义（"兜"）
 * 用于定义背包内的物理隔断区域
 * 物品不能跨区域放置，大物品需要足够大的连续区域
 *
 * 设计示例：
 * - 便宜背包 3x3：分成 1x3 + 2x3 两个区域，无法放置 3x3 物品
 * - 贵背包 3x3：整个 3x3 是一个区域，可以放置 3x3 物品
 */
USTRUCT(BlueprintType)
struct FInventoryRegion
{
	GENERATED_BODY()

	/** 区域名称（用于调试/UI显示） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Region")
	FName RegionName;

	/** 区域起始坐标（左上角） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Region")
	FIntPoint Offset;

	/** 区域大小（宽x高，格子数） */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Region")
	FIntPoint Size;

	FInventoryRegion()
		: RegionName(NAME_None)
		, Offset(FIntPoint::ZeroValue)
		, Size(FIntPoint(1, 1))
	{
	}

	FInventoryRegion(FName InName, FIntPoint InOffset, FIntPoint InSize)
		: RegionName(InName)
		, Offset(InOffset)
		, Size(InSize)
	{
	}

	/** 检查一个点是否在此区域内 */
	bool ContainsPoint(FIntPoint Point) const
	{
		return Point.X >= Offset.X
			&& Point.Y >= Offset.Y
			&& Point.X < Offset.X + Size.X
			&& Point.Y < Offset.Y + Size.Y;
	}

	/** 检查一个矩形是否完全在此区域内 */
	bool ContainsRect(FIntPoint RectOffset, FIntPoint RectSize) const
	{
		return RectOffset.X >= Offset.X
			&& RectOffset.Y >= Offset.Y
			&& RectOffset.X + RectSize.X <= Offset.X + Size.X
			&& RectOffset.Y + RectSize.Y <= Offset.Y + Size.Y;
	}
};
