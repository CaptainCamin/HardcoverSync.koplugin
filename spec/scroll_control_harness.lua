-- The scroll control's pure logic: the row edges the container steps by. How it draws and takes taps is
-- checked on a real KOReader in spec/emu/scenarios/scroll_control.lua.
--
-- Run with:  lua spec/scroll_control_harness.lua [plugin-root]

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
  if name == "ffi/blitbuffer" then return { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_GRAY_5 = "grey5" } end
  if name == "ui/widget/container/inputcontainer" then
    return { extend = function(_, o) o.new = function(c, t) return setmetatable(t or {}, { __index = c }) end; return o end }
  end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then return real_require(name) end
  return make()
end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["logger"] = function() return { dbg = function() end, info = function() end, warn = function() end, err = function() end } end

local ScrollControl = require("hardcover/lib/ui/components/scroll_control")

local function row(h) return { getSize = function() return { w = 100, h = h } end } end
local grid = ScrollControl.grid({ row(40), row(60), row(20) })
r.check("one step row per child", grid and #grid == 3)
r.check("rows are edge to edge", grid[1].top == 0 and grid[1].bottom == 39 and grid[2].top == 40
  and grid[2].bottom == 99 and grid[3].top == 100 and grid[3].bottom == 119)
r.check("no children, no grid (free scrolling)", ScrollControl.grid({}) == nil and ScrollControl.grid(nil) == nil)

_G.require = real_require
r.finish()
