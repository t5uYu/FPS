--[[
    UGCFunctionRegistry.lua
    UGC 函数注册表（Lua 单例）

    职责：
    - 维护所有可被 LLM / UnLua 白名单脚本调用的函数列表
    - 每个函数附带 Schema（供 LLM Function Calling 读取）
    - 通过 :Call(name, params) 统一分发执行
    - 通过 :GetSchemas() 导出 JSON 供 LLMGateway 使用

    新增函数只需在 Registry:Register() 区域加一段，无需改 C++。

    用法：
        local Registry = require("Gameplay.UGC.UGCFunctionRegistry")
        Registry:Init(playerController)
        Registry:Call("set_attribute", { name="Health", value=100 })
        Registry:GetSchemas()  -- 返回 JSON 字符串
]]

local Registry = {}
Registry.__index = Registry

--============================================================
-- 内部状态
--============================================================

local _pc     = nil   -- PlayerController
local _bridge = nil   -- UUGCFunctionBridge C++ 组件
local _funcs  = {}    -- name → { schema, func }

local function _getFabBridge()
    if not _pc then return nil, "PlayerController 未初始化" end

    local bridge = nil
    pcall(function()
        bridge = _pc:GetComponentByClass(UE.UFabClientBridge)
    end)
    if not bridge then
        return nil, "未找到 UFabClientBridge 组件"
    end
    local ok, loggedIn = pcall(function() return bridge:IsLoggedIn() end)
    if not ok or not loggedIn then
        return nil, "Fab 未登录，请先打开 Fab 面板登录"
    end
    return bridge, nil
end

local function _tagsToCsv(tags)
    if type(tags) == "table" then
        local out = {}
        for _, tag in ipairs(tags) do
            local s = tostring(tag or "")
            if s ~= "" then table.insert(out, s) end
        end
        return table.concat(out, ",")
    end
    return tostring(tags or "")
end

local function _findLocalAnimAsset(uuid, name)
    local Library = require("Gameplay.AnimAgent.AnimAssetLibrary")
    Library:Init()

    local normalizedUuid = tostring(uuid or "")
    normalizedUuid = normalizedUuid:gsub("^dyn:", "")
    normalizedUuid = normalizedUuid:gsub("^pkg:", ""):gsub(":main$", "")
    if normalizedUuid ~= "" then
        local hit = Library:Find(normalizedUuid)
        if hit then return hit end
    end

    local query = tostring(name or "")
    if query ~= "" then
        local list = Library:Search(query)
        if list and list[1] then return list[1] end
    end

    local all = Library:GetAll()
    return all and all[1] or nil
end

--============================================================
-- 初始化（在 PlayerController BeginPlay 里调用）
--============================================================

function Registry:Init(playerController)
    _pc     = playerController
    _bridge = playerController:GetUGCBridge()
    _funcs  = {}
    self:RegisterAll()
    print("[UGCRegistry] 初始化完成，已注册函数数量: " .. self:Count())
end

--============================================================
-- 注册单个函数
--============================================================

function Registry:Register(name, def)
    -- def = { desc, params, func }
    -- params = { { name, type, desc, required } }
    _funcs[name] = def
end

--============================================================
-- 函数注册区（新增函数在此添加）
--============================================================

function Registry:RegisterAll()

    -- --------------------------------------------------------
    -- 属性操作
    -- --------------------------------------------------------

    self:Register("set_attribute", {
        desc = "设置角色属性值。可修改的属性：Health（生命值）、MaxHealth（最大生命值）、Armor（护甲）、MovementSpeed（移速）、Stamina（体力）",
        params = {
            { name = "attribute", type = "string",  desc = "属性名，可选：Health / MaxHealth / Armor / MovementSpeed / Stamina", required = true },
            { name = "value",     type = "number",  desc = "目标数值", required = true },
        },
        func = function(p)
            if not p.attribute or p.value == nil then
                return false, "缺少参数 attribute 或 value"
            end
            local ok = _bridge:SetAttribute(tostring(p.attribute), tonumber(p.value))
            return ok, ok and "设置成功" or "属性名不合法或超出范围"
        end
    })

    self:Register("get_attribute", {
        desc = "读取角色当前属性值",
        params = {
            { name = "attribute", type = "string", desc = "属性名，可选：Health / MaxHealth / Armor / MovementSpeed / Stamina", required = true },
        },
        func = function(p)
            if not p.attribute then return false, "缺少参数 attribute" end
            local val = _bridge:GetAttribute(tostring(p.attribute))
            if val < 0 then return false, "属性名不合法" end
            return true, val
        end
    })

    -- --------------------------------------------------------
    -- GAS 技能操作
    -- --------------------------------------------------------

    self:Register("grant_ability", {
        desc = "动态授予角色一个 GAS 技能。技能类需在白名单内（BlueprintClass 路径）",
        params = {
            { name = "ability_path", type = "string", desc = "技能蓝图类路径，如 /Game/_FPS/GAS/GA_FireBall", required = true },
            { name = "level",        type = "number", desc = "技能等级，默认 1", required = false },
        },
        func = function(p)
            if not p.ability_path then return false, "缺少参数 ability_path" end
            local cls = UE.UClass.Load(tostring(p.ability_path))
            if not cls then return false, "找不到技能类: " .. tostring(p.ability_path) end
            local level = tonumber(p.level) or 1
            local ok = _bridge:GrantAbility(cls, level)
            return ok, ok and "技能授予成功" or "授予失败（可能已存在或非法类型）"
        end
    })

    self:Register("remove_ability", {
        desc = "移除角色身上指定技能",
        params = {
            { name = "ability_path", type = "string", desc = "技能蓝图类路径", required = true },
        },
        func = function(p)
            if not p.ability_path then return false, "缺少参数 ability_path" end
            local cls = UE.UClass.Load(tostring(p.ability_path))
            if not cls then return false, "找不到技能类: " .. tostring(p.ability_path) end
            local ok = _bridge:RemoveAbility(cls)
            return ok, ok and "技能移除成功" or "移除失败（技能不存在）"
        end
    })

    -- --------------------------------------------------------
    -- 武器操作
    -- --------------------------------------------------------

    self:Register("spawn_weapon", {
        desc = "在指定位置生成一把武器拾取物。WeaponID 对应 DT_ItemDefinition 中的行名",
        params = {
            { name = "weapon_id", type = "string", desc = "武器 ID，如 AK47、Glock", required = true },
            { name = "x",         type = "number", desc = "世界坐标 X（cm）", required = true },
            { name = "y",         type = "number", desc = "世界坐标 Y（cm）", required = true },
            { name = "z",         type = "number", desc = "世界坐标 Z（cm），默认 0", required = false },
        },
        func = function(p)
            if not p.weapon_id or p.x == nil or p.y == nil then
                return false, "缺少参数 weapon_id / x / y"
            end
            local loc = UE.FVector(tonumber(p.x), tonumber(p.y), tonumber(p.z) or 0)
            local actor = _bridge:SpawnWeapon(FName(tostring(p.weapon_id)), loc)
            return actor ~= nil, actor and "武器已生成" or "生成失败"
        end
    })

    -- --------------------------------------------------------
    -- 游戏规则
    -- --------------------------------------------------------

    self:Register("set_rule", {
        desc = "设置游戏规则参数。可修改：RoundTime（回合时长秒）、RespawnDelay（复活延迟秒）、FriendlyFire（友伤 0/1）、GravityScale（重力倍率）",
        params = {
            { name = "rule",  type = "string", desc = "规则名，可选：RoundTime / RespawnDelay / FriendlyFire / GravityScale", required = true },
            { name = "value", type = "number", desc = "目标值", required = true },
        },
        func = function(p)
            if not p.rule or p.value == nil then return false, "缺少参数 rule 或 value" end
            local ok = _bridge:SetGameRule(tostring(p.rule), tonumber(p.value))
            return ok, ok and "规则设置成功" or "规则名不合法或超出范围"
        end
    })

    self:Register("get_rule", {
        desc = "读取当前游戏规则值",
        params = {
            { name = "rule", type = "string", desc = "规则名，可选：RoundTime / RespawnDelay / FriendlyFire / GravityScale", required = true },
        },
        func = function(p)
            if not p.rule then return false, "缺少参数 rule" end
            local val = _bridge:GetGameRule(tostring(p.rule))
            if val < 0 then return false, "规则名不合法" end
            return true, val
        end
    })

    -- --------------------------------------------------------
    -- 场景操作（放置 / 移动 / 删除 Actor）
    -- --------------------------------------------------------

    self:Register("place_object", {
        desc = (function()
            local PrefabReg = require("Gameplay.UGC.UGCPrefabRegistry")
            local semantic = PrefabReg:GetSemanticDesc()
            if semantic and semantic ~= "" then
                return "在场景中放置一个预制体 Actor。可用预制体及说明：" .. semantic
            end
            return "在场景中放置一个预制体 Actor。可用预制体：Box、Sphere、Cylinder、Ramp、SpawnPoint、ExtractionZone、TriggerZone、WeaponSpawn"
        end)(),
        params = {
            { name = "prefab", type = "string", desc = "预制体名称，区分大小写", required = true },
            { name = "x",      type = "number", desc = "世界坐标 X（cm）",      required = true },
            { name = "y",      type = "number", desc = "世界坐标 Y（cm）",      required = true },
            { name = "z",      type = "number", desc = "世界坐标 Z（cm），默认 0", required = false },
            { name = "yaw",    type = "number", desc = "绕 Z 轴旋转角度（度），默认 0", required = false },
            { name = "pitch",  type = "number", desc = "绕 Y 轴旋转角度（度），默认 0", required = false },
            { name = "roll",   type = "number", desc = "绕 X 轴旋转角度（度），默认 0", required = false },
            { name = "scale_x", type = "number", desc = "X 轴缩放倍率，默认 1", required = false },
            { name = "scale_y", type = "number", desc = "Y 轴缩放倍率，默认 1", required = false },
            { name = "scale_z", type = "number", desc = "Z 轴缩放倍率，默认 1", required = false },
        },
        func = function(p)
            if not p.prefab or p.x == nil or p.y == nil then
                return false, "缺少参数 prefab / x / y"
            end
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local loc   = UE.FVector(tonumber(p.x), tonumber(p.y), tonumber(p.z) or 0)
            local rot   = UE.FRotator(tonumber(p.pitch) or 0, tonumber(p.yaw) or 0, tonumber(p.roll) or 0)
            local scale = UE.FVector(tonumber(p.scale_x) or 1, tonumber(p.scale_y) or 1, tonumber(p.scale_z) or 1)
            local transform = UE.UKismetMathLibrary.MakeTransform(loc, rot, scale)
            local sceneID, actor = SceneData:CreateActorWithTransform(tostring(p.prefab), transform)
            if not sceneID then
                -- fallback: 尝试旧接口（2026-04-16 兼容）
                sceneID, actor = SceneData:CreateActor(tostring(p.prefab), loc)
            end
            if not sceneID then
                return false, "放置失败，预制体名称可能不合法或场景已满"
            end
            return true, string.format("已放置 %s，场景 ID=%d，坐标=(%.0f,%.0f,%.0f) 旋转=(%.0f,%.0f,%.0f) 缩放=(%.1f,%.1f,%.1f)",
                p.prefab, sceneID, p.x, p.y, tonumber(p.z) or 0,
                tonumber(p.pitch) or 0, tonumber(p.yaw) or 0, tonumber(p.roll) or 0,
                tonumber(p.scale_x) or 1, tonumber(p.scale_y) or 1, tonumber(p.scale_z) or 1)
        end
    })

    self:Register("move_object", {
        desc = "移动场景中已有的 Actor 到新坐标。scene_id 从 list_objects 获取。保留原有旋转和缩放",
        params = {
            { name = "scene_id", type = "number", desc = "Actor 的场景 ID（整数）", required = true },
            { name = "x",        type = "number", desc = "目标坐标 X（cm）",       required = true },
            { name = "y",        type = "number", desc = "目标坐标 Y（cm）",       required = true },
            { name = "z",        type = "number", desc = "目标坐标 Z（cm）",       required = false },
        },
        func = function(p)
            if p.scene_id == nil or p.x == nil or p.y == nil then
                return false, "缺少参数 scene_id / x / y"
            end
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local entry = SceneData:QueryActor(tonumber(p.scene_id))
            if not entry then
                return false, "找不到 scene_id=" .. tostring(p.scene_id)
            end
            -- 保留原有的 rotation 和 scale（2026-04-16 修复：不再重置为默认值）
            local EditorBridge = require("Gameplay.UGC.UGCEditorCore"):GetBridge()
            local origRot   = UE.FRotator(0, 0, 0)
            local origScale = UE.FVector(1, 1, 1)
            if EditorBridge and entry.actor then
                local origT = EditorBridge:GetActorTransform(entry.actor)
                local _, r, s = UE.UKismetMathLibrary.BreakTransform(origT)
                origRot   = r
                origScale = s
            end
            local loc = UE.FVector(tonumber(p.x), tonumber(p.y), tonumber(p.z) or 0)
            local newT = UE.UKismetMathLibrary.MakeTransform(loc, origRot, origScale)
            local ok = SceneData:ModifyActor(tonumber(p.scene_id), newT)
            return ok, ok and string.format("Actor %d 已移动到 (%.0f,%.0f,%.0f)",
                p.scene_id, p.x, p.y, tonumber(p.z) or 0) or "移动失败"
        end
    })

    self:Register("delete_object", {
        desc = "删除场景中指定 ID 的 Actor。scene_id 从 list_objects 获取",
        params = {
            { name = "scene_id", type = "number", desc = "Actor 的场景 ID（整数）", required = true },
        },
        func = function(p)
            if p.scene_id == nil then return false, "缺少参数 scene_id" end
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local ok = SceneData:DeleteActor(tonumber(p.scene_id))
            return ok, ok and "Actor " .. tostring(p.scene_id) .. " 已删除" or "删除失败，ID 不存在"
        end
    })

    self:Register("list_objects", {
        desc = "列出场景中所有已放置的 Actor，返回每个的 scene_id、预制体名称和坐标",
        params = {},
        func = function(p)
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local EditorBridge = require("Gameplay.UGC.UGCEditorCore"):GetBridge()
            local lines = {}
            SceneData:ForEach(function(entry)
                local x, y, z = 0, 0, 0
                if EditorBridge and entry.actor then
                    local t = EditorBridge:GetActorTransform(entry.actor)
                    local loc, _, _ = UE.UKismetMathLibrary.BreakTransform(t)
                    x, y, z = loc.X, loc.Y, loc.Z
                end
                table.insert(lines, string.format("ID=%d prefab=%s pos=(%.0f,%.0f,%.0f)",
                    entry.sceneID, tostring(entry.prefabName), x, y, z))
            end)
            if #lines == 0 then return true, "场景为空" end
            return true, table.concat(lines, "\n")
        end
    })

    -- --------------------------------------------------------
    -- PCG 过程化内容生成（2026-04-16 新增）
    -- --------------------------------------------------------

    self:Register("pcg_generate", {
        desc = "在指定位置执行 PCG 过程化内容生成（自动散布掩体/装饰物群）。需要 UGCPCGBridge 组件和配置好的 PCG Graph 资产",
        params = {
            { name = "x",      type = "number", desc = "生成中心 X 坐标（cm）", required = true },
            { name = "y",      type = "number", desc = "生成中心 Y 坐标（cm）", required = true },
            { name = "z",      type = "number", desc = "生成中心 Z 坐标（cm），默认 0", required = false },
            { name = "radius", type = "number", desc = "生成半径（cm），默认 1000", required = false },
            { name = "seed",   type = "number", desc = "随机种子，0 = 随机", required = false },
            { name = "graph_path", type = "string", desc = "PCG Graph 资产路径，空 = 使用默认", required = false },
        },
        func = function(p)
            if p.x == nil or p.y == nil then
                return false, "缺少参数 x / y"
            end
            local pcgBridge = _pc:GetUGCPCGBridge()
            if not pcgBridge then
                return false, "PCG Bridge 组件不可用"
            end
            local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z) or 0
            local loc = UE.FVector(x, y, z)
            local radius = tonumber(p.radius) or 0
            local seed = tonumber(p.seed) or 0
            local graphPath = tostring(p.graph_path or "")
            local actor = pcgBridge:Generate(loc, radius, seed, graphPath)
            if not actor then
                return false, "PCG 生成失败，请检查 PCG Graph 配置"
            end
            -- 登记到 SceneData，让保存/加载和场景清空能感知 PCG 生成物
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local sceneID = SceneData:RegisterExternalActor(actor, "PCG_Generated", {
                kind       = "pcg",
                x          = x,
                y          = y,
                z          = z,
                radius     = radius,
                seed       = seed,
                graph_path = graphPath,
            })
            return true, string.format("PCG 生成完成 SceneID=%s 中心=(%.0f,%.0f,%.0f) 半径=%.0f",
                tostring(sceneID), x, y, z, radius > 0 and radius or 1000)
        end
    })

    self:Register("pcg_clear", {
        desc = "清除所有 PCG 过程化生成的内容",
        params = {},
        func = function(p)
            local pcgBridge = _pc:GetUGCPCGBridge()
            if not pcgBridge then
                return false, "PCG Bridge 组件不可用"
            end
            local count = pcgBridge:GetActiveCount()
            pcgBridge:CleanupAll()
            -- 同步移除 SceneData 中的 PCG 条目（Actor 已被 Bridge 销毁）
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            SceneData:UnregisterExternalByKind("pcg")
            return true, "已清除 " .. count .. " 个 PCG 生成组"
        end
    })

    -- --------------------------------------------------------
    -- 场景生成器（2026-04-17 新增）
    -- 暴露给 LLM：generate_<name>（每个生成器一个独立函数）+ list_generators + delete_batch
    -- --------------------------------------------------------

    self:Register("list_generators", {
        desc = "列出所有可用的批量场景生成器（CoverField/Room/Wall 等），返回名字+一句中文描述+必填参数。在调用 generate_xxx 之前先用此函数了解能力。",
        params = {},
        func = function(p)
            local Generators = require("Gameplay.UGC.Generators.Init")
            local list = Generators:GetSchemas()
            if #list == 0 then return true, "（暂无注册的生成器）" end
            local lines = {}
            for _, g in ipairs(list) do
                local req = {}
                for _, pa in ipairs(g.params or {}) do
                    if pa.required then req[#req+1] = pa.name end
                end
                table.insert(lines, string.format("- %s: %s [必填: %s]",
                    g.name, g.desc or "", table.concat(req, ",")))
            end
            return true, table.concat(lines, "\n")
        end
    })

    self:Register("delete_batch", {
        desc = "按 batch_id 整批删除某次生成器调用产生的所有 Actor",
        params = {
            { name="batch_id", type="string", desc="generate_xxx 返回结果中的 batch_id", required=true },
        },
        func = function(p)
            if not p.batch_id then return false, "缺少 batch_id" end
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local n = SceneData:DeleteBatch(tostring(p.batch_id))
            return true, string.format("已删除 batch %s，共 %d 个 Actor", p.batch_id, n)
        end
    })

    self:Register("list_batches", {
        desc = "列出当前所有由生成器创建的 batch（id 与每批数量），方便挑选要清理的批次",
        params = {},
        func = function(p)
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local batches = SceneData:ListBatches()
            if #batches == 0 then return true, "（无活跃 batch）" end
            local lines = {}
            for _, b in ipairs(batches) do
                table.insert(lines, string.format("- %s（%d 个）", b.id, b.count))
            end
            return true, table.concat(lines, "\n")
        end
    })

    -- --------------------------------------------------------
    -- 跨调用 batch（2026-04-17 新增）
    -- 用法：begin_batch("city_block") → 多次原子调用 → end_batch()
    -- 期间所有原子/生成器产出 Actor 都会归到同一个 batchID，便于一键删除
    -- --------------------------------------------------------

    self:Register("begin_batch", {
        desc = "开启一个具名 batch：之后的 scatter_* / place_* / build_* / generate_* 调用会共享同一个 batch_id。完成后用 end_batch 关闭。同名重复调用将复用旧 ID。",
        params = {
            { name="name", type="string", desc="自定义 batch 名（如 city_block / forest_a）", required=true },
        },
        func = function(p)
            if not p.name then return false, "缺少 name" end
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local id = SceneData:BeginNamedBatch(tostring(p.name))
            return true, "已开启 batch: " .. id .. "（后续调用都会归到此 batch）"
        end
    })

    self:Register("end_batch", {
        desc = "关闭当前 active batch。之后的原子/生成器调用会各自创建独立 batch。",
        params = {},
        func = function(p)
            local SceneData = require("Gameplay.UGC.UGCSceneData")
            local id = SceneData:EndActiveBatch()
            if id then return true, "已关闭 batch: " .. id end
            return true, "（无 active batch）"
        end
    })

    -- --------------------------------------------------------
    -- Fab 平台操作（异步提交）
    -- --------------------------------------------------------

    self:Register("fab_publish_local_asset", {
        desc = "把 UE 本地 AnimAgent/Fab 动态 GLB 资产发布到 Fab 资产平台。可传 uuid 精确发布；不传 uuid 时可按 name 搜索，仍为空则发布最近一个本地资产。该操作异步提交，完成结果见 UE 日志 LogFabClient。",
        params = {
            { name = "uuid",        type = "string", desc = "本地资产 uuid，可带 dyn: 前缀；可选", required = false },
            { name = "name",        type = "string", desc = "发布名称；也可用于搜索本地资产", required = false },
            { name = "description", type = "string", desc = "资产描述", required = false },
            { name = "tags",        type = "string", desc = "英文逗号分隔标签，如 weapon,ugc,ai", required = false },
        },
        func = function(p)
            local bridge, err = _getFabBridge()
            if not bridge then return false, err end

            local item = _findLocalAnimAsset(p.uuid, p.name)
            local uploadPath = item and (item.glb_path or item.source_path or item.manifest_path) or ""
            if not item or uploadPath == "" then
                return false, "未找到可发布的本地 UGC 资产"
            end

            local publishName = tostring(p.name or "")
            if publishName == "" then publishName = item.name or ("UE资产-" .. tostring(item.uuid or "")) end

            local desc = tostring(p.description or "")
            if desc == "" then desc = item.prompt or "" end

            local tags = _tagsToCsv(p.tags)
            if tags == "" then tags = _tagsToCsv(item.tags) end

            bridge:UploadModelSimple(publishName, uploadPath, desc, tags)
            return true, string.format("已提交 Fab 发布：%s path=%s（异步完成看 LogFabClient / OnUploadCompleted）",
                publishName, tostring(uploadPath))
        end
    })

    self:Register("fab_create_ai_model", {
        desc = "在 Fab 平台创建 Meshy 文生 3D 模型任务。任务完成后服务端会沉淀为 Fab 资产，之后可在 Fab 面板下载添加到 Project。",
        params = {
            { name = "prompt", type = "string", desc = "文生 3D 提示词", required = true },
            { name = "mode",   type = "string", desc = "生成模式，可选；默认 preview", required = false },
        },
        func = function(p)
            if not p.prompt or tostring(p.prompt) == "" then
                return false, "缺少 prompt"
            end
            local bridge, err = _getFabBridge()
            if not bridge then return false, err end

            local mode = tostring(p.mode or "")
            if mode == "" then mode = "preview" end
            bridge:CreateAiTextTaskSimple(tostring(p.prompt), mode)
            return true, "已提交 Fab AI 文生模型任务，稍后用 fab_check_ai_task 查询状态"
        end
    })

    self:Register("fab_create_ai_model_from_image", {
        desc = "在 Fab 平台创建 Meshy 图生 3D 模型任务。输入必须是可公网访问的图片 URL。",
        params = {
            { name = "image_url", type = "string", desc = "公网图片 URL", required = true },
            { name = "mode",      type = "string", desc = "生成模式，可选；默认 preview", required = false },
        },
        func = function(p)
            if not p.image_url or tostring(p.image_url) == "" then
                return false, "缺少 image_url"
            end
            local bridge, err = _getFabBridge()
            if not bridge then return false, err end

            local mode = tostring(p.mode or "")
            if mode == "" then mode = "preview" end
            bridge:CreateAiImageTaskSimple(tostring(p.image_url), mode)
            return true, "已提交 Fab AI 图生模型任务，稍后用 fab_check_ai_task 查询状态"
        end
    })

    self:Register("fab_check_ai_task", {
        desc = "查询 Fab AI 生成任务状态。返回结果会写入 UE 日志 LogFabClient，并通过 OnAiTaskCompleted 多播。",
        params = {
            { name = "task_id", type = "number", desc = "Fab AI 任务 ID", required = true },
        },
        func = function(p)
            if p.task_id == nil then return false, "缺少 task_id" end
            local bridge, err = _getFabBridge()
            if not bridge then return false, err end

            bridge:GetAiTaskSimple(tonumber(p.task_id))
            return true, "已提交任务状态查询，结果见 LogFabClient / OnAiTaskCompleted"
        end
    })

    -- 把 Generators 注册表里所有 Gen_* 自动暴露成 generate_<name> 函数
    local Generators = require("Gameplay.UGC.Generators.Init")
    Generators:ExportFunctions(self)
    -- 把 Atoms 也以独立函数形式暴露给 LLM（scatter_box / place_grid / place_at / ...）
    Generators:ExportAtomsAsFunctions(self)

end

--============================================================
-- 执行函数
--============================================================

function Registry:Call(name, params)
    local def = _funcs[name]
    if not def then
        print("[UGCRegistry] 未知函数: " .. tostring(name))
        return false, "未知函数: " .. tostring(name)
    end
    if not _bridge then
        print("[UGCRegistry] Bridge 未初始化")
        return false, "Bridge 未初始化"
    end

    local ok, r1, r2 = pcall(def.func, params or {})
    if not ok then
        print("[UGCRegistry] 执行出错: " .. tostring(r1))
        return false, "执行异常: " .. tostring(r1)
    end
    return r1, r2
end

--============================================================
-- 导出 Schema（供 LLM 读取）
-- OpenAI / DeepSeek Function Calling 格式：
-- [{"type":"function","function":{"name":...,"description":...,"parameters":{...}}}]
--============================================================

function Registry:GetSchemas()
    local parts = {}
    for name, def in pairs(_funcs) do
        local paramParts = {}
        local required = {}
        for _, p in ipairs(def.params or {}) do
            table.insert(paramParts, string.format(
                '"%s":{"type":"%s","description":"%s"}',
                p.name, p.type, p.desc
            ))
            if p.required then
                table.insert(required, '"' .. p.name .. '"')
            end
        end
        table.insert(parts, string.format(
            '{"type":"function","function":{"name":"%s","description":"%s","parameters":{"type":"object","properties":{%s},"required":[%s]}}}',
            name,
            def.desc,
            table.concat(paramParts, ","),
            table.concat(required, ",")
        ))
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

--============================================================
-- 工具
--============================================================

function Registry:Count()
    local n = 0
    for _ in pairs(_funcs) do n = n + 1 end
    return n
end

function Registry:ListFunctions()
    local names = {}
    for name in pairs(_funcs) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

return Registry
