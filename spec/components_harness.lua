-- The MMD components' numbers and pure logic: the metrics every component reads from Theme.mmd (each
-- touch area at least TOUCH_MIN, the sizes the appendix gives) and the secondary-text setting. What they look like and how they take taps is checked on a real
-- KOReader in the emulator scenes (spec/emu/scenarios/components.lua).
--
-- Run with:  lua spec/components_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

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

local real_require = require
_G.require = function(name)
  if name == "device" then
    return { screen = { scaleBySize = function(_, n) return n end,
                        getWidth = function() return 1000 end, getHeight = function() return 1400 end } }
  end
  if name == "ffi/blitbuffer" then
    return { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_GRAY_5 = "grey5" }
  end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["logger"] = function() return { dbg = function() end, info = function() end, warn = function() end, err = function() end } end

local Theme = require("hardcover/lib/ui/theme")
local UiPrefs = require("hardcover/lib/ui_prefs")

-- ---------------------------------------------------------------- metrics
do
  local m = Theme.mmd
  r.check("every touch area is at least TOUCH_MIN",
    m.radio.touch >= Theme.TOUCH_MIN and m.checkbox.touch >= Theme.TOUCH_MIN and m.switch.touch >= Theme.TOUCH_MIN,
    "a touch area is smaller than " .. Theme.TOUCH_MIN)
  r.check("the switch is 48 x 30 with a 20 knob", m.switch.w == 48 and m.switch.h == 30 and m.switch.knob == 20)
  r.check("radio 26 with a 14 dot, checkbox 28", m.radio.size == 26 and m.radio.dot == 14 and m.checkbox.size == 28)
  r.check("tabs 50, top bar 67, nav bar 57", m.tabs.h == 50 and m.top_bar.h == 67 and m.nav_bar.h == 57)
  r.check("overlays: a 3px rule and a 2px gap", m.rule.overlay == 3 and m.rule.gap == 2)
  r.check("the top bar's rule fits inside its height", m.rule.overlay < m.top_bar.h)
end

-- ---------------------------------------------------------------- secondary text
do
  UiPrefs.pure_black_text = false
  r.check("secondary text is dark grey by default", Theme.secondary() == Theme.DARK_GREY)
  UiPrefs.pure_black_text = true
  r.check("the beta setting makes it pure black", Theme.secondary() == Theme.BLACK)
  UiPrefs.pure_black_text = false
end

_G.require = real_require
r.finish()
