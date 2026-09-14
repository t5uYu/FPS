--[[
    Packaged UGC prefab catalog.

    This is the runtime-safe fallback until UUGCPrefabDefinition PrimaryDataAssets
    are introduced. Only assets that exist in the repository belong here.
    Editor-only discovery may add newly authored assets during PIE.
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
