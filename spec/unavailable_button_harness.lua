-- An unavailable button and a plain rule never rest on grey (MMD: black and white only; docs/e-ink-design.md
-- rule 3): the button keeps a Black label, is never filled, draws a dotted border and takes no tap; Theme.rule
-- is a black dotted divider unless it is a firm heading underline.
--
-- Run with:  luajit spec/unavailable_button_harness.lua [plugin-root]

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

local dots, frames = {}, {}
local real_require = require
_G.require = function(name)
  if name == "device" then
    return { screen = { scaleBySize = function(_, n) return n end,
                        getWidth = function() return 1000 end, getHeight = function() return 1400 end } }
  end
  if name == "ffi/blitbuffer" then
    return { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_GRAY_5 = "grey5", COLOR_DARK_GRAY = "dark" }
  end
  if name == "ui/widget/container/framecontainer" then
    local F = {}
    function F:new(o) frames[#frames + 1] = o; o.paintTo = o.paintTo or function() end; return o end
    return F
  end
  if name == "hardcover/lib/ui/components/draw" then
    return { dottedBorder = function(...) dots[#dots + 1] = { ... } end }
  end
  if name == "hardcover/lib/ui/tap_row" then
    return { new = function(_, o) return o end }
  end
  if name == "ui/widget/textwidget" or name == "ui/widget/linewidget" or name == "ui/widget/widget" then
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

local function lastFrame() return frames[#frames] end

-- Theme.button
local on = Theme.button("Save", 300, { filled = true, callback = function() end })
r.check("enabled filled button: black frame, filled, taps",
  lastFrame().color == "black" and lastFrame().background == "black" and on.callback ~= nil and #dots == 0)

local off = Theme.button("Save", 300, { filled = true, enabled = false, callback = function() end })
local f = lastFrame()
r.check("unavailable button is not filled", f.background == "white")
r.check("unavailable button takes no tap", off.callback == nil)
f:paintTo({}, 10, 20)
r.check("unavailable button draws a dotted border", #dots == 1 and dots[1][2] == 10 and dots[1][3] == 20)
r.check("unavailable button's own border is white, so only the dots show", f.color == "white")
r.check("unavailable button label is Black, not grey", off.label.fgcolor == "black")

-- Theme.rule
local firm = Theme.rule(300, true)
r.check("firm rule is solid black", firm.background == "black")
local soft = Theme.rule(300, false)
r.check("plain rule is the dotted divider, not a grey line", soft.background == nil and type(soft.paintTo) == "function")

-- the MMD Button component
local Button = require("hardcover/lib/ui/components/button")
local before = #dots
local b = Button.new { label = "Save", w = 300, primary = true, enabled = false }
local bf = lastFrame()
bf:paintTo({}, 0, 0)
r.check("component button, unavailable: not filled, dotted, no tap",
  bf.background == "white" and #dots == before + 1 and b.callback == nil)

r.finish()
