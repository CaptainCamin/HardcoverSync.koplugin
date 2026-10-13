-- Every full-screen plugin screen must go up with a flashing "full" refresh, or a partial one
-- draws it over the screen beneath and it ghosts (the For you / Vibes shelf, a list, a goal...).
-- They all come through DialogManager:openScreen, so this checks that path, then that no flow
-- shows a tracked screen around it.
--
-- Run with:  lua spec/screen_open_refresh_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __concat = function() return "" end,
  })
end

local shows, remounts = {}, {}
package.preload["ui/uimanager"] = function()
  return { show = function(_, widget, mode) shows[#shows + 1] = { widget = widget, mode = mode } end,
    close = function() end, setDirty = function() end }
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["hardcover/lib/ui/hosted"] = function()
  return { remount = function(host, screen) remounts[#remounts + 1] = screen end }
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")

local tracked
local function manager()
  shows, remounts, tracked = {}, {}, {}
  return setmetatable({
    screens = function() return { track = function(_, kind, w) tracked[kind] = w end } end,
  }, { __index = DialogManager })
end

r.check("a screen opened on its own is shown with a full refresh and remembered", pcall(function()
  local screen = {}
  manager():openScreen("for_you", screen)
  assert(#shows == 1 and shows[1].widget == screen, "not shown once")
  assert(shows[1].mode == "full", "shown with " .. tostring(shows[1].mode))
  assert(tracked.for_you == screen, "not tracked")
end))

r.check("a screen mounted in the shell is placed there, not shown on top", pcall(function()
  local screen = {}
  manager():openScreen("vibes", screen, { remount = true })
  assert(#shows == 0 and remounts[1] == screen)
end))

r.check("no flow shows a full-screen screen around openScreen", pcall(function()
  for _, file in ipairs { "shelf_flows", "list_flows", "book_flows" } do
    local src = assert(io.open(PLUGIN .. "/hardcover/lib/ui/" .. file .. ".lua")):read("*a")
    assert(not src:find("UIManager:show%(dialog%)"), file .. " shows a screen with no refresh mode")
  end
end))

r.finish()
