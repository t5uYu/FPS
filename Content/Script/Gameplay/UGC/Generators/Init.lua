--[[
    Generators/Init.lua
    场景生成器注册表 + 调度器（Lua 单例）

    职责：
    - 维护所有 Gen_*.lua 注册的生成器
    - Generate(name, params)：执行生成器，把生成点列表落到 SceneData，并归入一个 batch
    - ExportFunctions(targetRegistry)：把每个生成器以 generate_<name> 形式
      注册到 UGCFunctionRegistry，让 LLM Function Calling 直接看到独立函数

    每个 Gen_*.lua 模块需返回一个表，提供：
        M.Register(Generators)
            内部调 Generators.Register(name, def)
            def = {
              desc   = "对外说明",
              params = { {name,type,desc,required}, ... },
              func   = function(p) return { points = {...}, prefab = "Box" } end
            }

    生成器 func 应返回：
        { points = { {x,y,z[,yaw,pitch,roll,prefab]}, ... },
          prefab = "默认 prefab id（可被 point.prefab 覆盖）" }
]]

local SceneData = require("Gameplay.UGC.UGCSceneData")
local PrefabReg = require("Gameplay.UGC.UGCPrefabRegistry")

local M = {}

local _gens = {}   -- name → def

--============================================================
-- 注册接口（供 Gen_*.lua 调用）
--============================================================

function M.Register(name, def)
    if not name or not def or not def.func then
        print("[Generators] Register 失败：缺少 name/def/func")
        return
    end
    _gens[name] = def
end

function M.GetDef(name) return _gens[name] end

function M.List()
    local names = {}
    for k in pairs(_gens) do names[#names+1] = k end
    table.sort(names)
    return names
end

function M.GetSchemas()
    local list = {}
    for name, def in pairs(_gens) do
        list[#list+1] = { name = name, desc = def.desc, params = def.params }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

--============================================================
-- 执行
--============================================================

--- 调用指定生成器，把生成结果落到 SceneData
--- @return batchID(string) | nil, count(number) | errMsg(string)
function M:Generate(name, params, context)
    local def = _gens[name]
    if not def then
        return nil, "未知生成器: " .. tostring(name)
    end

    local ok, result = pcall(def.func, params or {})
    if not ok then
        return nil, "生成器异常: " .. tostring(result)
    end
    if type(result) ~= "table" or type(result.points) ~= "table" then
        return nil, "生成器返回格式错误（需要 {points={...}, prefab=...}）"
    end

    local default_prefab = result.prefab
    local points = result.points
    if #points == 0 then
        return nil, "生成 0 个点（参数可能太小或种子问题）"
    end

    local commands = {}
    local batchID = SceneData:AllocateBatchID()
    if not batchID then return nil, "SceneData 未初始化" end
    local skipCount = 0
    for _, p in ipairs(points) do
        local prefab = p.prefab or default_prefab
        if not prefab or not PrefabReg.IsValid(prefab) then
            skipCount = skipCount + 1
        else
            local transform = UE.UKismetMathLibrary.MakeTransform(
                UE.FVector(p.x or 0, p.y or 0, p.z or 0),
                UE.FRotator(p.pitch or 0, p.yaw or 0, p.roll or 0),
                UE.FVector(p.scale_x or 1, p.scale_y or 1, p.scale_z or 1))
            commands[#commands + 1] = {
                type="CreateEntity", prefabName=prefab,
                transform=require("Gameplay.UGC.UGCWorldProjection").ToData(transform),
                groups={batchID},
            }
        end
    end
    if #commands == 0 then return nil, "没有有效的生成点" end

    local result = SceneData:ExecuteComposite(commands, "Generate " .. tostring(name), context or {source="generator", approved=true})
    if not result.ok then return nil, result.message end

    local successCount = 0
    for _, childResult in ipairs(result.data or {}) do
        if childResult.ok and childResult.data and childResult.data.sceneID then
            successCount = successCount + 1
        end
    end

    print(string.format(
        "[Generators] %s → batch=%s 成功=%d 跳过=%d (无效prefab) 请求点数=%d",
        name, batchID, successCount, skipCount, #points))

    return batchID, successCount
end

--============================================================
-- LLM 函数导出
-- 把每个生成器以 generate_<name>（小写）注册到 UGCFunctionRegistry
--============================================================

function M:ExportFunctions(targetRegistry)
    if not targetRegistry or not targetRegistry.Register then
        print("[Generators] ExportFunctions: targetRegistry 不合法")
        return
    end
    local self_ = self
    for name, def in pairs(_gens) do
        local funcName = "generate_" .. string.lower(name)
        targetRegistry:Register(funcName, {
            desc   = "[场景生成器] " .. (def.desc or name),
            params = def.params or {},
            func   = function(p, context)
                local batchID, countOrErr = self_:Generate(name, p, context)
                if not batchID then
                    return false, "生成失败: " .. tostring(countOrErr)
                end
                return true, string.format(
                    "已生成 %d 个 Actor，batch_id=%s（用 delete_batch 整批清除）",
                    countOrErr, batchID)
            end,
        })
    end
    print(string.format("[Generators] 已导出 %d 个生成器为 LLM 函数", (function()
        local n = 0; for _ in pairs(_gens) do n = n + 1 end; return n
    end)()))
end

--============================================================
-- 自动加载所有 Gen_*.lua（顺序无关）
-- 新增生成器：在此追加一行 require
--============================================================

local function safeLoad(modPath)
    local ok, mod = pcall(require, modPath)
    if not ok then
        print("[Generators] 加载失败 " .. modPath .. ": " .. tostring(mod))
        return
    end
    if type(mod) == "table" and type(mod.Register) == "function" then
        mod.Register(M)
    else
        print("[Generators] " .. modPath .. " 未导出 Register 函数")
    end
end

safeLoad("Gameplay.UGC.Generators.Gen_CoverField")
safeLoad("Gameplay.UGC.Generators.Gen_Room")
safeLoad("Gameplay.UGC.Generators.Gen_Wall")

return M
