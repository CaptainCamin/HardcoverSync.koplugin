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

-- ---------------------------------------------------------------- floating action button
do
  local f = Theme.mmd.fab
  r.check("fab sizes are 72 / 64 / 48", f.size.large == 72 and f.size.medium == 64 and f.size.small == 48)
  r.check("fab icons 28 / 28 / 24, radius 18 / 18 / 14, halo 4 / 3 / 2",
    f.icon.large == 28 and f.icon.medium == 28 and f.icon.small == 24
    and f.radius.large == 18 and f.radius.small == 14 and f.halo.large == 4 and f.halo.small == 2)
  r.check("a fab, halo included, is never under TOUCH_MIN",
    f.size.small + 2 * f.halo.small >= Theme.TOUCH_MIN)

  local local_icon
  local Fab = require("hardcover/lib/ui/components/fab")
  local seen
  Theme.box = function(w, hh, child, opts) seen = { w = w, h = hh, opts = opts }; return make() end
  Theme.icon = function(name, size) local_icon = { name = name, size = size }; return make() end
  local fab = Fab.new { icon = "plus", callback = function() end }
  r.check("the default is the large square with its icon", seen.w == f.size.large and seen.h == f.size.large
    and local_icon.name == "plus" and local_icon.size == f.icon.large)
  r.check("a square, not a circle: it has a radius", seen.opts.radius == f.radius.large and not seen.opts.round)
  Fab.new { icon = "plus", scale = "small" }
  r.check("scale picks the size", seen.w == f.size.small and local_icon.size == f.icon.small)
  Fab.new { icon = "plus", enabled = false, callback = function() end }
  r.check("an unavailable fab is a dotted square", seen.opts.dotted == true)
  local x, y = Fab.position(1000, 1400, 80, 80)
  r.check("it sits in the bottom right by default", x == 1000 - 80 - f.margin and y == 1400 - 80 - f.margin)
  x = Fab.position(1000, 1400, 80, 80, "left")
  r.check("or the bottom left", x == f.margin)
  r.check("a body reserves the fab's height and both margins",
    Fab.reserve("large") == f.size.large + 2 * f.halo.large + 2 * f.margin)
end

-- ---------------------------------------------------------------- button sizes and the round button
do
  local h = Theme.mmd.button.height
  r.check("button heights grow small < medium < large, none under TOUCH_MIN - 8",
    h.small < h.medium and h.medium < h.large and h.small >= Theme.TOUCH_MIN - 8)
  r.check("the sizes are about 1 : 1.35 : 1.6", math.abs(h.medium / h.small - 1.35) < 0.1
    and math.abs(h.large / h.small - 1.6) < 0.1)
  local sz = Theme.mmd.round_button.size
  r.check("a round button is never under TOUCH_MIN",
    sz.small >= Theme.TOUCH_MIN and sz.small < sz.medium and sz.medium < sz.large)

  local Button = require("hardcover/lib/ui/components/button")
  local seen
  Theme.box = function(w, hh, child, opts) seen = { w = w, h = hh, opts = opts }; return make() end
  Button.new { label = "Go", w = 200, scale = "small" }
  r.check("scale picks the height", seen.h == h.small, tostring(seen.h))
  Button.new { label = "Go", w = 200, scale = "medium", h = 99 }
  r.check("an explicit h wins over scale", seen.h == 99, tostring(seen.h))
  Button.new { label = "Go", w = 200 }
  r.check("no scale keeps the dialog height", seen.h == Button.HEIGHT, tostring(seen.h))
  Theme.icon = function() return make() end
  Button.round { icon = "plus", scale = "large" }
  r.check("round draws a circle of the scale's size", seen.w == sz.large and seen.h == sz.large and seen.opts.round)
  Button.round { icon = "plus", enabled = false }
  r.check("a disabled round button is a dotted circle", seen.opts.dotted == true and seen.w == sz.medium)
end

_G.require = real_require
r.finish()
