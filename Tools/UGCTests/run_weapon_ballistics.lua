--[[
    run_weapon_ballistics.lua

    T17：编解码统一（含武器弹道 JSON）的回归测试。

    覆盖点：
      1. 仓库里真实的 Content/Data/WeaponBallistics.json 能通过 schema 校验（防止配置写坏）
      2. 编解码只有一份：Content/Script 下不再出现 rapidjson（与 run_tests.ps1 的静态守卫一致）
      3. schema 能抓住各类写错：缺字段、未知字段（拼错）、类型错、点数越界、数值越界、非有限数
      4. 弹道配置随包落盘：DefaultGame.ini 必须以 NonUFS 方式 stage Content/Data，
         否则运行期 io.open 读不到（UFS 在 pak 里）
]]

local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

local json = require("Util.json")
local Schema = require("Gameplay.Weapon.WeaponBallisticsSchema")

local total, passed = 0, 0
local function check(value, message) if not value then error(message or "check failed", 2) end end
local function equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s got %s", message or "not equal", tostring(expected), tostring(actual)), 2)
    end
end
local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
end

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function splitLines(text)
    local lines = {}
    for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    return lines
end

--- 合法条目的模板（每个用例只改一处）
local function entry(overrides)
    local value = {
        recoil_pattern = { { 0.0, 1.0 }, { 0.0, 2.0 }, { -0.3, 2.5 } },
        random_spread_radius = 0.4,
        pattern_reset_time = 0.4,
    }
    for key, replacement in pairs(overrides or {}) do value[key] = replacement end
    return value
end

--- 断言被拒绝，且错误信息里带上定位片段
local function rejects(data, fragment, label)
    local ok, err = Schema.Validate(data)
    check(not ok, label .. ": 应当被拒绝，但校验通过了")
    check(tostring(err):find(fragment, 1, true) ~= nil,
        string.format("%s: 错误信息缺少 %q（实际: %s）", label, fragment, tostring(err)))
end

--============================================================
-- 1. 真实配置
--============================================================

test("shipped ballistics config passes the schema", function()
    local path = root .. "/Content/Data/WeaponBallistics.json"
    local content = readFile(path)
    check(content, "缺少配置文件: " .. path)

    local data = json.decode(content)
    check(type(data) == "table", "配置文件必须能被 Util.json 解码")

    local ok, err, report = Schema.Validate(data)
    check(ok, "真实配置未通过校验: " .. tostring(err))
    equal(report.version, Schema.VERSION, "report.version")
    check(report.weapons >= 2, "至少配置了两个武器，实际 " .. report.weapons)
    check(report.patternPoints > 0, "Pattern 点数必须大于 0")
    check(report.weaponIDs[1] == "AK47", "weaponIDs 排序后第一个应为 AK47，实际 " .. tostring(report.weaponIDs[1]))

    -- 配置里的每个武器都要能被 Lua 读取到它期望的字段
    for _, weaponID in ipairs(report.weaponIDs) do
        local weapon = data[weaponID]
        check(type(weapon.recoil_pattern) == "table" and #weapon.recoil_pattern >= 1, weaponID .. " 需要 Pattern")
        check(type(weapon.recoil_pattern[1][1]) == "number", weaponID .. " Pattern 点必须是数值")
    end
end)

--============================================================
-- 2. 编解码唯一
--============================================================

test("no rapidjson left under Content/Script", function()
    local weapon = readFile(root .. "/Content/Script/Gameplay/Weapon/BP_WeaponBase.lua")
    check(weapon, "找不到 BP_WeaponBase.lua")
    check(weapon:find('require("Util.json")', 1, true) ~= nil, "BP_WeaponBase.lua 必须用 Util.json")
    check(weapon:find("BallisticsSchema.Validate", 1, true) ~= nil, "BP_WeaponBase.lua 必须走 schema 校验")

    -- 注释里可以提「不再使用 rapidjson」，所以只看非注释行（与 run_tests.ps1 的守卫同一约定）
    for index, line in ipairs(splitLines(weapon)) do
        if not line:match("^%s*%-%-") and line:find("rapidjson", 1, true) then
            error(string.format("第 %d 行仍在调用 rapidjson: %s", index, line))
        end
    end
end)

--============================================================
-- 3. schema 抓错
--============================================================

test("schema rejects malformed configs", function()
    local validData = { AK47 = entry() }
    check(Schema.Validate(validData), "模板条目本身必须合法")

    rejects({}, "至少需要一个武器条目", "空配置")
    rejects({ AK47 = "nope" }, "必须是对象", "条目不是对象")
    local missingPattern = entry()
    missingPattern.recoil_pattern = nil
    rejects({ AK47 = missingPattern }, "recoil_pattern", "缺必填字段")
    rejects({ AK47 = entry({ recoilPattern = {} }) }, "未知字段", "字段名拼错")
    rejects({ AK47 = entry({ recoil_pattern = {} }) }, "至少需要一个", "空 Pattern")
    rejects({ AK47 = entry({ recoil_pattern = { { 1.0 } } }) }, "正好包含 2 个数值", "点元素个数不对")
    rejects({ AK47 = entry({ recoil_pattern = { { "1.0", 2.0 } } }) }, "必须是有限数值", "数值写成字符串")
    rejects({ AK47 = entry({ recoil_pattern = { { 0 / 0, 1.0 } } }) }, "必须是有限数值", "NaN")
    rejects({ AK47 = entry({ recoil_pattern = { { 0.0, math.huge } } }) }, "必须是有限数值", "Inf")
    rejects({ AK47 = entry({ recoil_pattern = { { 0.0, 999 } } }) }, "超出角度上限", "角度越界")
    rejects({ AK47 = entry({ random_spread_radius = 999 }) }, "必须在", "散布半径越界")
    rejects({ AK47 = entry({ random_spread_radius = "0.4" }) }, "必须是有限数值", "半径写成字符串")
    rejects({ AK47 = entry({ pattern_reset_time = 0 }) }, "必须在", "归零时间过小")
    rejects({ AK47 = entry({ pattern_reset_time = 99 }) }, "必须在", "归零时间过大")

    -- 点数上限
    local points = {}
    for index = 1, Schema.MAX_PATTERN_POINTS + 1 do points[index] = { 0.0, 1.0 } end
    rejects({ AK47 = entry({ recoil_pattern = points }) }, "超过上限", "点数超上限")

    -- 可选字段缺省是允许的（使用方有兜底默认值）
    local ok = Schema.Validate({ AK47 = { recoil_pattern = { { 0.0, 1.0 } } } })
    check(ok, "只有 recoil_pattern 的条目应当合法")
end)

test("schema reports the failing path", function()
    local ok, err = Schema.Validate({ AK47 = entry({ recoil_pattern = { { 0.0, 1.0 }, { 0.0, "2.0" } } }) })
    check(not ok, "必须被拒绝")
    check(tostring(err):find("AK47.recoil_pattern[2][2]", 1, true) ~= nil,
        "错误信息必须定位到具体点，实际: " .. tostring(err))
end)

--============================================================
-- 4. 打包 staging
--============================================================

test("ballistics config is staged as NonUFS for packaged runs", function()
    local ini = readFile(root .. "/Config/DefaultGame.ini")
    check(ini, "缺少 Config/DefaultGame.ini")
    check(ini:find('DirectoriesToAlwaysStageAsNonUFS=(Path="Data")', 1, true) ~= nil,
        "DefaultGame.ini 必须把 Content/Data 以 NonUFS 方式 stage，否则打包后 io.open 读不到弹道配置")
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
