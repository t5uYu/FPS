# UGC 架构专业化评审与整改方案

> 评审日期：2026-09-10  
> 范围：`Source/FPS/UGC`、`Content/Script/Gameplay/UGC`、`Content/Script/System/UI/UGC`。  
> 定位：保留当前原型功能，不先重写全部 UI；优先建立稳定的数据、命令、执行和安全边界。

## 1. 总结判断

当前 UGC 是一套**验证能力很强、工程边界很弱**的原型。它已经贯通了场景编辑、预制体、撤销重做、节点图、触发器、PCG、LLM Function Calling 和存档，说明产品方向是成立的；但它不是“补几个 TODO 就能产品化”的状态。

真正的问题不是 Lua 多或代码写得长，而是以下对象没有分开：

- 文档数据与 World Actor；
- 业务命令与直接引擎调用；
- 图模型、图 UI 与图编译器；
- Authoring World 与 Playtest World；
- AI 提案与授权执行；
- Runtime 能力与桌面开发工具。

建议建立唯一主线：

```text
用户 / AI / 网络客户端
        |
        v
Command Request -> Policy + Validation -> Transaction / Command Bus
                                            |
                                            v
                                      UGC Document
                                            |
                                            v
                                      World Projection
                                            |
                                            v
                                      Unreal Actors
```

节点程序使用独立链路：

```text
Graph Document -> Typed Compiler -> Immutable IR -> Sandboxed VM + Scheduler
```

AI 只生成 Proposal，不应直接修改世界。

## 2. 量化现状

- 一方 UGC：39 个 C++/Lua 文件，约 8,811 行。
- Lua 模块级可变状态约 66 处。
- `pcall` 约 57 处，`collectgarbage` 5 处。
- 直接 `io.open` 11 处，`os.execute` 2 处。
- 硬编码 `/Game/` 路径约 22 处。
- C++ 暴露约 56 个 UFUNCTION。
- 未发现项目自有 UGC 自动化测试。

这些数字本身不是罪过，但集中出现在文档、Widget 生命周期和权限边界上，说明当前系统主要依靠运行时容错，而不是结构保证。

## 3. 值得保留的部分

- `EditorCore` 已有 Idle/Edit/Play 状态概念。
- `SceneData` 已意识到稳定 ID、Dirty、Undo/Redo、版本和 external metadata。
- `UGCFunctionRegistry` 已接近“能力目录 + Schema + Handler”。
- 批量生成器使用确定性 seed，适合重放与测试。
- 节点定义集中在 `UGCNodeRegistry`。
- C++ Bridge 的方向正确：封装 Lua 不方便直接调用的 Unreal 原子能力。
- PCG、TriggerZone、LLM、节点执行已有端到端验证。

整改应保留能力和 UX，只替换状态归属与执行边界。

## 4. 最高优先级结构问题

### 4.1 Widget 同时拥有图文档、ViewModel 和“编译器”

`WBP_UGCBlueprintEditor.lua` 同时维护 `_graphs`、活动图、节点数据、Widget/CanvasSlot 引用、拖拽、连线、保存和编译。关闭 Widget 后模块全局状态继续存在，并持有可能已被 UE GC 回收的 UObject，因此出现大量 `RemoveFromParent -> nil -> collectgarbage` 和 `pcall(IsValid)`。

**修正：**

- `FUGCGraphDocument`：只保存纯数据，禁止 UObject/Widget/CanvasSlot。
- `UUGCGraphViewModel`：选中、平移、缩放、拖拽等 UI 状态。
- Widget：Document 到 Node Widget 的一次性投影。
- `UGCGraphCompiler`：独立验证和编译，不依赖 Widget。

### 4.2 SceneData 是 God Object

`UGCSceneData.lua` 同时承担数据库、Actor 管理、脚本库、Undo/Redo、Batch、Dirty、序列化、PCG 重放和 Lua GC 管理。这会阻止多文档、多 World、多人 Session、后台加载和无 World 测试。

**修正为四层：**

1. `FUGCDocument`：纯数据与版本。
2. `UUGCDocumentSubsystem`：当前 Session 的 Document 生命周期与 Revision。
3. `FUGCCommandHistory`：事务和 Undo/Redo。
4. `UUGCWorldProjectionSubsystem`：`EntityId -> WeakObjectPtr<AActor>`。

Document 中不得保存 Actor 指针。

### 4.3 没有统一 Command Bus

UI、LLM、节点程序、PCG 都能直接 Spawn/Move/Delete/SetAttribute。Undo 只覆盖部分 Actor 操作，无法覆盖规则、程序、PCG 和组合操作。

**修正：所有写操作都变成 Command。**

建议基础结构：

- `FUGCCommandId`：FGuid。
- `FUGCEntityId`：FGuid。
- `FUGCCommandContext`：Author、Role、Source、BaseRevision。
- `FUGCCommandResult`：状态、错误码、事件、InverseCommand。
- `IUGCCommandHandler`：Validate、Execute、BuildInverse。

首批命令：CreateEntity、DeleteEntity、SetTransform、SetProperty、UpdateProgram、CreateGeneratedGroup、SetWorldRule。批量生成和 AI 修改使用 `CompositeCommand`，必须原子成功或回滚。

### 4.4 存档不具备事务性

当前 Widget 直接 `os.execute/io.open` 连续写 `scene.json`、`programs.json`、`editor.json`。中间失败会留下半套存档，加载也没有 Manifest、Checksum、备份和完整 Migration。

**修正：**

- Widget 只调用 `SaveDocument(Slot)` / `LoadDocument(Slot)`。
- 引入 `IUGCPersistenceProvider`。
- 不可变 Snapshot -> 临时文件 -> 校验重开 -> 原子 Rename。
- Manifest 包含 SchemaVersion、DocumentId、Revision、EngineVersion、ContentVersion、Checksums。
- 显式 Migration：V1 -> V2 -> V3。
- 自动保存、崩溃恢复、备份轮转归服务层。
- Runtime 使用 UE 文件/SaveGame/后端接口，不使用 shell 命令。

### 4.5 Prefab Catalog 依赖物理扫描 `.uasset`

PIE 下扫描 `Content/_UGC/Placeables/*.uasset` 在 pak/IoStore 中不可用，且开发者资产、语义 manifest、玩家自定义路径被混成一个 Registry。

**修正：**

- `UUGCPrefabDefinition : UPrimaryDataAsset`。
- ID 使用 `FPrimaryAssetId`。
- Definition 包含 ActorClass、DisplayName、CategoryTag、SearchTags、Bounds、Cost、AllowedModes、Version。
- AssetManager 扫描 Definition。
- 开发者 Catalog 与玩家内容 Provider 分离。
- 玩家内容必须经过导入、内容哈希与安全校验，禁止任意 BlueprintClass 路径。

### 4.6 节点“编译”实际只是 UI 校验

当前 Compile 只检查入口、可达性和 Branch 的 `condition_node`。运行器仍按字符串类型直接解释 Lua table：

- 无 Pin 类型系统、方向和连接基数校验；
- 无完整循环分析；
- 无不可变 IR；
- 无指令预算、取消和任务隔离；
- Delay 用 `seconds * 60` 近似帧数；
- Runtime Error 无法稳定映射回 Node/Pin；
- Interval 注册没有明确的 Preview 启动闭环。

**修正为 Compiler + VM：**

1. Normalize Graph。
2. Schema Validation。
3. Typed Pin Checking。
4. Control-flow Analysis。
5. Capability/Permission Validation。
6. Emit `FUGCCompiledProgram`。

VM 只执行 IR，不读取 Widget Graph。调度器使用真实时间、CancelToken、每帧指令预算、最大并发和确定性 seed。当前按钮在产出 IR 前应叫“验证”，不应叫“编译”。

### 4.7 LLM 客户端直连并直接执行世界修改

当前 APIKey 位于 Blueprint Defaults；客户端维护历史和 Tool Schema，模型返回 tool_calls 后直接调用 Registry Handler。

问题包括：

- Key 可能进入资产或构建产物；
- 客户端可伪造命令；
- 权限检查不一致；
- `grant_ability` 接受任意可加载 ClassPath，并非真正 allowlist；
- Tool Result 未再次发送模型形成完整 tool loop；
- 单一 `_onResult` 无 RequestId、并发、取消和超时模型；
- 无限流、预算、审计、幂等与用户确认。

**修正：AI 只生成 Proposal。**

```text
User Text
 -> AI Gateway / Server Proxy
 -> Structured Proposal {commands[], explanation, risk}
 -> Schema Validator
 -> Policy Engine / Quota
 -> Preview Diff
 -> User Approval（高风险/批量操作）
 -> Command Bus Transaction
 -> Tool Results
 -> Optional second model turn for final response
```

API Key 放服务端或受保护的本地开发设置。参数只能引用 PrefabId、EntityId、RuleId 等受控 ID，禁止任意 ClassPath。

### 4.8 网络模型基本缺失

UGC 修改没有统一 Server RPC、复制文档、Revision 或冲突控制，只适合单机原型。

即使短期只做单机，也应从一开始抽象：

- `LocalCommandTransport`：单机直接提交 Command。
- `ServerCommandTransport`：客户端请求，服务端验证、执行和广播结果。

Document 从第一版就带 Revision 和 CommandId，避免未来推倒重来。

### 4.9 UGCGameMode 继承错误

`AUGCGameMode` 继承 PVP `AFPSGameMode`，却使用 SpectatorPawn；它调用父类自定义 `HandleStartingNewPlayer`，仍会走分队和 FPS 出生逻辑。同时 FunctionBridge 又只支持 `AFPSCharacter`。

**修正：**

- Authoring：`AUGCAuthoringGameMode : AGameModeBase`。
- 编辑 Pawn：`AUGCEditorPawn`。
- Playtest：从 Document 创建不可变 Snapshot，进入独立 Preview World/关卡实例。
- 短期若同 World，至少由 SessionSubsystem 明确切换 EditorPawn 与 GameplayPawn 的 Possession。

### 4.10 Runtime 模块混入桌面开发能力

`FPS` Runtime 模块直接依赖 DesktopPlatform、ApplicationCore、HTTP、PCG、UMG/Slate；EditorBridge 包含原生文件对话框和磁盘资产扫描。Shipping、移动和主机边界不清晰。

**修正：**

- Runtime Core 不依赖 DesktopPlatform 或裸磁盘资产扫描。
- 文件对话框、开发扫描进入 Editor/Developer 模块。
- AI Provider 与 PCG 为可选模块。
- 运行时 UI 只依赖 UMG/SlateCore。

### 4.11 TriggerZone 直接依赖具体 PlayerController

TriggerZone 硬转 `AUGCPlayerController` 并调用 Lua NativeEvent，无法自然服务 NPC、服务器事件、不同 Pawn 或测试环境。

**修正：** TriggerZone 发布 `FUGCRuntimeEvent {EventTag, SourceEntityId, InstigatorId, Payload}`，由 `UUGCEventRouterSubsystem` 路由给 Program Runtime。

### 4.12 依靠大量 pcall 和强制 GC 维持生命周期

大量 `pcall` 用于吞掉失效 UObject 和 Widget 生命周期异常；强制 `collectgarbage` 被用于规避 TryBind 重入崩溃。这是 View 对象进入持久模型后的症状。

**修正：**

- Document 不存 UObject。
- ViewModel 使用弱引用，并在 Destruct 明确解绑。
- 异步任务持有 CancellationToken 与弱 Owner。
- 统一 Result/ErrorCode，不把错误吞成 nil。
- 独立日志分类、SessionId、CommandId、ProgramId。

## 5. 推荐目标模块

建议逐步建立独立插件 `FPSUGC`，至少拆为以下模块。

### FPSUGCCore（Runtime，无 World/UMG/HTTP）

- Document 类型；
- EntityId、ProgramId、Revision；
- Command、Result、ErrorCode；
- Graph Schema 和 IR 数据；
- 序列化 DTO/Migration；
- 纯逻辑 Validator。

该模块必须可以运行无 World 的自动化测试。

### FPSUGCRuntime（Runtime）

- `UUGCSessionSubsystem`；
- Command Bus 与 Policy；
- World Projection；
- Prefab Catalog；
- Event Router；
- Generated Group/PCG 生命周期；
- Local/Server Transport。

### FPSUGCScripting（Runtime）

- Node Registry；
- Compiler；
- Compiled Program；
- VM、Scheduler、Execution Budget；
- Debug Trace 与错误定位。

### FPSUGCUI（Runtime）

- UMG/Slate Views；
- Editor/Graph/Chat ViewModel；
- Selection 和 Tool State；
- 命令预览、Undo/Redo、错误列表。

UI 不直接 Spawn、Destroy 或写文件。

### FPSUGCAI（可选 Runtime Client + Server Service）

- Provider-neutral Request/Response；
- Proposal Schema；
- Policy/Quota；
- 完整 Tool Loop；
- RequestId、Cancel、Retry、Rate Limit、Audit；
- Server Proxy。

### FPSUGCDeveloper（Editor/Developer）

- 原生文件对话框；
- 开发资产发现和校验；
- Blueprint/Content Browser 工具；
- 文档检查器、迁移器、诊断面板。

## 6. 推荐核心数据模型

```text
FUGCDocument
  Header
    DocumentId: Guid
    SchemaVersion: int
    Revision: int64
    ContentVersion: string
  Entities: Map<Guid, FUGCEntityRecord>
  Programs: Map<Guid, FUGCGraphDocument>
  GeneratedGroups: Map<Guid, FUGCGeneratedGroupRecord>
  WorldSettings: FInstancedPropertyBag
```

`FUGCEntityRecord`：

- EntityId：FGuid；
- PrefabId：FPrimaryAssetId；
- Transform；
- Typed Property Bag；
- ProgramId：可选 Guid；
- Parent/Children：可选层级；
- Tags；
- Revision/LastModifiedBy。

Document 中禁止 Actor/UObject/Widget 指针。

## 7. 推荐关键流程

### 手动编辑

```text
Widget Event
 -> ViewModel::RequestMove
 -> SetTransformCommand
 -> Policy / Validation
 -> Command Transaction
 -> Document Mutation
 -> World Projection
 -> Domain Event
 -> UI Refresh
```

### AI 编辑

```text
Prompt -> Proposal -> Validate -> Preview -> Approve
       -> CompositeCommand -> Atomic Execute/Rollback -> Audit
```

### Playtest

```text
Authoring Document -> Immutable Snapshot -> Validate/Compile
 -> Preview World -> Runtime Projection -> Program VM
 -> End Preview and discard runtime mutations
```

### 保存

```text
Snapshot -> Validate -> Versioned Package -> Temp Write
 -> Checksum/Reopen -> Atomic Rename -> Backup Ring
```

## 8. 分阶段迁移

### Phase 0：止血与基线（2-4 天）

- “编译”按钮改名“验证”。
- Delay 改为真实秒 Scheduler。
- API Key 移出 Blueprint 资产。
- 明确单机或多人目标。
- 建 3 个 Golden Scene 和序列化回归测试。
- 为操作增加结构化日志。

### Phase 1：Document + Command Bus（1-2 周）

- 建纯数据 Document 和 Guid EntityId。
- 用 Adapter 包装旧 SceneData，保持 UI 暂时不改。
- Create/Delete/Transform/Batch 全走 Command。
- Undo/Redo 变成 Command + Inverse。
- Projection 独立维护 EntityId -> Actor。

这是最关键阶段。

### Phase 2：持久化 + Prefab Catalog（1 周）

- 单一版本化存档包、临时写入、原子提交、Migration。
- Prefab 改 PrimaryDataAsset + AssetManager。
- 删除 Runtime 对 `.uasset` 文件扫描、`os.execute/io.open` 的依赖。
- PCG Group 成为一等 Document Record。

### Phase 3：Graph Compiler + VM（2-3 周）

- Graph Model 从 Widget 移出。
- Typed Pin、连接约束、控制流验证、IR。
- 真实时间 Scheduler、取消、预算、错误定位。
- TriggerZone 改发 Event Router。
- Preview 启动时自动注册 Interval。

### Phase 4：AI 安全边界（1-2 周）

- Provider 抽象和服务端代理。
- Proposal/Preview/Approval。
- Allowlist、配额、审计、幂等 RequestId。
- Tool Result 回传模型，直到 Final Response 或达到步骤上限。

### Phase 5：UI 与多人（按产品目标）

- Editor/Graph UI ViewModel 化。
- 去除模块全局 UObject 和强制 GC workaround。
- 事件驱动刷新替代无条件 Tick。
- 若支持协作：Server Transport、Revision 冲突和增量事件复制。

## 9. 应删除或收敛的入口

- `UUGCFunctionBridge::ExecuteFunction`：当前是假入口，删除或接统一 Command Registry。
- `UGCPlaceableConfig.lua`：与动态 PrefabRegistry 重复，收敛为 Catalog。
- `Util.json`、`Gameplay.UGC.json`、`UGCSerialize`：至少文档持久化只保留一个经测试实现。
- `ScheduleCallback(frames)`：只用于 UI 下一帧，不用于脚本 Delay。
- Widget 中 `os.execute/io.open`：迁移后删除。

## 10. 验收标准

- 关闭 Widget 不影响 Document，不需强制 Lua GC。
- UI、AI、脚本、网络命令走同一验证/执行路径。
- 批量操作可原子回滚。
- 保存崩溃不会损坏上一个有效版本。
- Graph 执行前一定生成 IR，Runtime 不读取 Widget 数据。
- API Key 不在客户端资产和日志。
- AI 修改可预览、审计、重放。
- EntityId 在保存、加载、PCG 和网络后稳定。
- Runtime 可在无 DesktopPlatform 的 Shipping Target 编译。
- Core Document/Compiler/Command 可无 World 自动化测试。

## 11. 整改落地状态（2026-09-10）

### 已落地

- Pure `UGCDocument`：稳定 ID、Revision、Entities、Programs、GeneratedGroups、WorldSettings。
- `UGCCommandBus`：统一命令、动态 inverse、Undo/Redo、Composite 原子回滚和事件缓冲。
- `UGCWorldProjection`：Document 不再持有 Actor/UObject；触发区同步稳定 EntityId。
- `UGCPersistence + UUGCStorageBridge`：单一版本化 `*.ugc.json`、temp/verify/backup/rename，旧三文件格式只读兼容。
- Typed Graph Schema/Compiler/IR：Pin/参数/连接/循环/可达性验证；Runner 仅执行 IR，并使用真实 DeltaTime、任务取消和预算。
- AI Proposal：read-only 自动执行，write/high 需确认，带 baseRevision，完整 Tool Result 循环；任意资产路径被 allowlist 替代。
- `AUGCGameMode` 已从 `AFPSGameMode` 解耦；Controller 已具备 Authoring Pawn / Playtest Pawn 显式切换。
- TriggerZone 改为发布 `UUGCEventRouterSubsystem` 事件，不再直接依赖 `AUGCPlayerController`。
- C++ Bridge 写操作增加 Authority 检查；假 `ExecuteFunction` 删除；API Key 改为 `FPS_UGC_LLM_API_KEY`。
- DesktopPlatform 和磁盘 `.uasset` 扫描限制为 Editor 构建；Shipping 使用审核过的打包 Catalog。
- Graph Widget 的 UObject View 缓存与纯图数据分离，已移除 UGC 路径强制 `collectgarbage`。

### 验证结果

- 仓库 Lua 5.4.4 临时解释器对本次改动 Lua 全部 `loadfile` 通过。
- 纯 Lua 回归：Document/Command/Compiler 8 项、SceneData/Projection/External/WorldRule 7 项、Registry Policy 1 项、LLM Tool Loop 1 项、Persistence 1 项，全部通过。
- UE 5.7 临时兼容构建中 UHT 通过；本轮 UGC C++ translation units 均成功编译并生成 `UnrealEditor-FPS.lib`。
- 完整编辑器构建仍被既有第三方/工具兼容问题阻塞：UnLua 缺少 `DefaultParamCollection.inl`、Wwise 5.7 API 不兼容、UEEditorMCP `GetMaterialResource` 5.7 API 不兼容。项目目标版本仍是 UE 5.4。

### 尚未完成

- `UPrimaryDataAsset + AssetManager` Prefab Catalog 正式迁移。
- 多人 `ServerCommandTransport`、Revision 冲突解决、增量事件复制。
- Playtest 独立 World/关卡实例；当前先采用同 World 双 Pawn 生命周期。
- AI 服务端代理、配额、持久审计日志和可视化 Proposal 卡片。
- UE 5.4 Editor 内完整 PIE/Blueprint 资产验证。
