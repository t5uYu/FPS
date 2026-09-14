--[[
    UGCNodeRegistry.lua
    UI adapter over the shared typed UGCGraphSchema.
]]

local Schema = require("Gameplay.UGC.UGCGraphSchema")
local R = { Definitions={}, Categories={} }

local COLORS = {
    ["事件"] = {r=0.63, g=0.06, b=0.06},
    ["条件"] = {r=0.06, g=0.44, b=0.19},
    ["动作"] = {r=0.06, g=0.31, b=0.63},
}

local categoryMap = {}
for typeName, source in pairs(Schema.Definitions) do
    local def = {}
    for k, v in pairs(source) do def[k] = v end
    def.color = COLORS[def.category]
    def.exec_in = def.inputs and def.inputs.exec_in == "exec" or false
    def.exec_out = def.outputs and def.outputs.exec_out == "exec" or false
    def.exec_out_true = def.outputs and def.outputs.exec_out_true == "exec" or false
    def.exec_out_false = def.outputs and def.outputs.exec_out_false == "exec" or false
    R.Definitions[typeName] = def

    local category = categoryMap[def.category]
    if not category then
        category = { name=def.category, items={} }
        categoryMap[def.category] = category
        R.Categories[#R.Categories + 1] = category
    end
    category.items[#category.items + 1] = { type=typeName, label=def.label }
end

local order = { ["事件"]=1, ["条件"]=2, ["动作"]=3 }
table.sort(R.Categories, function(a, b) return (order[a.name] or 99) < (order[b.name] or 99) end)
for _, category in ipairs(R.Categories) do
    table.sort(category.items, function(a, b) return a.label < b.label end)
end

return R
