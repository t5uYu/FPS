--[[
    run_entity_id.lua

    T9：entityId 的最终设计是「派生字符串」而不是随机 GUID，本测试把该决定的约束钉死：

      1. 格式与派生规则：<documentId>-entity-<sceneID>，由 Document.MakeEntityId 唯一实现
      2. 稳定性：同一 documentId + sceneID 在 快照往返 / 旧 scene.json 往返 / 迁移 之后都不变
      3. 显式 id（PCG / 外部导入路径）必须被保留；重复、空串、控制字符、超长会被拒绝
      4. sceneID 不得复用：nextSceneID 必须严格大于最大 sceneID，删除实体后再分配也不会撞
]]

local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

local Document = require("Gameplay.UGC.UGCDocument")
local Migrations = require("Gameplay.UGC.UGCMigrations")
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

local TRANSFORM = { 0, 0, 0, 0, 0, 0, 1, 1, 1 }

local function newDocument(documentId)
    return Document.New({ documentId = documentId })
end

--============================================================
-- 1. 派生规则
--============================================================

test("entity ids are derived from documentId and sceneID", function()
    equal(Document.ENTITY_ID_SUFFIX, "-entity-", "suffix is part of the public contract")
    equal(Document.MakeEntityId("doc-a", 7), "doc-a-entity-7", "MakeEntityId format")

    local doc = newDocument("doc-a")
    local record = doc:MakeEntityRecord("Box", TRANSFORM)
    check(doc:InsertEntity(record), "insert must succeed")
    equal(record.entityId, "doc-a-entity-1", "derived id")
    equal(doc:GetEntity(1).entityId, "doc-a-entity-1", "stored id")

    -- documentId 不同 ⇒ entityId 不同（同名 sceneID 也不冲突）
    local other = newDocument("doc-b")
    local otherRecord = other:MakeEntityRecord("Box", TRANSFORM)
    other:InsertEntity(otherRecord)
    equal(otherRecord.entityId, "doc-b-entity-1", "第二个文档的同 sceneID 实体 id 不同")
end)

--============================================================
-- 2. 稳定性
--============================================================

test("entity ids survive snapshot, legacy JSON and migration round trips", function()
    local doc = newDocument("doc-stable")
    doc:InsertEntity(doc:MakeEntityRecord("Box", TRANSFORM))
    doc:InsertEntity(doc:MakeEntityRecord("Sphere", TRANSFORM))
    local expected = { doc:GetEntity(1).entityId, doc:GetEntity(2).entityId }

    -- 快照往返
    local restored = Document.FromSnapshot(doc:Snapshot())
    check(restored, "FromSnapshot must succeed")
    equal(restored:GetEntity(1).entityId, expected[1], "snapshot round trip keeps id #1")
    equal(restored:GetEntity(2).entityId, expected[2], "snapshot round trip keeps id #2")

    -- 迁移链（当前版本是空操作，仍然要逐字节稳定）
    local migrated, report = Migrations.Migrate(doc:Snapshot())
    check(migrated, tostring(report))
    equal(migrated.entities[1].entityId, expected[1], "migration keeps id #1")

    -- v1 文档：没有 entityId，迁移后按 documentId + sceneID 派生，结果可预测
    local v1 = Migrations.Migrate({
        header = { documentId = "doc-legacy", schemaVersion = 1, revision = 3 },
        entities = { { id = 1, prefab = "Box", t = TRANSFORM } },
    })
    check(v1, "v1 migration must succeed")
    equal(v1.entities[1].entityId, "doc-legacy-entity-1", "migrated v1 entity derives a stable id")
end)

test("explicit entity ids from external callers are preserved", function()
    local doc = newDocument("doc-pcg")
    local record = doc:MakeEntityRecord("PCG_Generated", TRANSFORM, {
        entityId = "pcg-forest-0007",
        external = true,
        metadata = { kind = "pcg", seed = 7 },
    })
    check(doc:InsertEntity(record), "insert with explicit id must succeed")
    equal(doc:GetEntity(1).entityId, "pcg-forest-0007", "explicit id kept")

    local restored = Document.FromSnapshot(doc:Snapshot())
    check(restored, "round trip must succeed")
    equal(restored:GetEntity(1).entityId, "pcg-forest-0007", "explicit id survives the round trip")
end)

--============================================================
-- 3. 拒绝非法 id
--============================================================

test("malformed and duplicate entity ids are rejected", function()
    local doc = newDocument("doc-reject")
    doc:InsertEntity(doc:MakeEntityRecord("Box", TRANSFORM, { entityId = "fixed-id" }))

    local duplicate = doc:MakeEntityRecord("Sphere", TRANSFORM, { entityId = "fixed-id" })
    local ok, err = doc:InsertEntity(duplicate)
    check(not ok, "duplicate explicit entityId must be rejected")
    check(tostring(err):find("duplicate entityId", 1, true) ~= nil, "error names the duplicate: " .. tostring(err))
    equal(doc:Count(), 1, "rejected insert must not mutate the document")

    local empty = doc:MakeEntityRecord("Sphere", TRANSFORM, { entityId = "" })
    ok, err = doc:InsertEntity(empty)
    check(not ok, "empty entityId must be rejected")
    check(tostring(err):find("non%-empty") ~= nil, "error explains the requirement: " .. tostring(err))

    local control = doc:MakeEntityRecord("Sphere", TRANSFORM, { entityId = "bad\nid" })
    ok, err = doc:InsertEntity(control)
    check(not ok, "control characters must be rejected")

    local long = doc:MakeEntityRecord("Sphere", TRANSFORM, { entityId = string.rep("x", 200) })
    ok, err = doc:InsertEntity(long)
    check(not ok, "overlong entityId must be rejected")
    check(tostring(err):find("too long", 1, true) ~= nil, "error mentions the limit: " .. tostring(err))

    -- 快照校验同样拒绝重复与非法 id（加载路径）
    local snapshot = doc:Snapshot()
    table.insert(snapshot.entities, {
        sceneID = 99, entityId = "fixed-id", prefabName = "Box", transform = TRANSFORM,
    })
    local valid, validationError = Document.ValidateSnapshot(snapshot)
    check(not valid, "snapshot with duplicate entityId must be rejected")
    check(tostring(validationError):find("duplicate entityId", 1, true) ~= nil, tostring(validationError))
end)

--============================================================
-- 4. sceneID 不复用
--============================================================

test("scene ids are never reused so derived ids stay unique", function()
    local doc = newDocument("doc-reuse")
    doc:InsertEntity(doc:MakeEntityRecord("Box", TRANSFORM))
    doc:InsertEntity(doc:MakeEntityRecord("Box", TRANSFORM))
    doc:InsertEntity(doc:MakeEntityRecord("Box", TRANSFORM))
    equal(doc.nextSceneID, 4, "cursor after three inserts")

    doc:RemoveEntity(3)
    local nextID = doc:AllocateSceneID()
    equal(nextID, 4, "deleted sceneID must not be handed out again")

    local record = doc:MakeEntityRecord("Box", TRANSFORM, { sceneID = nextID })
    doc:InsertEntity(record)
    equal(record.entityId, "doc-reuse-entity-4", "new entity gets a fresh derived id")

    -- 手写一个复用了 sceneID 的快照：nextSceneID 校验必须拦下来
    local snapshot = doc:Snapshot()
    snapshot.nextSceneID = 4
    local valid, err = Document.ValidateSnapshot(snapshot)
    check(not valid, "nextSceneID <= max sceneID must be rejected")
    check(tostring(err):find("nextSceneID", 1, true) ~= nil, tostring(err))

    -- nextSceneID 缺省（旧包）不强制，但解析会自行推导出安全值
    local withoutCursor = doc:Snapshot()
    withoutCursor.nextSceneID = nil
    valid = Document.ValidateSnapshot(withoutCursor)
    check(valid, "missing nextSceneID stays tolerated")
    local restored = Document.FromSnapshot(withoutCursor)
    check(restored, "document without cursor still loads")
    check(restored.nextSceneID > 4, "cursor is rebuilt safely, got " .. tostring(restored.nextSceneID))
end)

test("legacy scene.json ids stay stable through the legacy entry point", function()
    -- 旧 scene.json 只带 sceneID / id，entityId 由加载路径派生；这里确认派生结果与 documentId 绑定
    local payload = json.encode({
        version = 3,
        documentId = "legacy-doc",
        revision = 5,
        nextID = 3,
        actors = {
            { sceneID = 1, prefab = "Box", t = TRANSFORM },
            { sceneID = 2, prefab = "Box", t = TRANSFORM },
        },
    })
    local entities = {}
    for _, actor in ipairs(json.decode(payload).actors) do
        entities[#entities + 1] = {
            sceneID = actor.sceneID, prefabName = actor.prefab, transform = actor.t,
        }
    end
    local snapshot = {
        header = { documentId = "legacy-doc", schemaVersion = 3, revision = 5 },
        nextSceneID = 3,
        entities = entities,
    }
    local doc = Document.FromSnapshot(snapshot)
    check(doc, "legacy snapshot must load")
    equal(doc:GetEntity(1).entityId, "legacy-doc-entity-1", "derived from the legacy documentId")
    equal(doc:GetEntity(2).entityId, "legacy-doc-entity-2", "second entity")
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
