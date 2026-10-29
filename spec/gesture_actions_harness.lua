-- Gesture actions that need an open book must do nothing from the file browser.
--
-- Run with:  lua spec/gesture_actions_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local r = KB.support.reporter()
local check = r.test

local function browserApp()
  local calls = {}
  local app = KB.new_app {
    ui = {},
    settings = { setSync = function() calls[#calls + 1] = "setSync" end },
    hardcover = { showLinkBookDialog = function() calls[#calls + 1] = "link" end },
  }
  return app, calls
end

for _, name in ipairs { "onHardcoverTrack", "onHardcoverStopTrack", "onHardcoverLink" } do
  check(name .. " does nothing without an open book", function()
    local app, calls = browserApp()
    app[name](app)
    assert(#calls == 0, "reached " .. tostring(calls[1]))
  end)
end

r.finish()
