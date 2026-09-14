--[[
    UGCPersistence.lua

    Versioned, atomic persistence provider for UGC projects. UI supplies a path;
    this service owns all file IO and legacy migration.
]]

local json = require("Util.json")
local Log = require("Gameplay.UGC.UGCLog")

local Persistence = {}
Persistence.__index = Persistence

local PROJECT_FILE = "project.ugc.json"
local PACKAGE_VERSION = 1
local _storage = nil

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
function Persistence:Init(storageBridge)

    _storage = storageBridge
end

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
    local ok, err = atomicWrite(path, encoded)
    if not ok then
        Log.Error("save_failed", err, { path = path })
        return false, err
    end
    sceneData:ClearDirty()
    Log.Info("project_saved", {
        path = path,
        bytes = #encoded,
        entities = entityCountOf(sceneData),
        document = documentIdOf(sceneData),
    })
    return true, path
end

function Persistence:LoadProject(selectedPath, sceneData)
    local selected = normalize(selectedPath)
    local folder = dirname(selected)
    local selectedName = selected:match("([^/]+)$") or ""
    local directContent = selected:lower():match("%.json$") and readFile(selected) or nil

    if directContent and selectedName:lower() ~= "scene.json" then
        local package = json.decode(directContent)
        if type(package) ~= "table" or type(package.document) ~= "table" then
            Log.Error("invalid_project_file", "所选 JSON 不是有效的 UGC 项目文件", { path = selected })
            return false, "所选 JSON 不是有效的 UGC 项目文件"
        end
        if tonumber(package.packageVersion) ~= PACKAGE_VERSION then
            Log.Error("unsupported_package", "不支持的 UGC packageVersion", { path = selected, version = package.packageVersion })
            return false, "不支持的 UGC packageVersion: " .. tostring(package.packageVersion)
        end
        local loaded, message = sceneData:DeserializePackageTable(package)
        if not loaded then
            Log.Error("load_failed", message, { path = selected })
            return false, message
        end
        Log.Info("project_loaded", {
            path = selected, version = PACKAGE_VERSION, legacy = false,
            entities = entityCountOf(sceneData), document = documentIdOf(sceneData),
        })
        return loaded, selected
    end

    if not directContent then
        local projectPath = folder .. PROJECT_FILE
        local content = readFile(projectPath)
        if content then
            local package = json.decode(content)
            if type(package) ~= "table" or type(package.document) ~= "table" then
                Log.Error("invalid_project_file", "UGC 项目文件 JSON 无效", { path = projectPath })
                return false, "UGC 项目文件 JSON 无效"
            end
            if tonumber(package.packageVersion) ~= PACKAGE_VERSION then
                Log.Error("unsupported_package", "不支持的 UGC packageVersion", { path = projectPath, version = package.packageVersion })
                return false, "不支持的 UGC packageVersion: " .. tostring(package.packageVersion)
            end
            local loaded, message = sceneData:DeserializePackageTable(package)
            if not loaded then
                Log.Error("load_failed", message, { path = projectPath })
                return false, message
            end
            Log.Info("project_loaded", {
                path = projectPath, version = PACKAGE_VERSION, legacy = false,
                entities = entityCountOf(sceneData), document = documentIdOf(sceneData),
            })
            return loaded, projectPath
        end
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
    return true, folder .. "scene.json"
end

Persistence.PROJECT_FILE = PROJECT_FILE
Persistence.PACKAGE_VERSION = PACKAGE_VERSION
return Persistence
