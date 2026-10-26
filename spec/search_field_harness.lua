-- The MMD search field: what it shows (the query, or the placeholder) and when it offers a clear X.
-- How it looks is judged on a device.
--
-- Run with:  luajit spec/search_field_harness.lua [plugin-root]

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

local taps, texts = {}, {}
local real_require = require
_G.require = function(name)
  if name == "device" then
    return { screen = { scaleBySize = function(_, n) return n end,
                        getWidth = function() return 1000 end, getHeight = function() return 1400 end } }
  end
  if name == "ffi/blitbuffer" then
    return { COLOR_BLACK = "black", COLOR_WHITE = "white" }
  end
  if name == "ui/widget/horizontalgroup" then
    return { new = function(_, o) return o end }
  end
  if name == "hardcover/lib/ui/tap_row" then
    return { new = function(_, o) taps[#taps + 1] = o; return o end }
  end
  if name == "hardcover/lib/ui/components/draw" then
    return { icon = function(n) return { icon = n } end }
  end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["logger"] = function() return { dbg = function() end, info = function() end, warn = function() end, err = function() end } end

local Theme = require("hardcover/lib/ui/theme")
Theme.mmdText = function(str, _, _, opts) texts[#texts + 1] = { str = str, color = opts and opts.color }; return {} end
Theme.touchable = function(child, width, callback)
  local tap = { child = child, callback = callback, dimen = { w = width, h = Theme.TOUCH_MIN } }
  taps[#taps + 1] = tap
  return tap
end
local SearchField = require("hardcover/lib/ui/components/search_field")

r.check("no query shows the placeholder and nothing to clear", (function()
  local s, has = SearchField.content(nil, "Search books")
  local s2, has2 = SearchField.content("   ", "Search books")
  return s == "Search books" and not has and s2 == "Search books" and not has2
end)())
r.check("a query shows the query and offers a clear", (function()
  local s, has = SearchField.content("dune", "Search books")
  return s == "dune" and has
end)())
r.check("the field is 48 tall", SearchField.HEIGHT == Theme.mmd.search.h and Theme.mmd.search.h == 48)
r.check("the clear X has a touch area of at least TOUCH_MIN", Theme.mmd.search.clear_touch >= Theme.TOUCH_MIN)

local tapped, cleared
local taps_before = #taps
local f = SearchField.new { width = 600, placeholder = "Search books", on_tap = function(q) tapped = q end }
r.check("empty: placeholder in full black, one tap area (no clear button)", texts[#texts].str == "Search books"
  and texts[#texts].color == "black" and #taps - taps_before == 1)
r.check("the field tap target fills at least TOUCH_MIN", f.field_button.dimen.h >= Theme.TOUCH_MIN)
f.field_button.callback()
r.check("empty: a tap passes an empty query", tapped == "")

taps_before = #taps
f = SearchField.new { width = 600, query = "dune", placeholder = "Search books",
  on_tap = function(q) tapped = q end, on_clear = function() cleared = true end }
r.check("with a query: shows it in black and has a clear button", texts[#texts].str == "dune"
  and texts[#texts].color == "black" and #taps - taps_before == 2)
r.check("the clear tap target fills at least TOUCH_MIN", f.clear_button.dimen.h >= Theme.TOUCH_MIN)
f.field_button.callback()
f.clear_button.callback()
r.check("with a query: a tap passes it, the X clears", tapped == "dune" and cleared == true)

r.finish()
