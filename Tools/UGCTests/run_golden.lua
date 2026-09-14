--[[
    run_golden.lua

    T4：Golden Scene 与序列化 Golden 回归。

    目标：把「存档不漂移」变成可自动判定的回归，而不是靠人工看 diff。

    仓库内的 3 个 golden 样本放在 Tools/UGCTests/golden/：
      external_pcg.ugc.json   外部实体（PCG adapter）+ worldSettings
      groups.ugc.json         生成批次 generatedGroups（匿名 batch + 具名 batch）
      program.ugc.json        图程序（level_main + actor_prog_N）

    每个样本跑两组判定：
      1. construct：用公开 API（SceneData 命令 / 批次 / 程序）从零构出同一份文档，
         再经 SceneData:SerializePackageTable + Util.json 编码，与样本逐字节比对。
      2. roundtrip：样本 → DeserializePackageTable → 再序列化，必须与样本完全一致（不动点）。
    program 样本额外跑一次 Compiler:Compile，确保「能存下来的程序」同时是「能编译的程序」。

    归一化：savedAt 是 os.time()，无法跨运行复现，因此在比对前统一置 0；
    样本里的 savedAt 就是 0。行尾 CRLF 也对齐成 LF（Windows 编辑器 / git 检出可能改动行尾）。
    除此以外没有任何字段被忽略 —— 其余内容逐字节比对。

    失败时输出两类定位信息：JSON 路径级的结构差异 + 行号级的文本差异。

    重新生成样本（确认行为改动是有意的之后再执行）：
      lua54 run_golden.lua <repo-root> --update
    然后 review `git diff Tools/UGCTests/golden/`。
]]

local root = assert(arg[1], "workspace root required")
local updateMode = (arg[2] == "--update") or (arg[3] == "--update")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

local GOLDEN_DIR = root .. "/Tools/UGCTests/golden"

--============================================================
-- 运行环境替身（与 run_scene.lua 同一套约定）
--============================================================

local PREFABS = {
    Box = "/Game/_UGC/Placeables/Box.Box_C",
    Sphere = "/Game/_UGC/Placeables/Sphere.Sphere_C",
    TriggerZone = "/Game/_UGC/Placeables/TriggerZone.TriggerZone_C",
    PCG_Generated = "/Game/_UGC/Placeables/PCG_Generated.PCG_Generated_C",
}

package.preload["Gameplay.UGC.UGCPrefabRegistry"] = function()
    return {
        IsValid = function(id) return PREFABS[id] ~= nil end,
        GetPath = function(id) return PREFABS[id] end,
        GetKind = function(id)
            if id == "PCG_Generated" then return "pcg" end
            return "static"
        end,
    }
end

UE = {
    FVector = function(x, y, z) return { X = x, Y = y, Z = z } end,
    FRotator = function(p, y, r) return { Pitch = p, Yaw = y, Roll = r } end,
    UKismetMathLibrary = {},
    UKismetSystemLibrary = {},
}
function UE.UKismetMathLibrary.MakeTransform(loc, rot, scale)
    return { loc = loc, rot = rot, scale = scale }
end
function UE.UKismetMathLibrary.BreakTransform(transform)
    return transform.loc, transform.rot, transform.scale
end
function UE.UKismetSystemLibrary.IsValid(actor) return actor ~= nil and actor.valid ~= false end

local function actor()
    return {
        valid = true,
        SetProgramID = function(self, id) self.programId = id end,
        SetSourceEntityID = function(self, id) self.entityId = id end,
        SetDebugVisible = function(self, value) self.debugVisible = value end,
    }
end

local bridge = { actors = {} }
function bridge:SpawnPlaceable(path, loc, rot)
    local value = actor()
    value.path = path
    value.transform = UE.UKismetMathLibrary.MakeTransform(loc, rot, UE.FVector(1, 1, 1))
    self.actors[#self.actors + 1] = value
    return value
end
function bridge:SetActorTransform(value, transform) value.transform = transform end
function bridge:TrySetActorTransform(value, transform) value.transform = transform; return true end
function bridge:GetActorTransform(value) return value.transform end
function bridge:DestroyActor(value) value.valid = false end
function bridge:TryDestroyActor(value) value.valid = false; return true end

local json = require("Util.json")
local SceneData = require("Gameplay.UGC.UGCSceneData")
local Compiler = require("Gameplay.UGC.UGCGraphCompiler")

--============================================================
-- 场景构造辅助
--============================================================

--- 9 元组 Transform：[x, y, z, pitch, yaw, roll, scaleX, scaleY, scaleZ]
local function transform(x, y, z, pitch, yaw, roll, sx, sy, sz)
    return {
        x or 0, y or 0, z or 0,
        pitch or 0, yaw or 0, roll or 0,
        sx or 1, sy or 1, sz or 1,
    }
end

--- 世界规则替身：set 做一次 clamp，get 对已知规则返回默认值（SetWorldRule 校验要求 oldValue >= 0）
local RULE_DEFAULTS = { GravityScale = 1, FriendlyFire = 0, RoundTime = 300, RespawnDelay = 5 }
local ruleState = {}
local function resetWorldRules() ruleState = {} end
local function applyWorldRule(rule, value)
    local number = tonumber(value) or 0
    if rule == "GravityScale" then number = math.max(0, math.min(3, number)) end
    if rule == "FriendlyFire" then number = (number ~= 0) and 1 or 0 end
    ruleState[rule] = number
    return true
end
local function readWorldRule(rule)
    if ruleState[rule] ~= nil then return ruleState[rule] end
    return RULE_DEFAULTS[rule] or -1
end

--- 每个场景共用的准备动作（构造与加载两条路径都必须先做）
local function prepare(SD)
    resetWorldRules()
    ruleState = {}
    SD:RegisterWorldRuleAdapter(applyWorldRule, readWorldRule, resetWorldRules)
    SD:RegisterExternalAdapter("pcg", function(record)
        SD:AttachExternalActor(record.sceneID, actor())
        return true
    end, function(value) value.valid = false; return true end)
end

--============================================================
-- 三个 golden 场景
--============================================================

local LEVEL_PROGRAM = {
    nodes = {
        { id = "event", type = "Event_OnGameStart", params = {} },
        { id = "rule", type = "Set_GameRule", params = { rule = "GravityScale", value = "0.8" } },
        { id = "print", type = "Print_Message", params = { msg = "关卡规则已应用" } },
    },
    connections = {
        { from_id = "event", from_pin = "exec_out", to_id = "rule", to_pin = "exec_in" },
        { from_id = "rule", from_pin = "exec_out", to_id = "print", to_pin = "exec_in" },
    },
}

local ACTOR_PROGRAM = {
    nodes = {
        { id = "enter", type = "Event_OnEnter", params = {} },
        { id = "delay", type = "Delay", params = { seconds = "0.5" } },
        { id = "print", type = "Print_Message", params = { msg = "玩家进入触发区" } },
    },
    connections = {
        { from_id = "enter", from_pin = "exec_out", to_id = "delay", to_pin = "exec_in" },
        { from_id = "delay", from_pin = "exec_out", to_id = "print", to_pin = "exec_in" },
    },
}

local SCENARIOS = {
    {
        name = "external_pcg",
        documentId = "ugc-golden-external-pcg",
        fixture = "external_pcg.ugc.json",
        --- external/PCG 实体 + worldSettings：验证 adapter 元数据与规则值的持久化形状
        build = function(SD)
            SD:CreateActorWithTransform("Box", UE.UKismetMathLibrary.MakeTransform(
                UE.FVector(0, 0, 0), UE.FRotator(0, 0, 0), UE.FVector(1, 1, 1)))
            SD:CreateExternalEntity("PCG_Generated", transform(1200, -350, 25), {
                kind = "pcg",
                graph = "/Game/_UGC/PCG/PCG_PineForest",
                seed = 20260914,
                x = 1200,
                y = -350,
                z = 25,
                radius = 800,
            })
            SD:SetWorldRule("GravityScale", 1.5)
            SD:SetWorldRule("FriendlyFire", 0)
            return { activeProgramId = "level_main", selectedSceneID = 2 }
        end,
    },
    {
        name = "groups",
        documentId = "ugc-golden-groups",
        fixture = "groups.ugc.json",
        --- 生成批次：匿名 batch_1 + 具名 batch_forest_a，验证 generatedGroups 与 nextBatchID
        build = function(SD)
            local first = SD:CreateActorWithTransform("Box", UE.UKismetMathLibrary.MakeTransform(
                UE.FVector(100, 0, 0), UE.FRotator(0, 0, 0), UE.FVector(1, 1, 1)))
            local second = SD:CreateActorWithTransform("Box", UE.UKismetMathLibrary.MakeTransform(
                UE.FVector(300, 0, 0), UE.FRotator(0, 0, 0), UE.FVector(1, 1, 1)))
            local batch = SD:BeginBatch()
            SD:AddToBatch(batch, first)
            SD:AddToBatch(batch, second)

            local third = SD:CreateActorWithTransform("Sphere", UE.UKismetMathLibrary.MakeTransform(
                UE.FVector(500, 200, 0), UE.FRotator(0, 0, 0), UE.FVector(1, 1, 1)))
            local fourth = SD:CreateActorWithTransform("Sphere", UE.UKismetMathLibrary.MakeTransform(
                UE.FVector(700, 200, 0), UE.FRotator(0, 0, 0), UE.FVector(1, 1, 1)))
            local named = SD:BeginNamedBatch("forest_a")
            SD:AddToBatch(named, third)
            SD:AddToBatch(named, fourth)

            return { activeProgramId = "level_main" }
        end,
    },
    {
        name = "program",
        documentId = "ugc-golden-program",
        fixture = "program.ugc.json",
        --- 图程序：level_main 与 actor_prog_1 同时入库，验证 programs 的序列化形状
        build = function(SD)
            local trigger = SD:CreateActorWithTransform("TriggerZone", UE.UKismetMathLibrary.MakeTransform(
                UE.FVector(-900, 120, 0), UE.FRotator(0, 90, 0), UE.FVector(2, 2, 2)))
            SD:CreateActorWithTransform("Box", UE.UKismetMathLibrary.MakeTransform(
                UE.FVector(-600, 120, 0), UE.FRotator(0, 0, 0), UE.FVector(1, 1, 1)))
            SD:SetLevelScript(LEVEL_PROGRAM)
            SD:SetActorScript(trigger, ACTOR_PROGRAM)
            return { activeProgramId = "level_main", selectedProgramId = "actor_prog_1" }
        end,
        --- 额外判定：样本里的 level 程序必须能编译成 IR
        extra = function(SD)
            local report = Compiler:Compile(SD:GetLevelScript(), { programID = "level_main" })
            if not report.ok then
                return "golden program 无法编译: " .. tostring(Compiler:FormatReport(report))
            end
            return nil
        end,
    },
}

--============================================================
-- 比对与差异定位
--============================================================

local function splitLines(text)
    local lines = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    return lines
end

--- 行级 LCS diff，返回 { {kind="="|"-"|"+", aLine=n, bLine=n, text=...}, ... }
local function lineDiff(a, b)
    local out = {}
    local n, m = #a, #b
    local dp = {}
    for i = 0, n do dp[i] = {} end
    for i = n, 0, -1 do
        for j = m, 0, -1 do
            if i == n or j == m then
                dp[i][j] = 0
            elseif a[i + 1] == b[j + 1] then
                dp[i][j] = dp[i + 1][j + 1] + 1
            else
                dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
            end
        end
    end
    local i, j = 0, 0
    while i < n and j < m do
        if a[i + 1] == b[j + 1] then
            out[#out + 1] = { kind = "=", aLine = i + 1, bLine = j + 1, text = a[i + 1] }
            i, j = i + 1, j + 1
        elseif dp[i + 1][j] >= dp[i][j + 1] then
            out[#out + 1] = { kind = "-", aLine = i + 1, bLine = j + 1, text = a[i + 1] }
            i = i + 1
        else
            out[#out + 1] = { kind = "+", aLine = i + 1, bLine = j + 1, text = b[j + 1] }
            j = j + 1
        end
    end
    while i < n do out[#out + 1] = { kind = "-", aLine = i + 1, bLine = j + 1, text = a[i + 1] }; i = i + 1 end
    while j < m do out[#out + 1] = { kind = "+", aLine = i + 1, bLine = j + 1, text = b[j + 1] }; j = j + 1 end
    return out
end

local function describe(value)
    if value == nil then return "缺失" end
    local kind = type(value)
    if kind == "table" then return json.encode(value) end
    if kind == "string" then return string.format("%q", value) end
    return tostring(value)
end

--- 结构差异：按 JSON 路径递归比对（数组按下标，表按键）
local function tableDiffs(expected, actual, path, out, limit)
    if #out >= limit then return end
    if type(expected) ~= type(actual) then
        out[#out + 1] = string.format("%s: expected %s, got %s", path, describe(expected), describe(actual))
        return
    end
    if type(expected) ~= "table" then
        if expected ~= actual then
            out[#out + 1] = string.format("%s: expected %s, got %s", path, describe(expected), describe(actual))
        end
        return
    end
    for key, value in pairs(expected) do
        tableDiffs(value, actual[key], path .. "." .. tostring(key), out, limit)
        if #out >= limit then return end
    end
    for key in pairs(actual) do
        if expected[key] == nil then
            out[#out + 1] = string.format("%s.%s: 输出里多出这个键（expected 缺失）", path, tostring(key))
            if #out >= limit then return end
        end
    end
end

local DIFF_LIMIT = 20
local LINE_LIMIT = 10

--- 比对两份文本，返回 nil（一致）或可直接打印的报告
--- CRLF 会被归一化成 LF（Windows 编辑器 / git 检出可能改动行尾），其余必须逐字节一致。
local function compareText(label, expectedText, actualText)
    expectedText = tostring(expectedText):gsub("\r\n", "\n"):gsub("%s+$", "")
    actualText = tostring(actualText):gsub("\r\n", "\n"):gsub("%s+$", "")
    if expectedText == actualText then return nil end

    local expectedLines, actualLines = splitLines(expectedText), splitLines(actualText)
    local report = { string.format("%s 与 golden 不一致", label) }
    report[#report + 1] = string.format("  golden 行数 %d / 当前输出行数 %d", #expectedLines, #actualLines)

    local structural = {}
    local expectedValue, actualValue = json.decode(expectedText), json.decode(actualText)
    if expectedValue and actualValue then
        tableDiffs(expectedValue, actualValue, "package", structural, DIFF_LIMIT)
    end
    if #structural > 0 then
        report[#report + 1] = string.format("  结构差异（最多列出 %d 条）：", DIFF_LIMIT)
        for _, item in ipairs(structural) do report[#report + 1] = "    " .. item end
    else
        report[#report + 1] = "  结构差异：无（差异只在文本/键序层面，说明编码器或缩进变了）"
    end

    local diff = lineDiff(expectedLines, actualLines)
    local changed, shown = 0, 0
    for _, entry in ipairs(diff) do if entry.kind ~= "=" then changed = changed + 1 end end
    report[#report + 1] = string.format("  行差异（共 %d 条，列出前 %d 条）：", changed, LINE_LIMIT)
    for _, entry in ipairs(diff) do
        if shown < LINE_LIMIT then
            if entry.kind == "-" then
                shown = shown + 1
                report[#report + 1] = string.format("    - golden:%d | %s", entry.aLine, entry.text)
            elseif entry.kind == "+" then
                shown = shown + 1
                report[#report + 1] = string.format("    + 输出:%d | %s", entry.bLine, entry.text)
            end
        end
    end
    report[#report + 1] = "  确认是有意的行为变化后，用 --update 重新生成样本并 review git diff。"
    return table.concat(report, "\n")
end

--============================================================
-- 文件读写
--============================================================

local function readFixture(name)
    local handle = io.open(GOLDEN_DIR .. "/" .. name, "rb")
    if not handle then return nil end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function writeFixture(name, text)
    local path = GOLDEN_DIR .. "/" .. name
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
    return path
end

--- savedAt 是 os.time()，无法跨运行复现；比对前统一置 0（样本里也是 0）
local function encodePackage(package)
    package.savedAt = 0
    return json.encode(package, "  ") .. "\n"
end

--- 构造路径：公开 API 从零建文档 → 序列化
local function buildPackage(scenario)
    local documentId = scenario.documentId
    SceneData:Init(bridge)
    prepare(SceneData)
    bridge.actors = {}
    SceneData:GetDocument().header.documentId = documentId
    local editorState = scenario.build(SceneData)
    return SceneData:SerializePackageTable(editorState)
end

--- 加载路径：golden → DeserializePackageTable → 再序列化（不动点检查）
local function roundTripPackage(encoded)
    local package = json.decode(encoded)
    SceneData:Init(bridge)
    prepare(SceneData)
    bridge.actors = {}
    local ok, message = SceneData:DeserializePackageTable(package)
    if not ok then return nil, tostring(message) end
    return SceneData:SerializePackageTable(package.editor or {}), nil, SceneData
end

--============================================================
-- 主流程
--============================================================

local total, passed = 0, 0
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

--- 样本数量守卫：T4 要求 external/PCG、Group、Program 三个场景样本都在
test("golden fixtures are present and complete", function()
    if updateMode then return end
    for _, scenario in ipairs(SCENARIOS) do
        local text = readFixture(scenario.fixture)
        if not text then
            error("缺少 golden 样本: Tools/UGCTests/golden/" .. scenario.fixture)
        end
        if not text:find('"packageVersion"', 1, true) then
            error("golden 样本不是版本化存档包: " .. scenario.fixture)
        end
    end
    if #SCENARIOS ~= 3 then
        error("T4 要求 3 个场景样本（external/PCG、Group、Program），当前 " .. #SCENARIOS)
    end
end)

for _, scenario in ipairs(SCENARIOS) do
    test("golden " .. scenario.name .. " construct matches fixture", function()
        local actual = encodePackage(buildPackage(scenario))
        if updateMode then
            local path = writeFixture(scenario.fixture, actual)
            print("  updated " .. path)
            return
        end
        local report = compareText("golden/" .. scenario.fixture, readFixture(scenario.fixture), actual)
        if report then error("\n" .. report, 0) end
    end)

    test("golden " .. scenario.name .. " load round-trips without drift", function()
        local encoded = readFixture(scenario.fixture)
        if not encoded then error("缺少 golden 样本: " .. scenario.fixture) end
        if type(json.decode(encoded)) ~= "table" then
            error("golden 样本不是合法 JSON: Tools/UGCTests/golden/" .. scenario.fixture)
        end
        local package, err, SD = roundTripPackage(encoded)
        if not package then error("加载 golden 失败: " .. tostring(err)) end
        local actual = encodePackage(package)
        local report = compareText("golden/" .. scenario.fixture .. "（roundtrip）", encoded, actual)
        if report then error("\n" .. report, 0) end
        if scenario.extra then
            local extraError = scenario.extra(SD)
            if extraError then error(extraError) end
        end
    end)
end

if updateMode then
    print(string.format("golden fixtures updated: %d scenarios, review git diff in Tools/UGCTests/golden/", #SCENARIOS))
end

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
