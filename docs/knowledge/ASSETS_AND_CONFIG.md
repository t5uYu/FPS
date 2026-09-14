# 资产、配置与工具链索引

## 1. 启动配置

- 引擎版本：UE 5.4。
- EditorStartupMap：`/Game/_FPS/Level/Level_MainMenu/Level_LoginMap.Level_LoginMap`
- GameDefaultMap：同上。
- GlobalDefaultGameMode：`/Game/_FPS/Blueprints/BP_MenuGameMode.BP_MenuGameMode_C`
- 默认输入：Enhanced Player Input + Enhanced Input Component。
- 渲染：DX12 SM6、Lumen/反射、Mesh Distance Fields、Virtual Shadow Maps。
- 自定义碰撞通道：`Projectile = ECC_GameTraceChannel1`。

## 2. 核心地图

- `Content/_FPS/Level/Level_MainMenu/Level_LoginMap.umap`
- `Content/_FPS/Level/Level_LoginMain/FirstPersonMap.umap`
- `Content/_FPS/Level/Level_Test/Level_Test.umap`
- `Content/_UGC/Level/UGC_Test/UGC_TestMap.umap`

其他 `Content/FPS`、`ShootingAI`、`StarterContent`、`SpaceshipInterior` 地图主要属于迁移素材、示例或场景资产。

## 3. 已确认的 Blueprint -> Lua 绑定

通过 `.uasset` 内嵌字符串离线确认：

- `BP_FPSPlayer` -> `Gameplay.Character.BP_FPSPlayer`
- `BP_FPSPlayerControll` -> `Gameplay.PlayerController`
- `BP_MenuPlayerController` -> `Gameplay.MenuPlayerController`
- `BP_WeaponBase` -> `Gameplay.Weapon.BP_WeaponBase`
- `BP_FPSProjectile` -> `Gameplay.Weapon.BP_FPSProjectile`
- `BP_UGCPlayerController` -> `Gameplay.UGC.UGCPlayerController`
- `WBP_MainMenu` -> `System.UI.Menu.WBP_MainMenu`
- `WBP_MapSelect` -> `System.UI.Menu.WBP_MapSelect`
- `WBP_PauseMenu` -> `System.UI.Menu.WBP_PauseMenu`
- `WBP_Settings` -> `System.UI.Menu.WBP_Settings`
- 库存 Widget -> `System.UI.Inventory.*`
- UGC Widget -> `System.UI.UGC.*`

这些确认不等于 Blueprint 图逻辑已完整验证。完整组件层级、默认字段和 Event Graph 需 UEEditorMCP 在线查询。

## 4. 核心资产域

### `_FPS`

- `Blueprints/`：游戏模式、玩家、控制器、输入。
- `Data/Items/DT_ItemDefinition`：物品表。
- `Data/Maps/DT_MapList`：地图表。
- `Data/Weapon/`：武器 DataAsset。
- `System/UI/`：菜单与库存 Widget。
- `Weapon/`：GAS abilities、damage GE、weapon/projectile Blueprint。

### `_UGC`

- `Blueprints/`：UGC GameMode 和 PlayerController。
- `Editor/Actor/`：三个 Gizmo。
- `Input/`：UGC 输入上下文和动作。
- `Level/UGC_Test/`：UGC 测试关卡。
- `Placeables/`：当前实际只有 Box、Sphere、TriggerZone 三个资产文件；`UGCPlaceableConfig.lua` 与 manifest 只登记这三个真实资产。
- `UI/`：编辑器、聊天、节点图。

## 5. 核心硬编码约定

### Socket

- 枪口：`Muzzle`
- 主手：`hand_r`
- 左手 IK：`LeftHandSocket`
- 背部：`weapon_back_1`、`weapon_back_2`

### GameplayTag

- `FPS.State.*`
- `FPS.Ability.Weapon.*`
- `FPS.Ability.Item.*`
- `FPS.Ability.Movement.*`
- `FPS.Effect.*`
- `FPS.Event.*`
- `FPS.Team.*`
- `FPS.Input.*`
- `GameplayCue.Weapon.Fire`

Tag 同时在 C++ Native 注册和 `DefaultGameplayTags.ini` 声明，修改时必须同步检查。

### UGC ID

- Actor ID：`actor_N`
- Actor program ID：`actor_prog_N`
- Level program ID：`level_main`
- Batch ID：`batch_N`


### UGC 本地密钥与存储

- LLM Key：进程环境变量 `FPS_UGC_LLM_API_KEY`；禁止写入 Blueprint Defaults、Config、日志和提交文件。
- `BP_UGCPlayerController.uasset` 中曾存在的 key-like 字符串已在 2026-09-10 原位抹除；必须在供应商侧轮换/吊销旧凭据。
- UGC JSON：`UUGCStorageBridge`；路径必须位于项目 `Saved/` 下，后缀仅允许 `.json`（存档本体）与 `.bak` / `.bakN`（备份轮转世代，T14 起放宽）；使用临时文件、重读校验、旧文件挪到 `.bak` 和 rename 提交。
- UGC JSON 编解码唯一实现：`Content/Script/Util/json.lua`（键序稳定、NaN/Inf -> `null`、失败返回 nil）；不要为存档再加第二个编解码器。
- `DesktopPlatform` 仅 Editor 构建依赖；Shipping 不提供原生文件对话框或磁盘 `.uasset` 扫描。

## 6. 插件

### 项目/工具插件

- `GamePlay 1.0`：Runtime，交互接口。
- `Web 1.0`：Runtime 空壳，当前未启用。
- `UEEditorMCP 0.1.0`：Editor-only，当前启用。
- `UnrealMCP 1.0`：旧 Editor 插件，当前禁用。

### 第三方

- UnLua 2.3.6。
- LuaProtobuf/LuaRapidjson/LuaSocket 1.0.0。
- Wwise 2024.1.8.8898.3839。

### `.uproject` 中显式启用

- ModelingToolsEditorMode（Editor）
- GameplayAbilities
- GamePlay
- EnhancedInput
- EditorScriptingUtilities
- UEEditorMCP（Editor）
- PCG / PCGExternalDataInterop / PCGGeometryScriptInterop

Wwise 插件描述为 EnabledByDefault。

## 7. 打包与脚本

`DefaultGame.ini`：

- 使用 Pak + IoStore。
- Oodle/Kraken 压缩。
- Stage `Content/Script`。
- Stage UnLua、LuaProtobuf、LuaSocket 脚本目录。
- Cook Wwise Tree/Types。

## 8. Wwise

- Wwise 工程：`FPS_WwiseProject/FPS_WwiseProject.wproj`
- 集成版本：2024.1.8.8898.3839。
- `SoundManager.lua` 已定义库存/武器事件名，但 Wwise Events Work Unit 当前几乎为空，代码中的事件名主要是占位契约。

## 9. 数据表转换

命令建议从工具目录运行：

```powershell
cd Tools/DataTableConverter
python converter.py
```

依赖：

- pandas >= 2.0
- openpyxl >= 3.1

当前只配置 `items`：

- 输入：`SourceData/Items.csv`
- 输出：`Output/CSV/DT_ItemDefinition.csv`
- 主键：`ItemID`

转换器会：

- 校验主键、尺寸、价格、库存和容器尺寸；
- 把 `CanRotate`/`IsContainer` 映射到 C++ 字段；
- 构造 UE Texture2D/Class 软引用字符串；
- 添加 DataTable 的 `---` Row Name 列。

## 10. UEEditorMCP

- 端口：55558。
- 客户端：`Plugins/UEEditorMCP/Python/ue_mcp_cli.py`
- Python Bridge：`ue_bridge.py`
- 统一 MCP 服务：`ue_editor_mcp/server_unified.py`
- 主要只读能力：
  - Blueprint summary/full description
  - 关卡 Actor 查询
  - 资产列表
  - PIE 状态
  - 编辑器日志
- Content Browser 的 Blueprint 右键菜单提供 `打开对应 Lua 文件`：反射调用 CDO 的 `GetModuleName`，映射到 `Content/Script/<module>.lua`，支持多选；源码编辑器不可用时回退系统默认编辑器。
- 实现位置：`Plugins/UEEditorMCP/Source/UEEditorMCP/Private/LuaAssetContextMenu.cpp`。
- 本次建立索引时端口不可连接。

## 11. 仓库体量

- `Content`：约 3,121 文件，约 4.30 GB。
- `Plugins`：约 7,901 文件，约 2.60 GB。
- `Source/FPS`：约 113 个 C++/Build 文件，约 13,034 行。
- `Content/Script`：46 个 Lua 文件，约 9,772 行。

大量体积来自 Wwise SDK、迁移素材和重复 StarterContent，不应成为普通功能开发的默认阅读范围。
