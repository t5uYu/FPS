--[[
    run_persistence.lua

    T14：备份轮转 + 自动保存 + 崩溃恢复的回归测试。

    覆盖点：
      1. 精确路径保存（显式 *.ugc.json）+ C++ 原子写留下的单代 .bak
      2. 备份轮转：N 代、新到旧顺序正确（main > .bak > .bak1 > .bak2 …），不超出配置世代数
      3. 自动保存：interval 到期、minInterval 节流、revision 未变不写、禁用与未绑定项目都不写
      4. 崩溃恢复：主文件损坏/缺失时回退到最近一个可用备份，且不覆盖主文件
      5. 存储边界：非存档/非备份后缀被拒绝（镜像 UUGCStorageBridge 放宽后的白名单）

    存储替身刻意镜像 UUGCStorageBridge：后缀白名单 + 临时文件 + 读回校验 + 旧文件挪到 .bak + rename。
]]

local root = assert(arg[1], "workspace root required")
local tempDir = assert(arg[2], "temp dir required"):gsub("\\", "/")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

UE = { UKismetSystemLibrary = { MakeDirectory = function() return true end } }

local Persistence = require("Gameplay.UGC.UGCPersistence")

--============================================================
-- 存储替身（镜像 UUGCStorageBridge 的契约）
--============================================================

--- 与 C++ IsAllowedJsonPath 一致：允许 .json / .bak / .bak<数字>
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
    -- 读回校验（与 C++ 一致）
    if readRaw(tempPath) ~= content then
        os.remove(tempPath)
        return false
    end
    os.remove(backupPath)
    local hadOriginal = self:FileExists(path)
    if hadOriginal and not os.rename(path, backupPath) then
        os.remove(tempPath)
        return false
    end
    if not os.rename(tempPath, path) then
        os.remove(tempPath)
        if hadOriginal then os.rename(backupPath, path) end
        return false
    end
    return true
end

Persistence:Init(storage)

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

--- 清掉主文件与所有可能存在的世代/临时文件
local function clean(path)
    os.remove(path)
    os.remove(path .. ".tmp")
    os.remove(path .. ".bak")
    for generation = 1, Persistence.MAX_BACKUP_GENERATIONS + 1 do
        os.remove(path .. ".bak" .. generation)
    end
end

local function revisionOfFile(path)
    local content = readRaw(path)
    if not content then return nil end
    local decoded = require("Util.json").decode(content)
    if type(decoded) ~= "table" or type(decoded.document) ~= "table" then return nil end
    return decoded.document.header and decoded.document.header.revision
end

--- 假 SceneData：revision 由测试直接控制，其余字段够用即可
local scene = { revision = 0 }
function scene:SerializePackageTable(editor)
    return {
        document = {
            header = { documentId = "persistence-test", schemaVersion = 3, revision = self.revision, contentVersion = "1" },
            nextSceneID = 1,
            nextBatchID = 1,
            entities = {},
            programs = {},
            generatedGroups = {},
            worldSettings = {},
        },
        editor = editor or {},
    }
end
function scene:ClearDirty() self.cleared = (self.cleared or 0) + 1 end
function scene:DeserializePackageTable(package) self.loaded = package; return true, "loaded" end
function scene:GetRevision() return self.revision end
function scene:Count() return 0 end

local function pathFor(name) return tempDir .. "/" .. name end

--============================================================
-- 1. 精确路径保存 + 单代备份（原有用例）
--============================================================

test("exact-path save + single backup generation", function()
    local path = pathFor("named.ugc.json")
    clean(path)
    Persistence:ConfigureBackups(1)

    scene.revision = 1
    local ok, saved = Persistence:SaveProject(path, scene, { activeProgramId = "level_main" })
    check(ok, tostring(saved))
    equal(saved, path, "save must use the exact path")
    check(scene.cleared, "successful save must clear the dirty flag")

    scene.revision = 2
    ok, saved = Persistence:SaveProject(path, scene, { activeProgramId = "level_main" })
    check(ok, tostring(saved))
    check(storage:FileExists(path .. ".bak"), "the previous content must be kept as .bak")
    equal(revisionOfFile(path), 2, "main file holds the newest revision")

    local loaded, loadedPath = Persistence:LoadProject(path, scene)
    check(loaded, tostring(loadedPath))
    equal(loadedPath, path, "load returns the exact path")
    equal(scene.loaded.packageVersion, Persistence.PACKAGE_VERSION, "package version")
    equal(scene.loaded.document.header.revision, 2, "main file revision")
end)

--============================================================
-- 2. 备份轮转
--============================================================

test("backup rotation keeps N generations newest first", function()
    local path = pathFor("rotate.ugc.json")
    clean(path)
    Persistence:ConfigureBackups(3)

    for revision = 1, 4 do
        scene.revision = revision
        local ok, err = Persistence:SaveProject(path, scene, {})
        check(ok, tostring(err))
    end

    equal(revisionOfFile(path), 4, "main = newest")
    equal(revisionOfFile(path .. ".bak"), 3, "generation 1 = previous save")
    equal(revisionOfFile(path .. ".bak1"), 2, "generation 2 = two saves ago")
    equal(revisionOfFile(path .. ".bak2"), 1, "generation 3 = three saves ago")
    check(not storage:FileExists(path .. ".bak3"), "generation count must be bounded by configuration")
end)

test("generation count is configurable and clamped", function()
    equal(Persistence:ConfigureBackups(99), Persistence.MAX_BACKUP_GENERATIONS, "upper clamp")
    equal(Persistence:ConfigureBackups(0), 1, "lower clamp")
    equal(Persistence:ConfigureBackups(nil), 3, "default when unset")
    equal(Persistence:GetBackupGenerations(), 3, "configured value")

    -- 世代数降到 1 后不再写多代备份；磁盘上已有的旧世代不会被删除（存储边界没有 delete）
    local path = pathFor("clamped.ugc.json")
    clean(path)
    Persistence:ConfigureBackups(1)
    for revision = 10, 11 do
        scene.revision = revision
        check((Persistence:SaveProject(path, scene, {})))
    end
    equal(revisionOfFile(path), 11, "main advances")
    equal(revisionOfFile(path .. ".bak"), 10, "single generation still rotates")
    check(not storage:FileExists(path .. ".bak1"), "配置为 1 代时不写第二代")
    Persistence:ConfigureBackups(3)
end)

--============================================================
-- 3. 自动保存
--============================================================

test("autosave respects interval, throttle and revision changes", function()
    local path = pathFor("autosave.ugc.json")
    clean(path)
    Persistence:ConfigureBackups(1)
    Persistence:ConfigureAutosave({ enabled = true, intervalSeconds = 10, minIntervalSeconds = 5 })

    scene.revision = 4
    local attached = Persistence:AttachProject(path, scene, { activeProgramId = "level_main" })
    equal(attached, path, "attach resolves the project path")

    local saved, detail = Persistence:Tick(4)
    check(not saved, "interval not reached")
    equal(detail, "interval", "reason: interval")

    scene.revision = 5
    saved, detail = Persistence:Tick(6)
    check(saved, "interval reached with a revision change must save")
    equal(detail, path, "autosave returns the written path")
    equal(revisionOfFile(path), 5, "autosave wrote the current revision")

    saved, detail = Persistence:Tick(2)
    check(not saved, "elapsed must reset after a save")
    equal(detail, "interval", "reason: interval")

    saved, detail = Persistence:Tick(9)
    check(not saved, "an unchanged revision must not be written again")
    equal(detail, "unchanged", "reason: unchanged")

    -- minInterval 节流：interval 到期但距上次写盘还不够久
    Persistence:ConfigureAutosave({ minIntervalSeconds = 60 })
    scene.revision = 6
    saved, detail = Persistence:Tick(10)
    check(not saved, "throttled by minIntervalSeconds")
    equal(detail, "throttled", "reason: throttled")

    saved, detail = Persistence:Tick(40)
    check(saved, "after the throttle window a pending change is written")
    equal(revisionOfFile(path), 6, "throttled save eventually lands")

    Persistence:ConfigureAutosave({ enabled = false })
    scene.revision = 7
    saved, detail = Persistence:Tick(1000)
    check(not saved, "disabled autosave must not write")
    equal(detail, "disabled", "reason: disabled")

    Persistence:ConfigureAutosave({ enabled = true })
    Persistence:DetachProject()
    saved, detail = Persistence:Tick(1000)
    check(not saved, "detached autosave must not write")
    equal(detail, "detached", "reason: detached")
    equal(revisionOfFile(path), 6, "no write happened for disabled/detached ticks")

    Persistence:ConfigureAutosave({ enabled = true, intervalSeconds = 120, minIntervalSeconds = 30 })
end)

--============================================================
-- 4. 崩溃恢复
--============================================================

test("crash recovery falls back to the newest valid backup", function()
    local path = pathFor("recover.ugc.json")
    clean(path)
    Persistence:ConfigureBackups(3)
    Persistence:ConfigureAutosave({ enabled = false })

    for revision = 1, 3 do
        scene.revision = revision
        check((Persistence:SaveProject(path, scene, {})))
    end
    equal(revisionOfFile(path .. ".bak"), 2, "generation 1 = revision 2")
    equal(revisionOfFile(path .. ".bak1"), 1, "generation 2 = revision 1")

    local broken = "{ this is not a package"
    writeRaw(path, broken)
    local loaded, chosen, info = Persistence:LoadProject(path, scene)
    check(loaded, tostring(chosen))
    equal(chosen, path .. ".bak", "recovered from generation 1")
    check(info and info.recovered, "info marks the recovery")
    equal(info.generation, 1, "recovered generation")
    equal(scene.loaded.document.header.revision, 2, "recovered content is the previous save")
    equal(readRaw(path), broken, "recovery must not overwrite the main file")

    writeRaw(path .. ".bak", broken)
    loaded, chosen = Persistence:LoadProject(path, scene)
    check(loaded, tostring(chosen))
    equal(chosen, path .. ".bak1", "falls through to generation 2")
    equal(scene.loaded.document.header.revision, 1, "generation 2 content")

    writeRaw(path .. ".bak1", broken)
    loaded, chosen = Persistence:LoadProject(path, scene)
    check(not loaded, "all candidates broken must fail")
    check(tostring(chosen):find("recover.ugc.json", 1, true) ~= nil, "failure lists the attempts")

    local restored, reason = Persistence:RestoreFromBackup(path, scene)
    check(not restored, "explicit restore must also fail")
    check(tostring(reason) ~= "", "restore reports a reason")
end)

test("load recovers when the main file is missing", function()
    local path = pathFor("missing.ugc.json")
    clean(path)
    Persistence:ConfigureBackups(2)

    for revision = 1, 2 do
        scene.revision = revision
        check((Persistence:SaveProject(path, scene, {})))
    end
    os.remove(path)
    check(not storage:FileExists(path), "main file removed")

    local loaded, chosen, info = Persistence:LoadProject(path, scene)
    check(loaded, tostring(chosen))
    equal(chosen, path .. ".bak", "recovered from the newest backup")
    check(info and info.recovered and info.generation == 1, "generation info")
    equal(scene.loaded.document.header.revision, 1, "backup content")

    local restored, restoredPath = Persistence:RestoreFromBackup(path, scene, 1)
    check(restored, tostring(restoredPath))
    equal(restoredPath, path .. ".bak", "explicit restore by generation")
end)

--============================================================
-- 5. 存储边界
--============================================================

test("storage boundary only accepts save and backup suffixes", function()
    local path = pathFor("boundary.ugc.json")
    check(storage:WriteTextFileAtomic(path, "{}"), "save suffix allowed")
    check(storage:WriteTextFileAtomic(path .. ".bak1", "{}"), "backup generation suffix allowed")
    check(not storage:WriteTextFileAtomic(path .. ".txt", "{}"), "arbitrary suffix rejected")
    check(not storage:WriteTextFileAtomic(path .. ".bakx", "{}"), "non numeric backup suffix rejected")
    check(not storage:FileExists(path .. ".txt"), "rejected suffix is invisible to reads")
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
