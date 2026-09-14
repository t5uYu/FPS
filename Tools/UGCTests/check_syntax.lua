local file = assert(arg[1], "Lua file required")
local chunk, err = loadfile(file)
if not chunk then
    io.stderr:write(err .. "\n")
    os.exit(1)
end
