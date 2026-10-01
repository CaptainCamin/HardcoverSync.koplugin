--[[--
Entry point for one emulator scenario.

    luajit spec/emu/run_scenario.lua spec/emu/scenarios/<name>.lua

The scenario file returns a table { name = ..., run = function(emu) end }.
Its job is to build real plugin widgets and let the harness screenshot them.
Anything it throws is a failure; the PNGs it produced beforehand are kept,
because a half-rendered screen is usually the interesting artefact.
]]

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$")
package.path = here .. "/?.lua;" .. package.path

local scenario_path = arg[1]
if not scenario_path then
  io.stderr:write("usage: run_scenario.lua <scenario.lua>\n")
  os.exit(2)
end

local emu = require("boot").boot()

local chunk = assert(loadfile(scenario_path))
local scenario = chunk()
assert(type(scenario) == "table" and type(scenario.run) == "function",
  scenario_path .. " must return { name = ..., run = function(emu) }")

local ok, err = xpcall(function()
  scenario.run(emu)
end, function(e)
  return tostring(e) .. "\n" .. debug.traceback("", 2)
end)

if not ok then
  io.stderr:write("scenario '" .. tostring(scenario.name) .. "' failed:\n" .. err .. "\n")
  emu:quit(1)
end

print(string.format("  %d screenshot(s)", #emu.shots))
emu:quit(0)
