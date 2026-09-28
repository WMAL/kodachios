-- conky-gauges-demo.lua
-- Compatibility shim for demo config; reuses the main gauges implementation.

require 'cairo'

local home = os.getenv("HOME") or ""
local main_file = home .. "/.config/kodachi/conky/lua/conky-gauges.lua"
local ok = pcall(function()
    dofile(main_file)
end)

if not ok then
    -- Keep demo conky stable even if the main gauge script is unavailable.
    function conky_main()
        return
    end
end

