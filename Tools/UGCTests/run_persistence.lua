local root = assert(arg[1], "workspace root required")
local tempDir = assert(arg[2], "temp dir required"):gsub("\\","/")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path
UE={UKismetSystemLibrary={MakeDirectory=function() return true end}}
local Persistence=require("Gameplay.UGC.UGCPersistence")
local function read(path)
    local f=io.open(path,"rb"); if not f then return nil end
    local content=f:read("*a"); f:close(); return content
end
local storage={}
function storage:FileExists(path) local f=io.open(path,"rb"); if not f then return false end; f:close(); return true end
function storage:ReadTextFile(path) return read(path) or "" end
function storage:WriteTextFileAtomic(path,content)
    local tmp,bak=path..".tmp",path..".bak"
    os.remove(tmp); local f=assert(io.open(tmp,"wb")); f:write(content); f:close()
    os.remove(bak); if self:FileExists(path) then assert(os.rename(path,bak)) end
    if not os.rename(tmp,path) then os.rename(bak,path); return false end
    return true
end
Persistence:Init(storage)
local saveCount=0
local scene={}
function scene:SerializePackageTable(editor) saveCount=saveCount+1; return {document={header={documentId="p",schemaVersion=3,revision=saveCount},entities={},programs={},generatedGroups={},worldSettings={}},editor=editor} end
function scene:ClearDirty() self.cleared=true end
function scene:DeserializePackageTable(package) self.loaded=package; return true,"loaded" end
local path=tempDir.."/named.ugc.json"
os.remove(path); os.remove(path..".bak"); os.remove(path..".tmp")
local ok,saved=Persistence:SaveProject(path,scene,{activeProgramId="level_main"})
assert(ok,saved); assert(saved==path); assert(scene.cleared)
ok,saved=Persistence:SaveProject(path,scene,{activeProgramId="level_main"})
assert(ok,saved)
local backup=io.open(path..".bak","rb"); assert(backup,"backup missing"); backup:close()
local loaded,loadedPath=Persistence:LoadProject(path,scene)
assert(loaded,loadedPath); assert(loadedPath==path); assert(scene.loaded.packageVersion==Persistence.PACKAGE_VERSION); assert(scene.loaded.document.header.revision==2)
os.remove(path); os.remove(path..".bak"); os.remove(path..".tmp")
print("ALL PASS persistence exact-path + backup")
