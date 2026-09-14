--[[
    WeaponBallisticsSchema.lua

    T17：武器弹道配置（Content/Data/WeaponBallistics.json）的唯一 schema 与校验实现。

    为什么单独成模块：
      * 编解码统一到 Util.json 之后，配置文件一旦写错（字段名拼错、数值写成字符串、数值越界）
        在运行时只会表现为"弹道不对"，很难定位。schema 把这类错误提前到加载期，并给出路径化报错。
      * 字段是白名单：未知字段直接拒绝，而不是静默忽略 —— 拼错的键名正是最需要被抓住的情况。

    数据结构（Schema.VERSION = 1）：
      {
        "<WeaponID>": {
          "recoil_pattern": [ [yaw, pitch], ... ],   -- 必填，>= 1 个点
          "random_spread_radius": number,            -- 可选，单位与 Pattern 一致（度），0 ~ 45
          "pattern_reset_time": number               -- 可选，秒，0.01 ~ 10
        }, ...
      }
]]

local Schema = {}

Schema.VERSION = 1
Schema.MAX_WEAPONS = 64
Schema.MAX_PATTERN_POINTS = 64
Schema.MAX_ANGLE = 180

Schema.LIMITS = {
    random_spread_radius = { min = 0, max = 45 },
    pattern_reset_time = { min = 0.01, max = 10 },
}

Schema.REQUIRED_FIELDS = { recoil_pattern = true }
Schema.OPTIONAL_FIELDS = { random_spread_radius = true, pattern_reset_time = true }
Schema.ALL_FIELDS = { "recoil_pattern", "random_spread_radius", "pattern_reset_time" }

local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function fail(path, message)
    return false, string.format("%s %s", path, message)
end

--- 校验单个武器条目
--- @return boolean ok, string|nil err
function Schema.ValidateEntry(weaponID, entry)
    local base = tostring(weaponID)
    if type(entry) ~= "table" then
        return fail(base, "必须是对象")
    end

    for field in pairs(entry) do
        if not Schema.REQUIRED_FIELDS[field] and not Schema.OPTIONAL_FIELDS[field] then
            return fail(base, "出现未知字段 " .. tostring(field)
                .. "（允许: " .. table.concat(Schema.ALL_FIELDS, ", ") .. "）")
        end
    end

    local pattern = entry.recoil_pattern
    if pattern == nil then
        return fail(base, "缺少必填字段 recoil_pattern")
    end
    if type(pattern) ~= "table" then
        return fail(base .. ".recoil_pattern", "必须是数组")
    end
    local pointCount = #pattern
    if pointCount == 0 then
        return fail(base .. ".recoil_pattern", "至少需要一个 [yaw, pitch] 点")
    end
    if pointCount > Schema.MAX_PATTERN_POINTS then
        return fail(base .. ".recoil_pattern",
            string.format("点数 %d 超过上限 %d", pointCount, Schema.MAX_PATTERN_POINTS))
    end
    for index = 1, pointCount do
        local point = pattern[index]
        local pointPath = string.format("%s.recoil_pattern[%d]", base, index)
        if type(point) ~= "table" then
            return fail(pointPath, "必须是 [yaw, pitch] 数组")
        end
        if #point ~= 2 then
            return fail(pointPath, "必须正好包含 2 个数值")
        end
        for axis = 1, 2 do
            local value = point[axis]
            if not isFinite(value) then
                return fail(string.format("%s[%d]", pointPath, axis), "必须是有限数值")
            end
            if math.abs(value) > Schema.MAX_ANGLE then
                return fail(string.format("%s[%d]", pointPath, axis),
                    string.format("超出角度上限 %d", Schema.MAX_ANGLE))
            end
        end
    end

    for field, limit in pairs(Schema.LIMITS) do
        local value = entry[field]
        if value ~= nil then
            if not isFinite(value) then
                return fail(base .. "." .. field, "必须是有限数值")
            end
            if value < limit.min or value > limit.max then
                return fail(base .. "." .. field,
                    string.format("必须在 %s ~ %s 之间（当前 %s）", tostring(limit.min), tostring(limit.max), tostring(value)))
            end
        end
    end

    return true, nil
end

--- 校验整份配置
--- @return boolean ok, string|nil err, table|nil report
---   report = { version, weapons, patternPoints, weaponIDs }
function Schema.Validate(data)
    if type(data) ~= "table" then
        return false, "配置根节点必须是对象（WeaponID -> 条目）", nil
    end

    local report = { version = Schema.VERSION, weapons = 0, patternPoints = 0, weaponIDs = {} }
    for weaponID, entry in pairs(data) do
        if type(weaponID) ~= "string" or weaponID == "" then
            return false, "武器 ID 必须是非空字符串（当前 " .. tostring(weaponID) .. "）", nil
        end
        local ok, err = Schema.ValidateEntry(weaponID, entry)
        if not ok then return false, err, nil end
        report.weapons = report.weapons + 1
        report.patternPoints = report.patternPoints + #entry.recoil_pattern
        report.weaponIDs[#report.weaponIDs + 1] = weaponID
    end

    if report.weapons == 0 then
        return false, "至少需要一个武器条目", nil
    end
    if report.weapons > Schema.MAX_WEAPONS then
        return false, string.format("武器条目 %d 超过上限 %d", report.weapons, Schema.MAX_WEAPONS), nil
    end

    table.sort(report.weaponIDs)
    return true, nil, report
end

return Schema
