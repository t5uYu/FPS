--[[
    run_migration.lua

    T15：显式迁移链 V1 → V2 → V3 的回归测试。

    覆盖点：
      1. V1 样本（id / prefab / t 写法，无 entityId/actorId/programId/nextSceneID）
         经 1→2→3 迁移后字段完整、版本正确
      2. V2 样本（有标识但缺 tags/properties/metadata/contentVersion）迁移到 3：
         容器补齐、布尔标志收敛、组内悬空引用被丢弃并计入 notes、非法世界规则被丢弃
      3. 当前版本（3）是空操作：迁移结果与输入等值，逐字节可复现
      4. 迁移是幂等的：migrate(migrate(x)) == migrate(x)
      5. 未知 / 越界 schemaVersion 被拒绝，且入参不被修改
      6. 迁移步骤抛异常时整链失败、入参不被修改（回滚语义的结构保证）
      7. Document.FromSnapshot 会自动走迁移链（v1 文档也能加载成 v3）
      8. 加载路径集成：v1 样本文件加载后是 v3，但磁盘上的文件一个字节都不动
      9. Persistence:MigrateProject 显式迁移：写回 v3、迁移前内容留在 .bak、二次调用不再写；
         迁移失败（未知版本）时文件保持原样
]]

local root = assert(arg[1], "workspace root required")
local tempDir = assert(arg[2], "temp dir required"):gsub("\\", "/")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

UE = { UKismetSystemLibrary = { MakeDirectory = function() return true end } }

local json = require("Util.json")
local Migrations = require("Gameplay.UGC.UGCMigrations")
local Document = require("Gameplay.UGC.UGCDocument")
local Persistence = require("Gameplay.UGC.UGCPersistence")

local FIXTURE_DIR = root .. "/Tools/UGCTests/fixtures"

--============================================================
-- 存储替身（与 run_persistence.lua 同一套契约）
--============================================================

local function allowedSuffix(path)
    local lower = tostring(path):lower()
    if lower:match("%.json$") then return true end
    if lower:match("%.bak$") then return true end
    return lower:match("%.bak%d+$") ~= nil
end

local function readRaw(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function writeRaw(path, content)
    local handle = assert(io.open(path, "wb"))
    handle:write(content)
    handle:close()
end

local storage = {}
function storage:FileExists(path)
    if not allowedSuffix(path) then return false end
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end
function storage:ReadTextFile(path)
    if not allowedSuffix(path) then return "" end
    return readRaw(path) or ""
end
function storage:WriteTextFileAtomic(path, content)
    if not allowedSuffix(path) then return false end
    local tempPath, backupPath = path .. ".tmp", path .. ".bak"
    os.remove(tempPath)
    writeRaw(tempPath, content)
    if readRaw(tempPath) ~= content then os.remove(tempPath); return false end
    os.remove(backupPath)
    local hadOriginal = self:FileExists(path)
    if hadOriginal and not os.rename(path, backupPath) then os.remove(tempPath); return false end
    if not os.rename(tempPath, path) then
        os.remove(tempPath)
        if hadOriginal then os.rename(backupPath, path) end
        return false
    end
    return true
end

Persistence:Init(storage)
Persistence:ConfigureBackups(2)

--============================================================
-- 测试骨架
--============================================================

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

local function fixture(name)
    local content = readRaw(FIXTURE_DIR .. "/" .. name)
    check(content, "missing fixture: " .. name)
    return json.decode(content)
end

local function encode(value) return json.encode(value, "  ") end

--- 假 SceneData：只记录最后一次加载的包
local scene = {}
function scene:SerializePackageTable(editor)
    return { document = self.loaded and self.loaded.document or {}, editor = editor or {} }
end
function scene:ClearDirty() self.cleared = true end
function scene:DeserializePackageTable(package) self.loaded = package; return true, "loaded" end
function scene:GetRevision() return self.loaded and self.loaded.document.header.revision or 0 end
function scene:Count() return #(self.loaded and self.loaded.document.entities or {}) end

--============================================================
-- 1. V1 → V3
--============================================================

test("v1 fixture migrates through the full chain to v3", function()
    local sample = fixture("migration_v1.ugc.json")
    local version = sample.document.header.schemaVersion
    equal(version, 1, "fixture is a v1 document")

    local migrated, report = Migrations.Migrate(sample.document)
    check(migrated, tostring(report))
    equal(report.from, 1, "report.from")
    equal(report.to, 3, "report.to")
    equal(#report.applied, 2, "two steps applied")
    equal(report.applied[1], "1 -> 2", "first step")
    equal(report.applied[2], "2 -> 3", "second step")
    equal(migrated.header.schemaVersion, 3, "schemaVersion upgraded")
    equal(migrated.header.contentVersion, "1", "contentVersion filled")

    local first = migrated.entities[1]
    equal(first.sceneID, 1, "sceneID recovered from the v1 'id' field")
    equal(first.id, nil, "v1 field removed")
    equal(first.prefabName, "Box", "prefabName recovered from 'prefab'")
    equal(first.prefab, nil, "v1 prefab field removed")
    equal(#first.transform, 9, "transform recovered from 't'")
    equal(first.t, nil, "v1 transform field removed")
    equal(first.entityId, "ugc-legacy-v1-entity-1", "entityId synthesized from documentId")
    equal(first.actorId, "actor_1", "actorId synthesized")
    equal(first.programId, "actor_prog_1", "programId synthesized")
    equal(first.external, false, "external defaults to false")
    equal(type(first.tags), "table", "tags container added")
    equal(type(first.properties), "table", "properties container added")
    equal(type(first.metadata), "table", "metadata container added")

    local second = migrated.entities[2]
    equal(second.external, true, "existing external flag preserved")
    equal(second.metadata.kind, "pcg", "metadata preserved")
    equal(second.metadata.seed, 42, "metadata payload preserved")

    equal(migrated.nextSceneID, 3, "nextSceneID derived from max sceneID")
    equal(migrated.nextBatchID, 1, "nextBatchID defaulted")
    equal(type(migrated.generatedGroups), "table", "groups container added")
    equal(type(migrated.worldSettings), "table", "world settings container added")
    equal(migrated.programs.level_main.nodes[1].id, "root", "programs untouched")
end)

--============================================================
-- 2. V2 → V3
--============================================================

test("v2 fixture migrates containers, flags and dangling references", function()
    local sample = fixture("migration_v2.ugc.json")
    equal(sample.document.header.schemaVersion, 2, "fixture is a v2 document")

    local migrated, report = Migrations.Migrate(sample.document)
    check(migrated, tostring(report))
    equal(report.from, 2, "report.from")
    equal(#report.applied, 1, "one step applied")
    equal(report.applied[1], "2 -> 3", "step name")
    equal(report.notes.droppedGroupMembers, 1, "dangling group member dropped")
    equal(report.notes.droppedWorldRules, 1, "non numeric world rule dropped")

    equal(migrated.header.schemaVersion, 3, "schemaVersion upgraded")
    equal(migrated.header.contentVersion, "1", "contentVersion filled")
    equal(migrated.entities[1].tags ~= nil, true, "tags container added")
    equal(migrated.entities[3].metadata ~= nil, true, "metadata container added")
    equal(migrated.entities[2].external, true, "numeric flag 1 normalizes to true")
    equal(migrated.entities[2].metadata.seed, 7, "metadata payload preserved")

    local members = migrated.generatedGroups.batch_1
    equal(#members, 2, "string member normalized, dangling member dropped")
    equal(members[1], 1, "member 1")
    equal(members[2], 2, "member 2 came from the string \"2\"")
    equal(migrated.worldSettings.GravityScale, 1.5, "numeric string coerced to number")
    equal(migrated.worldSettings.Broken, nil, "invalid rule dropped")
    equal(migrated.nextSceneID, 4, "existing nextSceneID preserved")
    equal(migrated.nextBatchID, 2, "existing nextBatchID preserved")
end)

--============================================================
-- 3/4. 空操作与幂等
--============================================================

test("current version is a no-op and migration is idempotent", function()
    local sample = fixture("migration_v2.ugc.json")
    local migrated, report = Migrations.Migrate(sample.document)
    check(migrated, tostring(report))

    local again, second = Migrations.Migrate(migrated)
    check(again, tostring(second))
    equal(#second.applied, 0, "no step applied for the current version")
    equal(second.from, Migrations.CURRENT, "report.from is the current version")
    equal(second.notes.unchanged, true, "report marks the no-op")
    equal(encode(again), encode(migrated), "migrate(migrate(x)) == migrate(x)")

    -- 已经是 v3 的文档同样逐字节不变（golden 回归依赖这一点）
    local current = fixture("migration_v1.ugc.json")
    local v3, _ = Migrations.Migrate(current.document)
    local same, _ = Migrations.Migrate(v3)
    equal(encode(same), encode(v3), "v3 documents pass through untouched")
end)

--============================================================
-- 5/6. 失败与回滚语义
--============================================================

test("unknown schema versions are rejected without touching the input", function()
    local sample = fixture("migration_v2.ugc.json")
    local doc = sample.document
    doc.header.schemaVersion = 9
    local before = encode(doc)

    local migrated, err = Migrations.Migrate(doc)
    check(not migrated, "must be rejected")
    check(tostring(err):find("9", 1, true) ~= nil, "error names the version: " .. tostring(err))
    equal(encode(doc), before, "input untouched")
end)

test("a failing step aborts the chain and leaves the input untouched", function()
    local sample = fixture("migration_v2.ugc.json")
    local doc = sample.document
    local before = encode(doc)

    local originalStep = Migrations.Steps[2]
    Migrations.Steps[2] = function() error("injected failure") end
    local migrated, err = Migrations.Migrate(doc)
    Migrations.Steps[2] = originalStep

    check(not migrated, "chain must fail")
    check(tostring(err):find("injected failure", 1, true) ~= nil, "error surfaces the step failure")
    equal(encode(doc), before, "input untouched after a failed step")

    local recovered = Migrations.Migrate(doc)
    check(recovered, "chain works again once the step is restored")
end)

--============================================================
-- 7. Document 入口
--============================================================

test("Document.FromSnapshot runs the migration chain", function()
    local sample = fixture("migration_v1.ugc.json")
    local doc, err = Document.FromSnapshot(sample.document)
    check(doc, tostring(err))
    equal(doc.header.schemaVersion, Migrations.CURRENT, "loaded document is current")
    equal(doc:Count(), 2, "entities loaded")
    equal(doc:GetEntity(1).prefabName, "Box", "entity fields usable after migration")
    equal(doc:GetEntity(1).entityId, "ugc-legacy-v1-entity-1", "stable entityId")

    -- 迁移后仍然要过校验：非法 sceneID 会被拒
    local broken = fixture("migration_v1.ugc.json")
    broken.document.entities[1].id = 0
    local rejected, rejectError = Document.FromSnapshot(broken.document)
    check(not rejected, "invalid sceneID must be rejected")
    check(tostring(rejectError) ~= "", "rejection carries a reason")
end)

--============================================================
-- 8. 加载路径集成
--============================================================

test("loading a v1 file migrates in memory and never rewrites it", function()
    local fixturePath = FIXTURE_DIR .. "/migration_v1.ugc.json"
    local before = readRaw(fixturePath)

    local loaded, chosen, info = Persistence:LoadProject(fixturePath, scene)
    check(loaded, tostring(chosen))
    equal(chosen, fixturePath, "loads the requested file")
    equal(scene.loaded.document.header.schemaVersion, Migrations.CURRENT, "in-memory document is migrated")
    equal(scene.loaded.document.entities[1].prefabName, "Box", "migrated entities")
    check(info and info.migration and info.migration.from == 1, "load reports the migration")
    equal(readRaw(fixturePath), before, "the fixture on disk is byte-identical after loading")
end)

--============================================================
-- 9. 显式迁移写回
--============================================================

test("MigrateProject writes v3 atomically and keeps the pre-migration copy", function()
    local target = tempDir .. "/migrate_project.ugc.json"
    os.remove(target); os.remove(target .. ".bak"); os.remove(target .. ".bak1")
    local original = readRaw(FIXTURE_DIR .. "/migration_v2.ugc.json")
    writeRaw(target, original)

    local ok, report, writtenPath = Persistence:MigrateProject(target)
    check(ok, tostring(report))
    equal(writtenPath, target, "migration writes back to the same path")
    equal(report.from, 2, "report.from")
    equal(report.applied[1], "2 -> 3", "step applied")

    local migrated = json.decode(readRaw(target))
    equal(migrated.document.header.schemaVersion, Migrations.CURRENT, "file now holds v3")
    equal(migrated.document.entities[2].external, true, "flag normalized on disk")
    equal(migrated.packageVersion, Persistence.PACKAGE_VERSION, "package version kept")
    equal(readRaw(target .. ".bak"), original, "pre-migration content kept as .bak")

    -- 二次调用：无需迁移，不再写盘
    local beforeSecond = readRaw(target)
    local okSecond, reportSecond = Persistence:MigrateProject(target)
    check(okSecond, tostring(reportSecond))
    equal(#reportSecond.applied, 0, "second call is a no-op")
    equal(readRaw(target), beforeSecond, "no write when nothing to migrate")

    -- 失败路径：未知版本 → 拒绝且文件保持原样
    local broken = tempDir .. "/migrate_broken.ugc.json"
    local brokenPackage = json.decode(original)
    brokenPackage.document.header.schemaVersion = 9
    writeRaw(broken, encode(brokenPackage))
    local brokenBefore = readRaw(broken)

    local okBroken, brokenError = Persistence:MigrateProject(broken)
    check(not okBroken, "unsupported version must be rejected")
    check(tostring(brokenError) ~= "", "rejection carries a reason")
    equal(readRaw(broken), brokenBefore, "failed migration leaves the file untouched")
    check(not storage:FileExists(broken .. ".bak"), "failed migration writes no backup either")

    os.remove(target); os.remove(target .. ".bak"); os.remove(target .. ".bak1")
    os.remove(broken); os.remove(broken .. ".bak")
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
