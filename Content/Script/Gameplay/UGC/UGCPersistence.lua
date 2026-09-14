--[[
    UGCPersistence.lua

    Versioned, atomic persistence provider for UGC projects. UI supplies a path;
    this service owns all file IO and legacy migration.
]]

local json = require("Gameplay.UGC.json")

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
        return false, "SceneData 不支持版本化存档"
    end
    local package = sceneData:SerializePackageTable(editorState or {})
    package.packageVersion = PACKAGE_VERSION
    local encoded = json.encode(package, "  ")
    local decoded = json.decode(encoded)
    if type(decoded) ~= "table" or type(decoded.document) ~= "table" then
        return false, "存档序列化自检失败"
    end
    local path = self:GetProjectPath(folderOrFile)
    local ok, err = atomicWrite(path, encoded)
    if not ok then return false, err end
    sceneData:ClearDirty()
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
            return false, "所选 JSON 不是有效的 UGC 项目文件"
        end
        if tonumber(package.packageVersion) ~= PACKAGE_VERSION then
            return false, "不支持的 UGC packageVersion: " .. tostring(package.packageVersion)
        end
        local loaded, message = sceneData:DeserializePackageTable(package)
        return loaded, loaded and selected or message
    end

    if not directContent then
        local projectPath = folder .. PROJECT_FILE
        local content = readFile(projectPath)
        if content then
            local package = json.decode(content)
            if type(package) ~= "table" or type(package.document) ~= "table" then
                return false, "UGC 项目文件 JSON 无效"
            end
            if tonumber(package.packageVersion) ~= PACKAGE_VERSION then
                return false, "不支持的 UGC packageVersion: " .. tostring(package.packageVersion)
            end
            local loaded, message = sceneData:DeserializePackageTable(package)
            return loaded, loaded and projectPath or message
        end
    end

    -- Legacy v2 layout: scene.json + programs.json + editor.json.
    local sceneJSON, err = directContent or readFile(folder .. "scene.json")
    if not sceneJSON then return false, "找不到 project.ugc.json 或 scene.json: " .. tostring(err or "") end
    local ok, message = sceneData:DeserializeFromJSON(sceneJSON)
    if not ok then return false, message or "旧版 scene.json 加载失败" end

    local programsJSON = readFile(folder .. "programs.json")
    if programsJSON then sceneData:DeserializeProgramsJSON(programsJSON) end
    sceneData:ClearDirty()
    return true, folder .. "scene.json"
end

Persistence.PROJECT_FILE = PROJECT_FILE
Persistence.PACKAGE_VERSION = PACKAGE_VERSION
return Persistence
