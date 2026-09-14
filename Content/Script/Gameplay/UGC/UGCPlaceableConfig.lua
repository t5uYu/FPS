--[[
    Packaged UGC prefab catalog —— T5 之后这是**迁移期兜底**，不再是权威来源。

    权威来源是 AssetManager 里的 `UUGCPrefabDefinition`（PrimaryAssetId 形如 `UGCPrefab:Box`）：
    `UGCPrefabRegistry:LoadDynamic()` 先取 Definition 列表，只有「还没有 Definition」的 id 才会
    落到本文件；Editor 下再兜底扫描 Content/_UGC/Placeables 并报警「缺 Definition」。

    保留原因：旧存档 / 旧自定义 JSON / 未及改造的资产仍需要能跑起来；
    等所有 Placeable 都有 Definition 且 PIE 验收通过后，本文件可以删除
    （删除时同步删掉 UGCPrefabRegistry 里的 ⓪b 段与 Tools/UGCTests/run_prefab_definitions.lua 的兜底用例）。
]]

return {
    {
        id="Box", label="方块", category="基础几何体",
        path="/Game/_UGC/Placeables/BA_Placeable_Box.BA_Placeable_Box_C",
        description="基础掩体方块，可缩放做墙壁、障碍物或地板",
        tags={"掩体", "墙壁", "地板", "障碍物"},
    },
    {
        id="Sphere", label="球体", category="基础几何体",
        path="/Game/_UGC/Placeables/BA_Placeable_Sphere.BA_Placeable_Sphere_C",
        description="球形障碍物，可用作装饰或物理交互对象",
        tags={"装饰", "障碍物", "物理"},
    },
    {
        id="TriggerZone", label="触发区", category="关卡功能",
        path="/Game/_UGC/Placeables/BP_Placeable_TriggerZone.BP_Placeable_TriggerZone_C",
        description="进入或离开时向 UGC Event Router 发布运行时事件",
        tags={"触发", "脚本", "事件", "逻辑"},
    },
}
