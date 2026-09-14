# 风险、断链与未完成项

> 这是“导航和验证清单”，不是已修复列表。修改前先重新确认对应 Blueprint Defaults/关卡配置。

## P0/P1：优先确认

### 1. PlayerState 上的 AttributeSet 死亡状态可能无法跨重生复位

- `UFPSCombatAttributeSet::bDead` 在死亡后置 true。
- ASC/AttributeSet 位于持久化的 PlayerState。
- `AFPSGameMode::RespawnPlayer` 重新生成 Pawn。
- `AFPSCharacter::ResetForRespawn` 只重置 Character 的 `bDead`，没有重置 AttributeSet 私有 `bDead`。

风险：首次死亡后，新 Pawn 仍使用旧 AttributeSet，后续伤害/治疗和死亡事件可能失效。建议为 AttributeSet 提供显式 Reset，并定义重生时 Ability/Effect 的清理策略。

### 2. 重生可能重复授予默认能力/效果

新 Character 每次 `InitializeAbilitySystem` 都会向 PlayerState ASC 授予 `DefaultAbilities` 和应用 `DefaultEffects`。如果旧能力/效果未清理，会重复叠加。

### 3. 武器弹药和状态没有复制

`AFPSWeaponBase` 复制 Actor 和 `InstalledAttachmentIDs`，但 `AmmoInfo`、`CurrentState` 未复制。客户端预测会本地扣弹，服务端也扣弹，但没有权威校正/OnRep。

风险：丢包、拒绝 RPC、延迟或 Reload 时可能出现 HUD 与服务端不同步。

### 4. 双护甲模型可能重复减伤

- Projectile Lua 按 `UFPSArmorComponent` 的 ArmorLevel/Durability 计算肉伤和甲伤。
- `UFPSCombatAttributeSet::HandleDamage` 又按 GAS `Armor` 与 `ArmorReduction` 吸收伤害。

若两套 Armor 同时有值，伤害可能二次减免。应明确一个模型负责“穿透与耐久”，另一个是否仍代表可消耗护盾。

### 5. UGC Authoring / Playtest 生命周期（已完成基础拆分，待 PIE）

- `AUGCGameMode` 已改为直接继承 `AGameModeBase`，不再进入 PVP 分队、比赛计时和复活流程。
- Authoring 默认使用 SpectatorPawn；进入 Play 时 `AUGCPlayerController` 生成并 Possess `BP_FPSPlayer`，返回 Edit 时恢复 Authoring Pawn。
- `PlayerStateClass` 显式保留 `AFPSPlayerState`，使 Playtest Pawn 可获得 ASC/AttributeSet。
- 仍需 UE 5.4 PIE 验证输入映射、摄像机位置、重复切换与 GAS 默认能力/Effect 是否出现累加。

## P1：资产和运行路径断链

机器检查发现以下硬编码引用在仓库中不存在：

- C++ GameMode fallback Pawn：`/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter`
- PlayerController 返回菜单：`/Game/_FPS/Level/Level_MainMenu`
- C++ MenuSubsystem 配置：`/Game/_FPS/Data/DA_MenuConfig`
- Lua UI：`/Game/_FPS/System/UI/WBP_HUD`
- Lua UI：`/Game/_FPS/System/UI/Menu/WBP_Loadout`
- GM 调试武器：`/Game/_FPS/Blueprints/Weapons/BP_Rifle`
- GM 调试手枪：`/Game/_FPS/Blueprints/Weapons/BP_Pistol`
- UGC Placeable：Cylinder、Ramp、SpawnPoint、Extraction、WeaponSpawn

补充：

- 实际主菜单地图文件是 `.../Level_MainMenu/Level_LoginMap.umap`。
- 实际玩家 Blueprint 是 `Content/_FPS/Blueprints/BP_FPSPlayer.uasset`。
- `BP_FPSGameMode` 很可能在 Blueprint Defaults 覆盖了 C++ fallback，但未在线读取 CDO 验证。

### 6. UI 有两套独立状态栈

- C++：`UFPSMenuSubsystem`
- Lua：`Gameplay.Core.UIManager`

当前 Blueprint/Lua 绑定显示主要运行路径是 Lua UIManager；C++ Widget 默认动作却会调用 MenuSubsystem。两边各自持有打开窗口、栈和输入模式，可能造成状态不一致。

### 7. 后坐力有两套并行实现

- `UGA_WeaponFire` 每发推进 `UFPSRecoilComponent`。
- `AFPSWeaponBase::Fire` 又调用可被 Lua 覆盖的 `OnShotFired`。
- `BP_WeaponBase.lua` 用自己的 `_PatternIndex` 和 JSON 计算实际方向。
- HUD 展示读取 C++ `RecoilComponent.CurrentSpread`。

风险：准星显示与实际弹道不一致；配置来源分裂为 RecoilProfile 与 JSON。

### 8. 配件复制未完成重建

`OnRep_InstalledAttachments` 只清空 `CachedAttachmentData`，注释说应通过 AssetManager 重建，但未实现。因此客户端：

- `GetAttachment` 返回空；
- 有效伤害/装弹时间/弹匣容量无法从复制 ID 恢复；
- 配件 Mesh 展示逻辑也未见实现。

### 9. 击杀/助攻归因需联网实测

AttributeSet 使用 `EffectContext.GetEffectCauser()` 并要求可转为 `AFPSCharacter`；Projectile 创建上下文时只显式 `AddSourceObject(this)`。需验证 EffectCauser 在当前 GAS 路径是否确实为攻击者 Character，否则 DamageDealt、助攻和 Killer 可能为空。

## P2：UGC 数据一致性

以下原问题已在 2026-09-10 的兼容式重构中处理：

- PCG external entity 使用稳定 SceneID/EntityId，并通过 external adapter 支持恢复、清理、Undo/Redo。
- 删除实体会保留并恢复 Program 与 GeneratedGroup 归属。
- Ability/Weapon/Attribute/Rule/PCG Graph 改用共享 allowlist；AI 不再接受任意 Ability 或 PCG 资产路径。
- API Key 改从 `FPS_UGC_LLM_API_KEY` 环境变量读取；Blueprint 中检测到的旧 key-like 值已抹除，旧凭据仍必须在供应商侧吊销/轮换。
- `UUGCFunctionBridge::ExecuteFunction` 假入口已删除；Delay/Interval 改为真实 DeltaTime Scheduler。
- Runtime UGC Lua 路径已移除 `io.open`、`os.execute` 和 `collectgarbage`；JSON IO 统一经 `UUGCStorageBridge`。

仍需关注：

- `UGCPlaceableConfig.lua` 目前是过渡性打包 Catalog；最终仍建议迁移为 `UPrimaryDataAsset + AssetManager`。
- AI 多写 Tool Call 当前被拒绝，要求模型改用单个原子生成器；未来若需任意多命令提案，应增加统一 Proposal -> CompositeCommand 翻译层。
- Document/Command/Compiler 已有纯 Lua 回归，但完整加载、PCG、Trigger Router 与 Authoring/Playtest 仍需 UE 5.4 PIE 验证。

### 15. Android File Server SecurityToken 已提交

`Config/DefaultEngine.ini` 包含 `SecurityToken`。即使只是本地开发令牌，也应确认是否需要轮换或移出共享配置。

## P2/P3：功能未完成或漂移

- `AFPSGameMode::OnPlayerExtracted` 仅日志，Raid 完成/保存/结算未接通。
- MenuSubsystem 设置保存/加载、音频设置、主菜单关卡跳转未完成。
- Settings 的按键读取、应用、重置未完成。
- Inventory C++ 网格线绘制未完成。
- ContextMenu 的 Use/Equip/Drop/Split 多处仍是 TODO。
- `UPlayerInteractComponent` 的 Line/Cone 模式未实现。
- Wwise 事件名多为占位，Events Work Unit 基本为空。
- `Web` 插件为空壳且未启用。
- `README.pdf` 记载 `MinPlayersToStart=2`，代码当前为 1。
- `SourceData/Items.csv` 中文编码异常，`Output/CSV/DT_ItemDefinition.csv` 正常。
- C++ Native GameplayTags 与 INI 同时声明，存在双维护漂移。
- 仓库包含大量重复迁移素材与 StarterContent，搜索时容易命中错误副本。

## 构建与运行时依赖（T19 验证记录，2026-09-14）

本机只有 UE 5.7（项目目标 5.4），因此用 5.7 + 临时补丁做了一次 Shipping 构建探针，结论如下。

### 已修复

- `Source/FPS/Inventory/Private/InventoryGridComponent.cpp` 曾 `#include "IDetailTreeNode.h"`（Editor-only，且全文件未使用）。这一行会让 **Shipping/Game 目标直接编译失败**（`fatal error C1083`），已删除并就地留注释。这是本轮 Shipping 探针抓到的真实缺陷。
- `Tools/UGCTests/run_tests.ps1` 增加守卫：编辑器专用 include/符号（DesktopPlatform、IDetailTreeNode、PropertyEditor、UnrealEd、GEditor 等）必须位于 `#if WITH_EDITOR` 内；`FPS.Build.cs` 必须把 DesktopPlatform 放在 `Target.bBuildEditor` 后面。

### 依赖瘦身（FPS.Build.cs）

- `HTTP` / `Json` / `PCG` 只在 `UGCHttpClient.cpp`、`UGCPCGBridge.cpp` 内部使用 → 从 Public 移到 Private。
- 移除 `Niagara`（全模块零符号引用）与 `ApplicationCore`（无直接引用，Slate/UMG 自身公开传递）。
- `DesktopPlatform` 保持 editor-only；`AIModule` 必须保留（`FPSCharacter.h` 暴露 `IGenericTeamAgentInterface`，该头位于 AIModule）。
- 更深一层的"Runtime Core 只依赖 Core/CoreUObject/Engine"需要 T11 拆插件才能达成。

### 探针结果（UE 5.7，非项目目标版本）

- 通过：UBT 解析全部模块规则与 UHT 全量头文件解析；新增 `Source/FPS/UGC/UGCLog.cpp` 在 **Shipping** 配置下单文件编译成功（`-SingleFile`）。
- 阻塞（第三方，非本项目代码）：`Plugins/UnLua/Source/UnLua/Private/DefaultParamCollection.cpp` 依赖 UBT 插件生成的 `DefaultParamCollection.inl`；该插件是 net6.0，UE 5.7 的 UBT 只接受 net8.0，把它重定向到 net8.0 后又因 UHT API 变更（`UhtSession.Packages`、`UhtModule.ModuleType/Name/OutputDirectory` 已移除）编译失败。结论：**UE 5.7 下无法完整构建，与项目代码无关；最终 Shipping 验证必须在 UE 5.4 环境执行（并需要在该机器上装 .NET SDK）。**
- 探针用的临时改动（`FPS.uproject` 引擎关联、`FPS.Target.cs` 的 `bOverrideBuildEnvironment`、`UnLuaSettings.h` 的 `MetaClass`、UnLua collector 的 TFM）均已逐字节还原（SHA256 已校验）。

## 验证缺口

本次未启动 Unreal Editor，UEEditorMCP 55558 端口不可连接，因此以下内容仍需编辑器内验证：

- Blueprint 的实际父类、CDO 默认属性与组件引用。
- 各地图 World Settings/GameMode Override。
- DataTable 的实际行值。
- Widget Designer 中 BindWidget 名称完整性。
- Blueprint 编译状态和资源重定向器。
- PIE 双客户端的 RPC、复制、重生和 UI 状态。
