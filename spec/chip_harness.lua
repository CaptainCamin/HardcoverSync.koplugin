-- The MMD chip: selected is filled black with a white label, otherwise outlined with a Black label;
-- never grey. Looks are judged on a device.
--
-- Run with:  luajit spec/chip_harness.lua [plugin-root]

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
  if name == "ffi/blitbuffer" then return { COLOR_BLACK = "black", COLOR_WHITE = "white" } end
  if name == "ui/widget/container/framecontainer" then
    return { new = function(_, o) return o end }
  end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["logger"] = function() return { dbg = function() end, info = function() end, warn = function() end, err = function() end } end

local Theme = require("hardcover/lib/ui/theme")
local labels = {}
Theme.mmdText = function(str, kind, size, opts) local t = { text = str, kind = kind, color = opts.color, width = opts.width }; labels[#labels + 1] = t; return t end
local Chip = require("hardcover/lib/ui/components/chip")

local on = Chip.new { label = "On track", selected = true }
r.check("selected: filled black, white bold label", on.background == "black" and on[1].color == "white" and on[1].kind == "strong")
local off = Chip.new { label = "Behind" }
r.check("not selected: white box, Black label, black outline", off.background == "white" and off[1].color == "black" and off.color == "black")
r.check("2 border, radius 20, 14 either side", on.bordersize == Theme.mmd.chip.border and on.radius == 20 and on.padding_left == 14 and on.padding_right == 14)
r.check("the label is kept as the chip's first child (screens and tests read it there)", on[1].text == "On track")
r.check("a width cuts the label rather than wrapping", Chip.new { label = "x", width = 200 }[1].width == 200 - 2 * (Theme.mmd.chip.border + 14))
r.finish()
