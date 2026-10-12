-- Opening the home screen (the "Hardcover: Home" gesture, the Hardcover menu entry, anything
-- else that runs HardcoverHome) must ask for a full e-ink refresh, so the shell does not come
-- up as a partial refresh over the screen it replaces.
--
-- Run with:  lua spec/shell_refresh_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local shows = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, widget, mode) shows[#shows + 1] = { widget = widget, mode = mode } end,
    close = function() end, isWidgetShown = function() return true end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    nextTick = function() end,
  }
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
-- the shell itself is not under test: a stand-in that records what it was opened on
package.preload["hardcover/lib/ui/shell"] = function()
  return { new = function(_, opts) return { shell = true, active = opts.active } end }
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local DialogManager = real_require("hardcover/lib/ui/dialog_manager")

local function manager()
  shows = {}
  return setmetatable({
    shellTabs = function() return {} end,
    screens = function() return { discard = function() end, track = function() end } end,
  }, { __index = DialogManager })
end

r.check("opening Home (the gesture's path) shows the shell with a full refresh", pcall(function()
  manager():showHome()
  assert(#shows == 1, "the shell was shown " .. #shows .. " times")
  assert(shows[1].widget.active == "home", "it did not open on Home")
  assert(shows[1].mode == "full", "shown with refresh mode " .. tostring(shows[1].mode))
end))

r.check("the Hardcover gesture's handler goes through that path", pcall(function()
  local f = assert(io.open(PLUGIN .. "/main.lua")):read("*a")
  local handler = f:match("function HardcoverApp:onHardcoverHome%(%).-\nend")
  assert(handler and handler:find("self.dialog_manager:showHome()", 1, true))
end))

r.finish()
