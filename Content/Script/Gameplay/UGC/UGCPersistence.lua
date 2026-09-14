--[[
    UGCPersistence.lua

    Versioned, atomic persistence provider for UGC projects. UI supplies a path;
    this service owns all file IO, legacy migration, backup rotation and autosave.

    T14 备份轮转 / 自动保存 / 崩溃恢复：
      * 世代布局：<file>.bak（最新一代，C++ 原子写自己就会维护）→ <file>.bak1 → <file>.bak2 …
        轮转只用「读 + 原子写」，不依赖 rename/delete，所以轮转中途崩溃最坏只是备份过期，
        主文件永远是原子的那一份。
      * 自动保存：AttachProject 绑定项目后由 Tick(deltaSeconds) 驱动，受 intervalSeconds 与
        minIntervalSeconds 双重节流，并且只在文档 revision 相对上次保存发生变化时才真的写盘。
      * 崩溃恢复：LoadProject 在主文件不可解码/校验失败时，按世代顺序回退到最近一个「可解码且
        校验通过」的备份；RestoreFromBackup 提供显式恢复入口（不覆盖主文件，由下一次保存提交）。

    T15 迁移链：LoadProject / MigrateProject 走 UGCMigrations 的显式 V1 → V2 → V3 链；
    迁移失败时既不写盘也不改动内存里的文档，原文件保持原样。
]]

local json = require("Util.json")
local Log = require("Gameplay.UGC.UGCLog")
local Migrations = require("Gameplay.UGC.UGCMigrations")

local Persistence = {}
Persistence.__index = Persistence

local PROJECT_FILE = "project.ugc.json"
local PACKAGE_VERSION = 1
local BACKUP_SUFFIX = ".bak"

local MAX_BACKUP_GENERATIONS = 9
local DEFAULT_BACKUP_GENERATIONS = 3
local DEFAULT_AUTOSAVE = {
    enabled = true,
    intervalSeconds = 120,
    minIntervalSeconds = 30,
}

local _storage = nil
local _backupGenerations = DEFAULT_BACKUP_GENERATIONS
local _autosave = {
    enabled = DEFAULT_AUTOSAVE.enabled,
    intervalSeconds = DEFAULT_AUTOSAVE.intervalSeconds,
    minIntervalSeconds = DEFAULT_AUTOSAVE.minIntervalSeconds,
}
local _autosaveState = {
    elapsedSeconds = 0,
    sinceLastSaveSeconds = 0,
    projectPath = nil,
    sceneData = nil,
    editorStateProvider = nil,
    lastSavedRevision = nil,
}

local function normalize(path)
    return tostring(path or ""):gsub("\\", "/")
end

local function dirname(path)
    return normalize(path):match("^(.*/)") or ""
end

local function readFile(path)
    if not _storage then return nil, "storage unavailable" end
    if not _storage:FileExists(path) then return nil, "file not found" end
    return tostring(_storage:ReadTextFile(path))
end

local function atomicWrite(path, content)
    if not _storage then return false, "UGCStorageBridge 未初始化" end
    path = normalize(path)
    if not _storage:WriteTextFileAtomic(path, content) then
        return false, "UGCStorageBridge 原子写入失败"
    end
    return true
end

--- 存档包里的 documentId（用于日志关联；stub 场景下可能拿不到）
local function documentIdOf(sceneData)
    if not sceneData or not sceneData.GetDocument then return nil end
    local ok, doc = pcall(sceneData.GetDocument, sceneData)
    if ok and type(doc) == "table" and doc.header then return doc.header.documentId end
    return nil
end

local function entityCountOf(sceneData)
    if not sceneData or not sceneData.Count then return nil end
    local ok, count = pcall(sceneData.Count, sceneData)
    if ok then return count end
    return nil
end

local function revisionOf(sceneData)
    if not sceneData or not sceneData.GetRevision then return nil end
    local ok, revision = pcall(sceneData.GetRevision, sceneData)
    if ok then return revision end
    if sceneData.GetDocument then
        local okDoc, doc = pcall(sceneData.GetDocument, sceneData)
        if okDoc and type(doc) == "table" and doc.header then return doc.header.revision end
    end
    return nil
end

--============================================================
-- 备份世代
--============================================================

--- 世代 1 = <file>.bak（C++ 原子写维护的最新一代），世代 i>1 = <file>.bak(i-1)
local function backupPath(path, generation)
    if generation <= 1 then return path .. BACKUP_SUFFIX end
    return path .. BACKUP_SUFFIX .. tostring(generation - 1)
end

--- 备份轮转：只做「读上一代 + 原子写下一代」，所以在没有 rename/delete 的存储边界上也成立。
local function rotateBackups(path)
    local generations = _backupGenerations
    for generation = generations, 2, -1 do
        local source = backupPath(path, generation - 1)
        if _storage and _storage:FileExists(source) then
            local content = tostring(_storage:ReadTextFile(source))
            if content ~= "" and not _storage:WriteTextFileAtomic(backupPath(path, generation), content) then
                return false, "备份写入失败: " .. backupPath(path, generation)
            end
        end
    end
    return true
end

--- 候选路径：主文件（generation 0）→ .bak → .bak1 → …，按「从新到旧」排序
local function candidatePaths(path)
    local list = { { path = path, generation = 0 } }
    for generation = 1, _backupGenerations do
        list[#list + 1] = { path = backupPath(path, generation), generation = generation }
    end
    return list
end

--============================================================
-- 包校验与迁移（纯检查，不接触 SceneData 状态）
--============================================================

local function inspectPackage(encoded)
    local package = json.decode(encoded)
    if type(package) ~= "table" or type(package.document) ~= "table" then
        return nil, "invalid_project_file", "所选 JSON 不是有效的 UGC 项目文件"
    end
    if tonumber(package.packageVersion) ~= PACKAGE_VERSION then
        return nil, "unsupported_package", "不支持的 UGC packageVersion: " .. tostring(package.packageVersion)
    end
    local document, report = Migrations.Migrate(package.document)
    if not document then
        return nil, "migration_failed", tostring(report)
    end
    package.document = document
    return package, nil, nil, report
end

--============================================================
-- 生命周期与配置
--============================================================

function Persistence:Init(storageBridge)
    _storage = storageBridge
    _autosaveState.elapsedSeconds = 0
    _autosaveState.sinceLastSaveSeconds = 0
end

function Persistence:ConfigureBackups(generations)
    local value = tonumber(generations) or DEFAULT_BACKUP_GENERATIONS
    if value < 1 then value = 1 end
    if value > MAX_BACKUP_GENERATIONS then value = MAX_BACKUP_GENERATIONS end
    _backupGenerations = math.floor(value)
    return _backupGenerations
end

function Persistence:GetBackupGenerations()
    return _backupGenerations
end

function Persistence:GetBackupPath(path, generation)
    return backupPath(normalize(path), generation or 1)
end

--- 自动保存策略：{ enabled, intervalSeconds, minIntervalSeconds }
function Persistence:ConfigureAutosave(options)
    options = options or {}
    if options.enabled ~= nil then _autosave.enabled = options.enabled == true end
    if tonumber(options.intervalSeconds) then
        _autosave.intervalSeconds = math.max(1, tonumber(options.intervalSeconds))
    end
    if tonumber(options.minIntervalSeconds) then
        _autosave.minIntervalSeconds = math.max(0, tonumber(options.minIntervalSeconds))
    end
    return self:GetAutosaveConfig()
end

function Persistence:GetAutosaveConfig()
    return {
        enabled = _autosave.enabled,
        intervalSeconds = _autosave.intervalSeconds,
        minIntervalSeconds = _autosave.minIntervalSeconds,
    }
end

--- 绑定当前项目：自动保存需要知道「往哪写」和「怎么取 editorState」
--- @param folderOrFile string 项目路径或目录
--- @param sceneData table SceneData facade
--- @param editorStateProvider function|table|nil 返回 editorState 的函数，或固定 table
function Persistence:AttachProject(folderOrFile, sceneData, editorStateProvider)
    local path = self:GetProjectPath(folderOrFile)
    _autosaveState.projectPath = path
    _autosaveState.sceneData = sceneData
    _autosaveState.editorStateProvider = editorStateProvider
    _autosaveState.elapsedSeconds = 0
    _autosaveState.sinceLastSaveSeconds = 0
    _autosaveState.lastSavedRevision = revisionOf(sceneData)
    Log.Info("project_attached", { path = path, revision = _autosaveState.lastSavedRevision })
    return path
end

function Persistence:DetachProject()
    _autosaveState.projectPath = nil
    _autosaveState.sceneData = nil
    _autosaveState.editorStateProvider = nil
    _autosaveState.lastSavedRevision = nil
    _autosaveState.elapsedSeconds = 0
    _autosaveState.sinceLastSaveSeconds = 0
end

function Persistence:GetAttachedPath()
    return _autosaveState.projectPath
end

local function editorStateFrom(provider)
    if type(provider) == "function" then
        local ok, value = pcall(provider)
        if ok and type(value) == "table" then return value end
        return {}
    end
    if type(provider) == "table" then return provider end
    return {}
end

--- 自动保存调度：由宿主 Tick 驱动（UGCPlayerController:ReceiveTick）。
--- 只有「interval 到期 + 距上次写盘超过 minInterval + revision 变了」才会真的写。
--- @return boolean saved, string|nil detail（savedDetail）
function Persistence:Tick(deltaSeconds)
    local delta = tonumber(deltaSeconds) or 0
    if delta < 0 then delta = 0 end
    _autosaveState.elapsedSeconds = _autosaveState.elapsedSeconds + delta
    _autosaveState.sinceLastSaveSeconds = _autosaveState.sinceLastSaveSeconds + delta

    if not _autosave.enabled then return false, "disabled" end
    if not _autosaveState.projectPath or not _autosaveState.sceneData then return false, "detached" end
    if _autosaveState.elapsedSeconds < _autosave.intervalSeconds then return false, "interval" end
    if _autosaveState.sinceLastSaveSeconds < _autosave.minIntervalSeconds then return false, "throttled" end

    local revision = revisionOf(_autosaveState.sceneData)
    if revision ~= nil and revision == _autosaveState.lastSavedRevision then
        return false, "unchanged"
    end

    local ok, path = self:SaveProject(
        _autosaveState.projectPath,
        _autosaveState.sceneData,
        editorStateFrom(_autosaveState.editorStateProvider))
    _autosaveState.elapsedSeconds = 0
    if not ok then
        Log.Error("save_failed", "自动保存失败", { path = _autosaveState.projectPath, autosave = true })
        return false, "failed"
    end
    _autosaveState.sinceLastSaveSeconds = 0
    _autosaveState.lastSavedRevision = revision
    Log.Info("autosave_committed", { path = path, revision = revision })
    return true, path
end

function Persistence:GetAutosaveRuntime()
    return {
        elapsedSeconds = _autosaveState.elapsedSeconds,
        sinceLastSaveSeconds = _autosaveState.sinceLastSaveSeconds,
        projectPath = _autosaveState.projectPath,
        lastSavedRevision = _autosaveState.lastSavedRevision,
    }
end

--============================================================
-- 保存 / 加载
--============================================================

function Persistence:GetProjectPath(folderOrFile)
    local path = normalize(folderOrFile)
    if path == "" then return PROJECT_FILE end
    if path:lower():match("%.json$") then return path end
    if path:sub(-1) ~= "/" then path = path .. "/" end
    return path .. PROJECT_FILE
end

function Persistence:SaveProject(folderOrFile, sceneData, editorState)
    if not sceneData or not sceneData.SerializePackageTable then
        Log.Error("not_initialized", "SceneData 不支持版本化存档")
        return false, "SceneData 不支持版本化存档"
    end
    local package = sceneData:SerializePackageTable(editorState or {})
    package.packageVersion = PACKAGE_VERSION
    local encoded = json.encode(package, "  ")
    local decoded = json.decode(encoded)
    if type(decoded) ~= "table" or type(decoded.document) ~= "table" then
        Log.Error("serialization_failed", "存档序列化自检失败")
        return false, "存档序列化自检失败"
    end
    local path = self:GetProjectPath(folderOrFile)

    -- 先把既有世代往后推一格，再提交主文件：这样 .bak 永远是「上一次成功保存」的内容，
    -- 轮转中途崩溃最坏只是丢一代更旧的备份，主文件与最新备份都不受影响。
    local rotated, rotateError = rotateBackups(path)
    if not rotated then
        Log.Warn("backup_rotation_failed", { path = path, reason = tostring(rotateError) })
    end

    local ok, err = atomicWrite(path, encoded)
    if not ok then
        Log.Error("save_failed", err, { path = path })
        return false, err
    end

    sceneData:ClearDirty()
    if _autosaveState.projectPath == path then
        _autosaveState.lastSavedRevision = revisionOf(sceneData)
        _autosaveState.sinceLastSaveSeconds = 0
    end
    Log.Info("project_saved", {
        path = path,
        bytes = #encoded,
        entities = entityCountOf(sceneData),
        document = documentIdOf(sceneData),
        backups = _backupGenerations,
    })
    return true, path
end

--- 主路径加载：主文件 → 备份世代（从新到旧）
--- @return boolean ok, string message|path, table|nil info
---   info = { recovered = bool, generation = number, from = string, reason = string|nil, migration = report|nil }
function Persistence:LoadProject(selectedPath, sceneData)
    local selected = normalize(selectedPath)
    local folder = dirname(selected)
    local selectedName = selected:match("([^/]+)$") or ""
    local isJsonTarget = selected:lower():match("%.json$") ~= nil

    if isJsonTarget then
        local failures = {}
        for _, candidate in ipairs(candidatePaths(selected)) do
            if _storage and _storage:FileExists(candidate.path) then
                local content = tostring(_storage:ReadTextFile(candidate.path))
                local package, code, message, report = inspectPackage(content)
                if not package then
                    failures[#failures + 1] = string.format("%s: %s", candidate.path, tostring(message))
                    if candidate.generation == 0 then
                        Log.Error(code or "load_failed", tostring(message), { path = candidate.path })
                    else
                        Log.Warn("backup_candidate_rejected", {
                            path = candidate.path, generation = candidate.generation, reason = tostring(message),
                        })
                    end
                else
                    local loaded, loadMessage = sceneData:DeserializePackageTable(package)
                    if loaded then
                        local info = {
                            recovered = candidate.generation ~= 0,
                            generation = candidate.generation,
                            from = candidate.path,
                            reason = failures[1],
                            migration = report,
                        }
                        if info.recovered then
                            Log.Warn("project_recovered", {
                                path = selected,
                                from = candidate.path,
                                generation = candidate.generation,
                                reason = tostring(failures[1] or ""),
                            })
                        end
                        if report and #(report.applied or {}) > 0 then
                            Log.Info("project_migrated", {
                                path = candidate.path, from = report.from, to = report.to,
                                steps = table.concat(report.applied, ","),
                                droppedGroupMembers = report.notes and report.notes.droppedGroupMembers or 0,
                            })
                        end
                        Log.Info("project_loaded", {
                            path = candidate.path, version = PACKAGE_VERSION, legacy = false,
                            recovered = info.recovered,
                            entities = entityCountOf(sceneData), document = documentIdOf(sceneData),
                        })
                        return loaded, candidate.path, info
                    end
                    failures[#failures + 1] = string.format("%s: %s", candidate.path, tostring(loadMessage))
                    Log.Error("load_failed", tostring(loadMessage), { path = candidate.path })
                end
            end
        end

        -- 指定了具体 .json 文件却一个候选都不存在时，仍回退到目录级/旧格式流程
        if #failures > 0 then
            Log.Error("recovery_failed", "存档与所有备份都不可用", {
                path = selected, backups = _backupGenerations, attempts = #failures,
            })
            return false, table.concat(failures, " | ")
        end
    end

    local directContent = isJsonTarget and readFile(selected) or nil

    if not directContent then
        local projectPath = folder .. PROJECT_FILE
        local content = readFile(projectPath)
        if content then
            local package, code, message, report = inspectPackage(content)
            if not package then
                Log.Error(code, message, { path = projectPath })
                return false, message
            end
            local loaded, loadMessage = sceneData:DeserializePackageTable(package)
            if not loaded then
                Log.Error("load_failed", loadMessage, { path = projectPath })
                return false, loadMessage
            end
            if report and #(report.applied or {}) > 0 then
                Log.Info("project_migrated", {
                    path = projectPath, from = report.from, to = report.to,
                    steps = table.concat(report.applied, ","),
                })
            end
            Log.Info("project_loaded", {
                path = projectPath, version = PACKAGE_VERSION, legacy = false,
                entities = entityCountOf(sceneData), document = documentIdOf(sceneData),
            })
            return loaded, projectPath, { recovered = false, generation = 0, from = projectPath }
        end
    end

    if directContent then
        local package, code, message = inspectPackage(directContent)
        if not package then
            Log.Error(code, message, { path = selected })
            return false, message
        end
        local loaded, loadMessage = sceneData:DeserializePackageTable(package)
        if not loaded then
            Log.Error("load_failed", loadMessage, { path = selected })
            return false, loadMessage
        end
        return loaded, selected, { recovered = false, generation = 0, from = selected }
    end

    if directContent then
        local package, code, message = inspectPackage(directContent)
        if not package then
            Log.Error(code, message, { path = selected })
            return false, message
        end
        local loaded, loadMessage = sceneData:DeserializePackageTable(package)
        if not loaded then
            Log.Error("load_failed", loadMessage, { path = selected })
            return false, loadMessage
        end
        return loaded, selected, { recovered = false, generation = 0, from = selected }
    end

    -- Legacy v2 layout: scene.json + programs.json + editor.json.
    local sceneJSON, err = directContent or readFile(folder .. "scene.json")
    if not sceneJSON then
        Log.Error("load_failed", "找不到 project.ugc.json 或 scene.json", { folder = folder, reason = err })
        return false, "找不到 project.ugc.json 或 scene.json: " .. tostring(err or "")
    end
    local ok, message = sceneData:DeserializeFromJSON(sceneJSON)
    if not ok then
        Log.Error("legacy_load_failed", message, { path = folder .. "scene.json" })
        return false, message or "旧版 scene.json 加载失败"
    end

    local programsJSON = readFile(folder .. "programs.json")
    if programsJSON then sceneData:DeserializeProgramsJSON(programsJSON) end
    sceneData:ClearDirty()
    Log.Info("project_loaded", {
        path = folder .. "scene.json", legacy = true, programs = programsJSON ~= nil,
        entities = entityCountOf(sceneData), document = documentIdOf(sceneData),
    })
    return true, folder .. "scene.json", { recovered = false, generation = nil, from = folder .. "scene.json", legacy = true }
end

--- 显式崩溃恢复入口：从备份世代里挑一个可用的加载进内存，不覆盖主文件。
--- @param generation number|nil 指定世代（1 = .bak）；nil 表示按新到旧找第一个可用
--- @return boolean ok, string message, table|nil info
function Persistence:RestoreFromBackup(folderOrFile, sceneData, generation)
    local path = self:GetProjectPath(folderOrFile)
    local generations = generation and { tonumber(generation) } or {}
    if not generation then
        for index = 1, _backupGenerations do generations[#generations + 1] = index end
    end

    local reason = "没有任何备份世代"
    for _, index in ipairs(generations) do
        local candidate = backupPath(path, index)
        if _storage and _storage:FileExists(candidate) then
            local content = tostring(_storage:ReadTextFile(candidate))
            local package, _, message = inspectPackage(content)
            if package then
                local loaded, loadMessage = sceneData:DeserializePackageTable(package)
                if loaded then
                    Log.Warn("project_recovered", {
                        path = path, from = candidate, generation = index, reason = "explicit restore",
                    })
                    return true, candidate, { recovered = true, generation = index, from = candidate }
                end
                reason = tostring(loadMessage)
            else
                reason = tostring(message)
            end
        end
    end
    Log.Error("recovery_failed", "备份恢复失败", { path = path, reason = reason })
    return false, reason
end

--- 显式迁移：把项目文件迁移到当前版本并原子写回（写前主文件已由 C++ 原子写备份为 .bak）。
--- 迁移失败或无需迁移时不写盘，原文件保持原样。
--- @return boolean ok, table|string report|error, string|nil path
function Persistence:MigrateProject(folderOrFile)
    local path = self:GetProjectPath(folderOrFile)
    local content, err = readFile(path)
    if not content then
        Log.Error("load_failed", "迁移前读取失败: " .. tostring(err), { path = path })
        return false, "迁移前读取失败: " .. tostring(err)
    end

    local package = json.decode(content)
    if type(package) ~= "table" or type(package.document) ~= "table" then
        Log.Error("invalid_project_file", "所选 JSON 不是有效的 UGC 项目文件", { path = path })
        return false, "所选 JSON 不是有效的 UGC 项目文件"
    end
    if tonumber(package.packageVersion) ~= PACKAGE_VERSION then
        Log.Error("unsupported_package", "不支持的 UGC packageVersion", {
            path = path, version = package.packageVersion,
        })
        return false, "不支持的 UGC packageVersion: " .. tostring(package.packageVersion)
    end

    local document, report = Migrations.Migrate(package.document)
    if not document then
        Log.Error("migration_failed", tostring(report), { path = path })
        return false, tostring(report)
    end
    if #(report.applied or {}) == 0 then
        Log.Info("project_migration_skipped", { path = path, version = report.to })
        return true, report, path
    end

    package.document = document
    package.packageVersion = PACKAGE_VERSION
    local encoded = json.encode(package, "  ")
    rotateBackups(path)
    local written, writeError = atomicWrite(path, encoded)
    if not written then
        Log.Error("save_failed", writeError, { path = path })
        return false, writeError
    end
    Log.Info("project_migrated", {
        path = path, from = report.from, to = report.to,
        steps = table.concat(report.applied, ","), bytes = #encoded,
    })
    return true, report, path
end

Persistence.PROJECT_FILE = PROJECT_FILE
Persistence.PACKAGE_VERSION = PACKAGE_VERSION
Persistence.BACKUP_SUFFIX = BACKUP_SUFFIX
Persistence.MAX_BACKUP_GENERATIONS = MAX_BACKUP_GENERATIONS
return Persistence
