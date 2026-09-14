--[[
    run_prefab_definitions.lua

    T5：`UUGCPrefabDefinition`（AssetManager）+ Lua 注册表的合并/兜底行为回归。

    覆盖点：
      1. Definition 是主来源（磁盘资产 + 运行时动态注册），来源记到 Registry.Sources
      2. Definition 覆盖同 id 的旧 Catalog 条目（Catalog 只是迁移期兜底）
      3. Catalog 只为「没有 Definition」的 id 补齐；老桥接层（没有 Definition API）时全量兜底
      4. Editor 扫描是最后兜底，且必须报警「资产缺 Definition」
      5. 运行时注册（GLB / runtime package）会同时进 AssetManager 的 ID 空间
      6. 注册失败不影响 Lua 侧可用性，只记警告
      7. GetSemanticDesc / GetKind / ListIDs 等 LLM 与放置路径的对外行为不变
      8. 源码级：UGCPlaceableConfig 只允许被 UGCPrefabRegistry 的兜底路径引用

    说明：Definition 列表由桥接层以 JSON 字符串给出（`GetPrefabDefinitionsJson`），
    这里用假桥接层直接喂 JSON，与 C++ 侧输出格式逐字段对齐。
]]

local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

package.preload["Gameplay.UGC.UGCPrefabRegistry"] = nil

UE = {
    UKismetSystemLibrary = {},
}
function UE.UKismetSystemLibrary.GetProjectDirectory()
    return "C:/fake/FPS/"
end

local Registry = require("Gameplay.UGC.UGCPrefabRegistry")
local json = require("Util.json")

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

--============================================================
-- 假桥接层
--============================================================

--- 模拟 TArray<FString>：Num() + [i]
local function stringArray(list)
    local array = { __num = #list }
    for i, v in ipairs(list) do array[i] = v end
    return setmetatable(array, { __index = function(self, key) if key == "Num" then return function() return self.__num end end end })
end

local function newBridge(options)
    options = options or {}
    local bridge = {
        definitionJson = options.definitionJson,
        files = options.files or {},
        registered = {},
        registerResult = options.registerResult,
    }
    if options.definitionJson ~= nil then
        function bridge:GetPrefabDefinitionsJson()
            if options.definitionThrows then error("bridge exploded") end
            return self.definitionJson
        end
    end
    if options.findFiles ~= false then
        function bridge:FindFilesInDirectory(_, pattern)
            return stringArray(self.files)
        end
    end
    if options.registerResult ~= nil then
        function bridge:RegisterRuntimePrefabDefinition(kind, id, classPath, label, category, description, tags)
            table.insert(self.registered, {
                kind = kind, id = id, classPath = classPath,
                label = label, category = category, description = description, tags = tags,
            })
            return self.registerResult
        end
    end
    return bridge
end

local function definition(overrides)
    local def = {
        id = "Box",
        classPath = "/Game/_UGC/Placeables/BA_Placeable_Box.BA_Placeable_Box_C",
        label = "方块(Definition)",
        category = "基础几何体",
        description = "来自 Definition 的描述",
        tags = { "掩体", "Definition" },
        version = 2,
        cost = 10.0,
        bounds = { 100, 100, 100 },
        allowedModes = { "Edit", "Play" },
        kind = "blueprint",
        source = "asset",
    }
    for k, v in pairs(overrides or {}) do def[k] = v end
    return def
end

--============================================================
-- 1-2. Definition 优先
--============================================================

test("definitions are the primary source and win over the legacy catalog", function()
    local bridge = newBridge({
        definitionJson = json.encode({
            definition(),                                       -- Box：与旧 Catalog 同 id，应当覆盖
            definition({ id = "Prop_Crate", label = "箱子", classPath = "/Game/_UGC/Prefabs/BP_Crate.BP_Crate_C", source = "asset" }),
        }),
        files = { "C:/fake/FPS/Content/_UGC/Placeables/BA_Placeable_Box.uasset" },
    })
    Registry:LoadDynamic(bridge)

    equal(Registry.GetSource("Box"), "definition", "Box 应当来自 Definition")
    equal(Registry.GetMeta("Box").label, "方块(Definition)", "Definition 的元数据应当覆盖 Catalog")
    equal(Registry.GetMeta("Box").description, "来自 Definition 的描述")
    check(Registry.GetPath("Prop_Crate"), "Definition 里的新条目应当进注册表")

    -- 旧 Catalog 里还有 Sphere / TriggerZone，它们没有 Definition → 兜底
    equal(Registry.GetSource("Sphere"), "catalog", "没有 Definition 的旧条目走 Catalog 兜底")
    equal(Registry.GetSource("TriggerZone"), "catalog")
    local counts = Registry.CountBySource()
    equal(counts.definition, 2, "两个 Definition 条目")
    check(counts.catalog >= 2, "Catalog 兜底至少 2 条")
    equal(counts.scan, 0, "Box 已经有 Definition，扫描不应再补一条")
end)

test("semantic description and lookup API keep working from definitions", function()
    local bridge = newBridge({ definitionJson = json.encode({ definition() }) })
    Registry:LoadDynamic(bridge)

    local semantic = Registry:GetSemanticDesc()
    check(semantic:find("Box", 1, true), "语义描述应包含 id")
    check(semantic:find("来自 Definition 的描述", 1, true), "语义描述应使用 Definition 的 description")
    check(semantic:find("Definition", 1, true), "语义描述应包含 tags")

    check(Registry.IsValid("Box"))
    equal(Registry.GetKind("Box"), "blueprint")
    check(Registry.GetPath("Box"):find("BA_Placeable_Box", 1, true), "类路径来自 Definition")
end)

--============================================================
-- 3-4. 兜底与报警
--============================================================

test("editor scan is the last resort and flags assets without definitions", function()
    local bridge = newBridge({
        definitionJson = json.encode({ definition({ id = "Box" }) }),
        files = {
            "C:/fake/FPS/Content/_UGC/Placeables/BA_Placeable_Box.uasset",      -- 已有 Definition
            "C:/fake/FPS/Content/_UGC/Placeables/BA_Placeable_Cylinder.uasset", -- 没有 Definition
        },
    })
    Registry:LoadDynamic(bridge)

    equal(Registry.GetSource("Cylinder"), "scan", "缺 Definition 的资产由扫描兜底")
    check(Registry.Prefabs["Cylinder"], "扫描出来的条目应当可用")
    equal(Registry.GetSource("Box"), "definition", "有 Definition 的条目不应被扫描覆盖")
    local counts = Registry.CountBySource()
    equal(counts.scan, 1, "只有 1 个条目来自扫描")
end)

test("a bridge without definition API falls back to the catalog", function()
    local bridge = newBridge({ findFiles = false })   -- 完全老的桥接层
    Registry:LoadDynamic(bridge)

    equal(Registry.GetSource("Box"), "catalog", "老桥接层应当全量走 Catalog 兜底")
    check(Registry.IsValid("Box"))
    check(Registry.IsValid("TriggerZone"))
    equal(Registry.CountBySource().definition, 0)
end)

test("a broken definition payload degrades to the catalog instead of failing", function()
    local bridge = newBridge({ definitionJson = "{ this is not json", findFiles = false })
    Registry:LoadDynamic(bridge)
    equal(Registry.GetSource("Box"), "catalog", "JSON 坏了也要能跑（退回兜底）")

    local throwing = newBridge({ definitionJson = "[]", definitionThrows = true, findFiles = false })
    Registry:LoadDynamic(throwing)
    equal(Registry.GetSource("Box"), "catalog", "桥接层抛异常也要能跑")
end)

--============================================================
-- 5-6. 运行时注册
--============================================================

test("runtime prefabs are also registered into the AssetManager id space", function()
    local bridge = newBridge({ definitionJson = "[]", registerResult = true })
    Registry:LoadDynamic(bridge)

    local glbId = Registry:RegisterDynamicGLB({ uuid = "u-1", name = "AI 椅子", glb_path = "Saved/UGC/chair.glb" })
    equal(glbId, "dyn:u-1")
    equal(#bridge.registered, 1, "动态 GLB 应当注册一个 Definition")
    equal(bridge.registered[1].kind, "dynamic_glb")
    equal(bridge.registered[1].id, "dyn:u-1")
    equal(bridge.registered[1].classPath, "/Script/FPS.AnimAgentDynamicPlaceable")
    equal(bridge.registered[1].label, "AI 椅子")
    equal(Registry.GetSource("dyn:u-1"), "definition", "注册后来源标记为 definition")
    equal(Registry.GetKind("dyn:u-1"), "dynamic_glb", "spawn 路由不变")

    local pkgId = Registry:RegisterRuntimeAsset({ package_id = "p1", manifest_path = "Saved/UGC/Packages/p1/manifest.json", name = "包资产" })
    equal(pkgId, "pkg:p1:main")
    equal(#bridge.registered, 2)
    equal(bridge.registered[2].kind, "runtime_asset")
    equal(Registry.GetKind("pkg:p1:main"), "runtime_asset")
end)

test("a failing registration only warns and keeps the lua side usable", function()
    local bridge = newBridge({ definitionJson = "[]", registerResult = false })
    Registry:LoadDynamic(bridge)

    local id = Registry:RegisterDynamicGLB({ uuid = "u-2", name = "AI 桌子", glb_path = "Saved/UGC/table.glb" })
    equal(id, "dyn:u-2", "注册失败不应影响 Lua 侧条目")
    check(Registry.GetDynamicGLB("dyn:u-2"), "运行期载荷仍在 Lua 侧")
    equal(Registry.GetKind("dyn:u-2"), "dynamic_glb")

    local noApi = newBridge({ definitionJson = "[]" })   -- 桥接层没有注册 API
    Registry:LoadDynamic(noApi)
    equal(Registry:RegisterDynamicGLB({ uuid = "u-3", glb_path = "Saved/UGC/x.glb" }), "dyn:u-3", "没有注册 API 也不能炸")
end)

--============================================================
-- 8. 源码级：Catalog 只能被兜底路径引用
--============================================================

test("the legacy catalog is only referenced by the registry fallback", function()
    -- 跨文件引用检查交给 run_tests.ps1 的静态守卫（PowerShell 列目录更可靠）；
    -- 这里锁住两个文件自身的契约：兜底文件必须自述身份，注册表必须有 Definition 主来源 + 兜底段。
    local function read(rel)
        local handle = io.open(root .. "/" .. rel, "rb")
        if not handle then return nil end
        local content = handle:read("*a")
        handle:close()
        return content
    end

    local catalog = read("Content/Script/Gameplay/UGC/UGCPlaceableConfig.lua")
    check(catalog, "兜底 Catalog 文件应当存在（T5 期间保留）")
    check(catalog:find("迁移期兜底", 1, true), "Catalog 必须自述为迁移期兜底")

    local registry = read("Content/Script/Gameplay/UGC/UGCPrefabRegistry.lua")
    check(registry:find("GetPrefabDefinitionsJson", 1, true), "注册表必须从 Definition 取主来源")
    check(registry:find("RegisterRuntimePrefabDefinition", 1, true), "运行时资产必须登记进 AssetManager")
    check(registry:find("prefab_definition_missing", 1, true), "缺 Definition 必须报警")
end)

test("the registry exposes the API other modules call", function()
    -- 2026-09-15 首次 PIE 实测：UGCFunctionRegistry.lua:288 调 require(...).ListIDs()，
    -- 该函数在 05a55fe 重构时被删掉，导致 RegisterAll 在运行时整体抛异常、LLM 工具注册表起不来。
    -- 这里把「其它模块对注册表的调用面」静态锁死，避免同类回归。
    local scanRoot = root .. "/Content/Script"
    local called = {}
    local function scanFile(path, name)
        local handle = io.open(path, "rb")
        if not handle then return end
        local content = handle:read("*a")
        handle:close()
        if name == "UGCPrefabRegistry.lua" then return end
        for fn in content:gmatch('require%("Gameplay%.UGC%.UGCPrefabRegistry"%)%.([%a_][%w_]*)') do
            called[fn] = (called[fn] or 0) + 1
        end
        for fn in content:gmatch('PrefabReg%a*[%.:]([%a_][%w_]*)') do
            called[fn] = (called[fn] or 0) + 1
        end
        for fn in content:gmatch('PrefabRegistry[%.:]([%a_][%w_]*)') do
            called[fn] = (called[fn] or 0) + 1
        end
    end
    -- 只扫描已知会引用注册表的目录，避免遍历整棵树
    for _, sub in ipairs({ "", "/Gameplay/UGC", "/System/UI/UGC", "/Gameplay/UGC/Generators" }) do
        local pipe = io.popen('dir /b "' .. (scanRoot .. sub):gsub("/", "\\") .. '\\*.lua" 2>nul')
        if pipe then
            for line in pipe:lines() do
                local name = line:match("([^\\/]+)$")
                if name then scanFile(scanRoot .. sub .. "/" .. name, name) end
            end
            pipe:close()
        end
    end

    local missing = {}
    for fn in pairs(called) do
        if Registry[fn] == nil then missing[#missing + 1] = fn end
    end
    equal(#missing, 0, "被别的模块调用的注册表函数必须都存在，缺: " .. table.concat(missing, ", "))
    check(called["ListIDs"], "UGCFunctionRegistry 依赖 ListIDs 作为 place_object 的 enum 来源")

    -- ListIDs 必须有内容（否则 place_object 的 enum 为空，AI 无法放置任何东西）
    local bridge = newBridge({ definitionJson = json.encode({ definition(), definition({ id = "Prop_Crate" }) }) })
    Registry:LoadDynamic(bridge)
    local ids = Registry.ListIDs()
    check(#ids >= 2, "ListIDs 至少应包含定义里的条目")
    local sorted = true
    for i = 2, #ids do if ids[i - 1] > ids[i] then sorted = false end end
    check(sorted, "ListIDs 应当排序（enum 展示稳定）")
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
