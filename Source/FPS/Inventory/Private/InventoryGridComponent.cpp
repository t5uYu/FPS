// Fill out your copyright notice in the Description page of Project Settings.
#include "FPS/Inventory/Public/InventoryGridComponent.h"

#include "FPS/Inventory/Public/ItemDataManager.h"


// Sets default values for this component's properties
UInventoryGridComponent::UInventoryGridComponent()
{
	// Set this component to be initialized when the game starts, and to be ticked every frame.  You can turn these features
	// off to improve performance if you don't need them.
	PrimaryComponentTick.bCanEverTick = false;

	// 设置默认网格大小，这里初始定义为3*3，作为安全箱
	// 背包引用时要手动设置更大
	GridSize = FIntPoint(3,3);
	
}
void UInventoryGridComponent::BeginPlay()
{
	Super::BeginPlay();

	// 从编辑器设置的 最新的 GridSize 初始化数组里拿到真正的背包大小
	int32 TotalSize = GridSize.X * GridSize.Y;
	OccupancyGrid.SetNum(TotalSize);
	for (auto& Grid : OccupancyGrid)
	{
		Grid = FGuid();
	}
	
	UE_LOG(LogTemp, Log, TEXT("[InventoryGridComponent] Grid initialized: %dx%d (%d cells)"),
		  GridSize.X, GridSize.Y, TotalSize);

}

bool UInventoryGridComponent::CanPlaceItem(FName ItemDefID, FIntPoint Position, bool bRotated, FGuid IgnoreItemID)
{
	// 拿到 bRotated 状态 Item 的 Size X 和 Size Y
	TOptional<FIntPoint> IsItemValid = GetItemSize(ItemDefID, bRotated);

	// 如果根据 ItemDefID 拿不到 ItemSize，说明有报错
	if (!IsItemValid.IsSet())
	{
		UE_LOG(LogTemp, Error,
			TEXT("[CanPlaceItem] ItemDefID %s 没有有效的 ItemSize"),
			*ItemDefID.ToString());
		return false;
	}

	// 起始位置不能为负数
	if (Position.X < 0 || Position.Y < 0)
	{
		UE_LOG(LogTemp, Warning, TEXT("[CanPlaceItem] 起始位置为负数！"));
		return false;
	}

	FIntPoint ItemSize = IsItemValid.GetValue();

	// 超出网格边界
	if (Position.X + ItemSize.X > GridSize.X || Position.Y + ItemSize.Y > GridSize.Y)
	{
		UE_LOG(LogTemp, Warning, TEXT("[CanPlaceItem] 物品 %s 超出 GridSize (%d, %d)"),
			*ItemDefID.ToString(),
			GridSize.X,
			GridSize.Y);
		return false;
	}

	// 区域检查：如果定义了区域，物品必须完全在某一个区域内
	if (Regions.Num() > 0)
	{
		int32 RegionIndex = FindRegionForPlacement(Position, ItemSize);
		if (RegionIndex == INDEX_NONE)
		{
			UE_LOG(LogTemp, Warning, TEXT("[CanPlaceItem] 物品 %s 跨区域或不在任何区域内"),
				*ItemDefID.ToString());
			return false;
		}
	}

	// 检查目标区域是否被占用（传入 IgnoreItemID 以忽略指定物品）
	return !IsAreaOccupied(Position, ItemSize, IgnoreItemID);
}

bool UInventoryGridComponent::AddItem(const FInventoryItem& Item, FIntPoint Position, bool bRotated)
{
	// 是否装得下
	if (!CanPlaceItem(Item.ItemDefID, Position, bRotated))
	{
		UE_LOG(LogTemp, Warning, TEXT("[InventoryGridComponent] AddItem Cannot place item %s at (%d, %d)"),   
			 *Item.ItemDefID.ToString(), Position.X, Position.Y);
		return false;
	}
	
	// 可以通过CanPlaceItem 说明这个Item是有效值
	FIntPoint ItemSize = GetItemSize(Item.ItemDefID,bRotated).GetValue();

	// 标记占用 ， 要用实例的Guid
	MarkGridOccupied(Position,ItemSize,Item.InstanceID);

	// 构建物品放置数据
	FInventoryItemPlacement ItemPlacement;
	ItemPlacement.Item = Item;
	ItemPlacement.bIsRotated = bRotated;
	ItemPlacement.GridPosition = Position;

	// 添加到 Items Map（Key: InstanceID, Value: Placement）- O(1)
	Items.Add(Item.InstanceID, ItemPlacement);

	UE_LOG(LogTemp, Log,
		TEXT("[AddItem] Successfully added item %s at (%d, %d), InstanceID: %s"),
		*Item.ItemDefID.ToString(),
		Position.X, Position.Y,
		*Item.InstanceID.ToString());

	// 广播变化事件，通知 UI 刷新
	OnInventoryChanged.Broadcast();

	return true;
}

bool UInventoryGridComponent::RemoveItem(FGuid ItemInstanceID)
{
	// 从 Items Map 中移除 - O(1)
	// Remove() 返回删除的元素数量，0 表示没找到
	if (Items.Remove(ItemInstanceID) == 0)
	{
		UE_LOG(LogTemp, Warning,
			TEXT("[RemoveItem] Item not found: %s"),
			*ItemInstanceID.ToString());
		return false;
	}

	// 清除网格占用
	ClearGridOccupancy(ItemInstanceID);

	UE_LOG(LogTemp, Log,
		TEXT("[RemoveItem] Successfully removed item: %s"),
		*ItemInstanceID.ToString());

	// 广播变化事件，通知 UI 刷新
	OnInventoryChanged.Broadcast();

	return true;
}

bool UInventoryGridComponent::IsAreaOccupied(FIntPoint Position, FIntPoint Size, FGuid IgnoreItemID)
{
	// Position = 起始坐标 (X, Y)
	// Size = 矩形大小 (宽, 高)
	// IgnoreItemID = 要忽略的物品 ID（用于移动物品时）

	// 遍历矩形区域
	for (int32 Y = 0; Y < Size.Y; Y++)
	{
		for (int32 X = 0; X < Size.X; X++)
		{
			int32 GridX = Position.X + X;
			int32 GridY = Position.Y + Y;
			int32 Index = GridY * GridSize.X + GridX;

			// 边界检查（防御性编程）
			if (Index < 0 || Index >= OccupancyGrid.Num())
			{
				UE_LOG(LogTemp, Error,
					TEXT("[IsAreaOccupied] Index out of bounds: %d"),
					Index);   
				return true;  // 越界视为被占用
			}

			
			FGuid OccupyingID = OccupancyGrid[Index];  // 获取占用者的 GUID    

			// 如果格子被占用 && 不是我们要忽略的物品
			if (OccupyingID.IsValid() && OccupyingID != IgnoreItemID)
			{
				return true;  // 被占用！
			}
		}
	}

	return false;  // 空闲

}

void UInventoryGridComponent::MarkGridOccupied(FIntPoint Position, FIntPoint Size, FGuid ItemID)
{
	// Position = 起始坐标 (X, Y)
	// Size = 背包大小 (宽, 高)
	// IgnoreItemID = 要忽略的物品 ID（用于移动物品时）

	// 遍历矩形区域
	for (int32 Y = 0; Y < Size.Y; Y++)
	{
		for (int32 X = 0; X < Size.X; X++)
		{
			int32 GridX = Position.X + X;
			int32 GridY = Position.Y + Y;
			int32 Index = GridY * GridSize.X + GridX;
			//为该格子的Guid赋值为ItemID
			OccupancyGrid[Index] = ItemID;
		}
	}
}

void UInventoryGridComponent::ClearGridOccupancy(FGuid ItemID)
{
	for (auto& Grid : OccupancyGrid)
	{
		if (Grid == ItemID)
		{
			//初始化Guid
			Grid = FGuid();
		}
	}
}

TOptional<FIntPoint> UInventoryGridComponent::GetItemSize(FName ItemDefID, bool bRotated) const
{
	// GameInstance是经典的单例模式，只有一个，因此要用指针 ^^_
	if (!GetWorld())
	{
		UE_LOG(LogTemp, Error, TEXT("[InventoryGridComponent] GetItemSize: World is null!"));
		return TOptional<FIntPoint>();
	}
	UGameInstance* GameInstance = GetWorld()->GetGameInstance();
	if (!GameInstance)
	{
		UE_LOG(LogTemp, Error, TEXT("[InventoryGridComponent] GetItemSize: GameInstance is null!"));
		return TOptional<FIntPoint>();
	}
	
	UItemDataManager* ItemDataMgr = GameInstance->GetSubsystem<UItemDataManager>();
	if (!ItemDataMgr)
	{
		UE_LOG(LogTemp,Warning,TEXT("[InventoryGridComponent] : GetItemSize ,couldn't find ItemDataManager!"));
		return TOptional<FIntPoint>();
	}

	// 这里为什么不统一用ItemDataMgr->GetItemSize(ItemDefID,bRotated); 是为了让日志直观
	// ItemDataMgr->GetItemSize里面还有关于 ItemDefID是否有效的判断贝贝
	return ItemDataMgr->GetItemSize(ItemDefID, bRotated);
}

bool UInventoryGridComponent::MoveItem(FGuid ItemInstanceID, FIntPoint NewPosition, bool bNewRotated)
{
	// 1. 查找物品
	FInventoryItemPlacement* Placement = Items.Find(ItemInstanceID);
	if (!Placement)
	{
		UE_LOG(LogTemp, Warning, TEXT("[MoveItem] Item not found: %s"), *ItemInstanceID.ToString());
		return false;
	}

	// 2. 获取物品尺寸
	TOptional<FIntPoint> ItemSizeOpt = GetItemSize(Placement->Item.ItemDefID, bNewRotated);
	if (!ItemSizeOpt.IsSet())
	{
		UE_LOG(LogTemp, Error, TEXT("[MoveItem] Cannot get item size"));
		return false;
	}
	FIntPoint ItemSize = ItemSizeOpt.GetValue();

	// 3. 边界检查
	if (NewPosition.X < 0 || NewPosition.Y < 0 ||
		NewPosition.X + ItemSize.X > GridSize.X ||
		NewPosition.Y + ItemSize.Y > GridSize.Y)
	{
		UE_LOG(LogTemp, Warning, TEXT("[MoveItem] Out of bounds"));
		return false;
	}

	// 4. 区域检查
	if (Regions.Num() > 0)
	{
		int32 RegionIndex = FindRegionForPlacement(NewPosition, ItemSize);
		if (RegionIndex == INDEX_NONE)
		{
			UE_LOG(LogTemp, Warning, TEXT("[MoveItem] 物品跨区域或不在任何区域内"));
			return false;
		}
	}

	// 5. 检查新位置是否可用（忽略自己当前占用的格子）
	if (IsAreaOccupied(NewPosition, ItemSize, ItemInstanceID))
	{
		UE_LOG(LogTemp, Warning, TEXT("[MoveItem] Target position occupied"));
		return false;
	}

	// 6. 清除旧占用
	ClearGridOccupancy(ItemInstanceID);

	// 7. 标记新占用
	MarkGridOccupied(NewPosition, ItemSize, ItemInstanceID);

	// 8. 更新放置数据
	Placement->GridPosition = NewPosition;
	Placement->bIsRotated = bNewRotated;

	UE_LOG(LogTemp, Log, TEXT("[MoveItem] Item moved to (%d, %d), Rotated: %s"),
		NewPosition.X, NewPosition.Y,
		bNewRotated ? TEXT("Yes") : TEXT("No"));

	// 9. 广播变化事件
	OnInventoryChanged.Broadcast();

	return true;
}

TArray<FInventoryItemPlacement> UInventoryGridComponent::GetAllItems() const
{
	TArray<FInventoryItemPlacement> Result;
	Items.GenerateValueArray(Result);
	return Result;
}

bool UInventoryGridComponent::GetItemPlacement(FGuid ItemInstanceID, FInventoryItemPlacement& OutPlacement) const
{

	FString s;
	FName name;
	const FInventoryItemPlacement* Found = Items.Find(ItemInstanceID);
	if (Found)
	{
		OutPlacement = *Found;
		return true;
	}
	return false;
}

int32 UInventoryGridComponent::FindRegionForPlacement(FIntPoint Position, FIntPoint Size) const
{
	// 遍历所有区域，找到能完全容纳物品的区域
	for (int32 i = 0; i < Regions.Num(); ++i)
	{
		if (Regions[i].ContainsRect(Position, Size))
		{
			return i;
		}
	}

	// 没有找到合适的区域
	return INDEX_NONE;
}
