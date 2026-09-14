local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path
package.preload["Gameplay.UGC.UGCSceneData"] = function()
    return { GetRevision=function() return 7 end }
end

local Registry=require("Gameplay.UGC.UGCFunctionRegistry")
Registry:Register("read_test", {risk="read", params={{name="mode",type="string",enum={"safe"},required=true}}, func=function() return true,"ok" end})
Registry:Register("write_test", {risk="write", params={{name="value",type="number",min=0,max=10,required=true}}, func=function() return true,"ok" end})

local ok,proposal=Registry:BuildProposal({{name="read_test",params={mode="safe"},id="r1"}})
assert(ok); assert(proposal.baseRevision==7); assert(proposal.highestRisk=="read")
local valid=Registry:BuildProposal({{name="read_test",params={mode="unsafe"},id="r2"}})
assert(not valid)
valid=Registry:BuildProposal({{name="read_test",params={mode="safe",extra=true},id="r3"}})
assert(not valid)
valid=Registry:BuildProposal({
    {name="write_test",params={value=1},id="w1"},
    {name="write_test",params={value=2},id="w2"},
})
assert(not valid)
print("ALL PASS registry validation/proposal policy")
