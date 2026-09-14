local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

local json = require("Util.json")
local executed = 0
local registry = {}
function registry:GetSchemas() return "[]" end
function registry:BuildProposal(calls)
    return true, {calls=calls, highestRisk="write", baseRevision=3}
end
function registry:FormatProposal(proposal) return "proposal " .. #proposal.calls end
function registry:ExecuteProposal(proposal)
    executed = executed + 1
    return true, {{name=proposal.calls[1].name, id=proposal.calls[1].id, ok=true, result="done"}}
end
package.preload["Gameplay.UGC.UGCFunctionRegistry"] = function() return registry end

UE = {UKismetSystemLibrary={
    GetProjectDirectory=function() return "F:/github/FPS/" end,
    MakeDirectory=function() return true end,
}}
local storage = {files={}}
function storage:FileExists(path) return self.files[path] ~= nil end
function storage:ReadTextFile(path) return self.files[path] or "" end
function storage:WriteTextFileAtomic(path, content) self.files[path] = content; return true end
local http = {SystemPrompt="system", sent={}}
function http:IsRequestInProgress() return false end
function http:SendMessageWithHistory(messages, tools)
    self.sent[#self.sent + 1] = {messages=messages, tools=tools}
end
function http:CancelRequest() self.cancelled = true end
local pc = {}
function pc:GetUGCHttpClient() return http end
function pc:GetUGCStorageBridge() return storage end

local Gateway = require("Gameplay.UGC.LLMGateway")
Gateway:Init(pc)
local first
assert(Gateway:Send("build", function(ok, msg) first={ok=ok,msg=msg} end))
assert(#http.sent == 1)
Gateway:OnResponse(json.encode({choices={{message={role="assistant", content="", tool_calls={{
    id="call_1", type="function", ["function"]={name="place_object", arguments="{}"},
}}}}}}))
assert(first and first.ok and first.msg:match("proposal"))
assert(Gateway:HasPendingProposal())
assert(executed == 0)

local final
assert(Gateway:Send("确认", function(ok, msg) final={ok=ok,msg=msg} end))
assert(executed == 1)
assert(#http.sent == 2)
assert(not Gateway:HasPendingProposal())
local sent = json.decode(http.sent[2].messages)
assert(sent[#sent].role == "tool")
Gateway:OnResponse(json.encode({choices={{message={role="assistant", content="completed"}}}}))
assert(final and final.ok and final.msg == "completed")
Gateway:Shutdown()
print("ALL PASS LLM proposal/approval/tool loop")
