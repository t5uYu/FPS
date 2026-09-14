--[[
    UGCPropertySchema.lua

    T8：UGC 实体属性的类型 schema（数值 / 字符串 / 布尔 / 枚举 / 引用）。

    为什么需要 schema：
      properties 是自由字典，AI（LLM Function Calling）是主要写入方之一。没有类型约束时，模型把
      material 写成 "metel"、把 mass 写成 "heavy"、把引用写成不存在的 sceneID，都会静默写进存档，
      直到有人读的时候才发现。这里把校验收敛到一处，命令层与加载层共用。

    约定：
      * 键是白名单：未登记的键直接拒绝（拼错的键名正是最需要被抓住的情况）。
      * reference 类型只校验"形状"（正整数 sceneID），"指向的实体是否存在"由命令层校验，
        因为 schema 不持有文档。
      * Schema 是叶子模块（不 require 任何东西），Document / 命令层 / LLM 注册表都复用它。
]]

local Schema = {}

Schema.MAX_PROPERTIES = 16
Schema.MAX_STRING_LENGTH = 128

Schema.Definitions = {
    mass = {
        type = "number", min = 0, max = 10000,
        label = "质量(kg)",
    },
    note = {
        type = "string", maxLength = Schema.MAX_STRING_LENGTH,
        label = "备注",
    },
    lit = {
        type = "boolean",
        label = "是否点亮",
    },
    material = {
        type = "enum", values = { "Default", "Metal", "Wood", "Concrete", "Glass" },
        label = "材质",
    },
    team = {
        type = "enum", values = { "None", "TeamA", "TeamB" },
        label = "归属队伍",
    },
    link = {
        type = "reference", referenceKind = "entity",
        label = "关联实体(sceneID)",
    },
}

local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function enumContains(list, value)
    for _, candidate in ipairs(list) do
        if candidate == value then return true end
    end
    return false
end

--- 键是否已登记
function Schema.IsKnown(key)
    return type(key) == "string" and Schema.Definitions[key] ~= nil
end

--- 已登记键的排序列表（供 LLM enum 参数、UI 下拉使用）
function Schema.KeyList()
    local keys = {}
    for key in pairs(Schema.Definitions) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

function Schema.Definition(key)
    return Schema.Definitions[key]
end

function Schema.IsReference(key)
    local def = Schema.Definitions[key]
    return def ~= nil and def.type == "reference"
end

function Schema.ReferenceKeys()
    local keys = {}
    for key, def in pairs(Schema.Definitions) do
        if def.type == "reference" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
end

--- 类型校验（不做"引用是否存在"的判断）
--- @return boolean ok, string|nil err
function Schema.Validate(key, value)
    local def = Schema.Definitions[key]
    if not def then
        return false, string.format("未知属性键 %s（允许: %s）", tostring(key), table.concat(Schema.KeyList(), ", "))
    end

    if def.type == "number" then
        if not isFinite(value) then return false, string.format("属性 %s 必须是数值", key) end
        if def.min ~= nil and value < def.min then
            return false, string.format("属性 %s 不能小于 %s", key, tostring(def.min))
        end
        if def.max ~= nil and value > def.max then
            return false, string.format("属性 %s 不能大于 %s", key, tostring(def.max))
        end
        return true, nil
    end

    if def.type == "string" then
        if type(value) ~= "string" then return false, string.format("属性 %s 必须是字符串", key) end
        local limit = def.maxLength or Schema.MAX_STRING_LENGTH
        if #value > limit then
            return false, string.format("属性 %s 长度 %d 超过上限 %d", key, #value, limit)
        end
        return true, nil
    end

    if def.type == "boolean" then
        if type(value) ~= "boolean" then return false, string.format("属性 %s 必须是布尔值", key) end
        return true, nil
    end

    if def.type == "enum" then
        if type(value) ~= "string" then return false, string.format("属性 %s 必须是字符串枚举", key) end
        if not enumContains(def.values, value) then
            return false, string.format("属性 %s 的值 %s 不在允许列表（%s）", key, tostring(value), table.concat(def.values, ", "))
        end
        return true, nil
    end

    if def.type == "reference" then
        local sceneID = tonumber(value)
        if not sceneID or sceneID < 1 or sceneID % 1 ~= 0 then
            return false, string.format("属性 %s 必须引用一个正整数 sceneID", key)
        end
        return true, nil
    end

    return false, string.format("属性 %s 的类型 %s 未实现", key, tostring(def.type))
end

--- 把外部输入（LLM 传的都是字符串）按 schema 类型转成 Lua 值，再走 Validate。
--- @return value|nil, string|nil err
function Schema.Coerce(key, raw)
    local def = Schema.Definitions[key]
    if not def then
        return nil, string.format("未知属性键 %s（允许: %s）", tostring(key), table.concat(Schema.KeyList(), ", "))
    end

    local value = raw
    if def.type == "number" or def.type == "reference" then
        value = tonumber(raw)
        if value == nil then return nil, string.format("属性 %s 需要数值/整数 sceneID，收到 %s", key, tostring(raw)) end
        if def.type == "reference" then value = math.floor(value) end
    elseif def.type == "boolean" then
        if type(raw) == "boolean" then
            value = raw
        elseif raw == 1 or raw == "1" or raw == "true" then
            value = true
        elseif raw == 0 or raw == "0" or raw == "false" then
            value = false
        else
            return nil, string.format("属性 %s 需要布尔值，收到 %s", key, tostring(raw))
        end
    elseif def.type == "string" or def.type == "enum" then
        if type(raw) ~= "string" then
            if type(raw) == "number" then raw = tostring(raw) else
                return nil, string.format("属性 %s 需要字符串，收到 %s", key, tostring(raw))
            end
        end
        value = raw
    end

    local valid, err = Schema.Validate(key, value)
    if not valid then return nil, err end
    return value, nil
end

return Schema
