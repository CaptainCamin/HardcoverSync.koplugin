-- The header of a list screen (hardcover/lib/ui/list_header.lua): the title bar with a row of
-- buttons under it, handed to KOReader's Menu as its title bar.
--
-- The real header runs here against stand-ins for the widgets under it, which only keep
-- what they are given and report a size. What is checked is what the Menu depends on (one
-- height, a dimen the vendored list reads, the calls a Menu makes on a title bar) and how
-- the row is laid out. How it looks is the emulator's job (spec/emu/scenarios/list_row.lua).
--
-- Usage: lua spec/list_header_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

support.preload_koreader_stubs()

package.preload["device"] = function()
  return { screen = { getWidth = function() return 1000 end, scaleBySize = function(_, n) return n end } }
end
package.preload["ui/geometry"] = function()
  return { new = function(_, o) return o end }
end

-- a container that stacks or lines up what it holds, as the real ones size themselves
local function group(horizontal)
  local G = {}
  G.__index = G
  function G:extend(fields)
    local child = {}
    for k, v in pairs(fields or {}) do child[k] = v end
    child.__index = child
    setmetatable(child, { __index = G })
    return child
  end
  function G:new(o)
    o = setmetatable(o or {}, self)
    if o.init then o:init() end
    return o
  end
  function G:getSize()
    if not self._size then
      local w, h = 0, 0
      for _, child in ipairs(self) do
        local s = child:getSize()
        if horizontal then
          w, h = w + s.w, math.max(h, s.h)
        else
          w, h = math.max(w, s.w), h + s.h
        end
      end
      self._size = { w = w, h = h }
    end
    return self._size
  end
  function G:resetLayout() self._size = nil end
  function G:paintTo(_, x, y) self.painted = { x = x, y = y } end
  function G:free()
    self.freed = (self.freed or 0) + 1
    for _, child in ipairs(self) do if child.free then child:free() end end
  end
  return G
end
package.preload["ui/widget/verticalgroup"] = function() return group(false) end
package.preload["ui/widget/horizontalgroup"] = function() return group(true) end
package.preload["ui/widget/container/leftcontainer"] = function()
  local L = group(true)
  function L:getSize() return self.dimen end
  return L
end

-- The family's parts: a title bar of a known height, a button of the width it is given
local record = { bars = {}, buttons = {} }
package.preload["hardcover/lib/ui/theme"] = function()
  local Theme = { margin = 20, space = { s = 8, m = 16 }, BUTTON_H = 54 }
  Theme.px = function(n) return n end
  function Theme.hspan(n) return { getSize = function() return { w = n, h = 0 } end, span = n } end
  function Theme.titleBar(opts)
    local bar = { opts = opts, calls = {}, freed = 0 }
    bar.left_button = opts.back_callback and { name = "back" } or nil
    bar.right_button = { name = "x" }
    if opts.right_icon then bar.extra_right_button = { name = opts.right_icon } end
    function bar:getSize() return { w = opts.width, h = 100 } end
    function bar:setTitle(t, no_refresh) self.calls[#self.calls + 1] = { "title", t, no_refresh } end
    function bar:setSubTitle(t, no_refresh) self.calls[#self.calls + 1] = { "subtitle", t, no_refresh } end
    function bar:setLeftIcon(i) self.calls[#self.calls + 1] = { "icon", i } end
    function bar:generateVerticalLayout() return { { self.left_button }, { self.right_button } } end
    function bar:free() self.freed = self.freed + 1 end
    record.bars[#record.bars + 1] = bar
    return bar
  end
  function Theme.button(text, w, opts)
    local b = { text = text, width = w, opts = opts, freed = 0 }
    function b:getSize() return { w = w, h = Theme.BUTTON_H } end
    function b:free() self.freed = self.freed + 1 end
    record.buttons[#record.buttons + 1] = b
    return b
  end
  return Theme
end

package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path
local ListHeader = require("hardcover/lib/ui/list_header")

local function noop() end
local function make(over)
  local o = {
    title = "Want to Read",
    width = 1000,
    back_callback = noop,
    show_parent = "parent",
    buttons = {
      { text = "Sort: Title", chevron = true, callback = noop },
      { text = "Search", callback = noop },
    },
  }
  for k, v in pairs(over or {}) do o[k] = v end
  return ListHeader:new(o)
end

local ROW_H = 54 + 2 * 8

print("\n== what the Menu asks of a title bar ==")
do
  local h = make()
  r.check("it is the bar and the row", #h == 2 and h[1] == h.title_bar)
  r.check("one height for the whole header", h:getHeight() == 100 + ROW_H and h:getSize().h == h:getHeight(), tostring(h:getHeight()))
  r.check("the vendored list reads dimen.h, and it agrees", h.dimen.h == h:getHeight() and h.dimen.w == 1000)
  h:paintTo(nil, 30, 40)
  r.check("painting records where it is (refreshes and taps need it)", h.dimen.x == 30 and h.dimen.y == 40 and h.painted.x == 30)
  r.check("the title bar is built with Back, the title and the width it was given",
    h.title_bar.opts.title == "Want to Read" and h.title_bar.opts.width == 1000
    and h.title_bar.opts.back_callback == noop and h.title_bar.opts.show_parent == "parent")
  r.check("and the buttons are the bar's, as callers and tests look for them",
    h.left_button == h.title_bar.left_button and h.right_button == h.title_bar.right_button and h.right_button.name == "x")

  h:setTitle("Other", true)
  local c = h.title_bar.calls[1]
  r.check("setTitle goes to the title bar, with no_refresh", c[1] == "title" and c[2] == "Other" and c[3] == true)
  r.check("and is remembered, for a later rebuild", h.title == "Other")
  h:setSubTitle("sub", true)
  r.check("setSubTitle goes to the title bar", h.title_bar.calls[2][1] == "subtitle" and h.title_bar.calls[2][2] == "sub")
  h:setLeftIcon("appbar.menu")
  r.check("setLeftIcon goes to the title bar", h.title_bar.calls[3][1] == "icon" and h.title_bar.calls[3][2] == "appbar.menu")
  h:getSize()
  h:setTitle("Again", true)
  r.check("each resets the layout", h._size == nil)

  local layout = h:generateVerticalLayout()
  r.check("the layout is the bar's rows, then one row of the buttons",
    #layout == 3 and layout[1][1] == h.left_button and layout[2][1] == h.right_button
    and #layout[3] == 2 and layout[3][1] == h.row_buttons[1] and layout[3][2] == h.row_buttons[2])
end

print("\n== taps ==")
do
  local h = make()
  local asked = {}
  local function child(name, consumes)
    return { handleEvent = function(_, ev) asked[#asked + 1] = name return consumes end }
  end
  h[1], h[2] = child("bar"), child("row")
  r.check("the row is asked before the bar, whose Back and X reach over its top edge",
    h:propagateEvent("tap") == false and asked[1] == "row" and asked[2] == "bar", table.concat(asked, ","))
  asked = {}
  h[2] = child("row", true)
  r.check("a button that takes the tap ends it: the bar is never asked", h:propagateEvent("tap") == true and #asked == 1 and asked[1] == "row")
  asked = {}
  h[1], h[2] = child("bar", true), child("row")
  r.check("a tap outside the row reaches the bar", h:propagateEvent("tap") == true and asked[2] == "bar")
  h = make({ buttons = {} })
  h[1] = child("bar", true)
  asked = {}
  r.check("with no row, the bar alone", h:propagateEvent("tap") == true and #asked == 1)
end

print("\n== the row ==")
do
  local h = make()
  local a, b = h.row_buttons[1], h.row_buttons[2]
  r.check("a button for each, in order, named as they were", #h.row_buttons == 2 and a.text == "Sort: Title" and b.text == "Search")
  r.check("the options reach the button", a.opts.chevron == true and a.opts.callback == noop and b.opts.filled == nil)
  r.check("two buttons share the width evenly", a.width == b.width, a.width .. " and " .. b.width)
  local row = h[2]
  local line = row[1]
  r.check("the margin, the buttons and the gap fill the width exactly",
    row:getSize().w == 1000 and line:getSize().w == 20 + a.width + 16 + b.width and 20 + a.width + 16 + b.width + 20 == 1000,
    tostring(line:getSize().w))
  r.check("the row is the same height as its buttons and the space above and below", row:getSize().h == ROW_H)

  h = make({ buttons = {
    { text = "Sort: Title", chevron = true },
    { text = "\226\128\156dark\226\128\157", filled = true },
    { text = "\195\151", narrow = true },
  } })
  local sort, words, x = h.row_buttons[1], h.row_buttons[2], h.row_buttons[3]
  r.check("a narrow button is a small square", x.width == 56 and x.getSize(x).h == 54)
  r.check("the others share what is left", sort.width == words.width and sort.width == (1000 - 40 - 2 * 16 - 56) / 2, sort.width .. " " .. words.width)
  r.check("the filled button is asked for filled", words.opts.filled == true and not sort.opts.filled)
  r.check("the row still ends at the margin", 20 + sort.width + 16 + words.width + 16 + x.width + 20 == 1000)
  r.check("and is the same height as with two buttons", h:getHeight() == 100 + ROW_H)

  -- a width that does not divide: the last wide button takes the rest
  h = make({ width = 1001 })
  local a1, b1 = h.row_buttons[1], h.row_buttons[2]
  r.check("a left-over pixel goes to the last wide button, so nothing overflows",
    20 + a1.width + 16 + b1.width + 20 == 1001 and b1.width - a1.width == 1, a1.width .. " " .. b1.width)

  h = make({ buttons = { { text = "New search", chevron = true } } })
  r.check("one button takes the whole width inside the margins", h.row_buttons[1].width == 1000 - 40)

  h = make({ buttons = {} })
  r.check("no buttons, no row", #h == 1 and #h.row_buttons == 0)
  r.check("and no height for it", h:getHeight() == 100 and h.dimen.h == 100)
  r.check("its layout is the title bar's", #h:generateVerticalLayout() == 2)
  h = ListHeader:new { title = "x", width = 1000, back_callback = noop }
  r.check("no buttons given is the same", #h == 1 and h:getHeight() == 100)

  h = make({ width = false })
  r.check("the width defaults to the screen's", h.width == 1000 and h.title_bar.opts.width == 1000)
end

print("\n== changing it in place ==")
do
  local h = make()
  local bar, old_row, old_first = h.title_bar, h[2], h.row_buttons[1]
  local height = h:getHeight()

  h:update { buttons = { { text = "Sort: Author" }, { text = "\226\128\156x\226\128\157", filled = true }, { text = "\195\151", narrow = true } } }
  r.check("new buttons replace the row, in the same object", #h == 2 and h[1] == bar and h[2] ~= old_row and #h.row_buttons == 3
    and h.row_buttons[1].text == "Sort: Author")
  r.check("the title bar is kept when only the row changed", h.title_bar == bar and bar.freed == 0)
  r.check("the row that went is freed", old_row.freed == 1 and old_first.freed == 1)
  r.check("the header is the same height, and says so", h:getHeight() == height and h.dimen.h == height)
  r.check("the layout follows", #h:generateVerticalLayout()[3] == 3)

  local row = h[2]
  h:update { right_icon = "cre.render.reload", right_callback = noop }
  r.check("an icon rebuilds the bar and keeps the row", h.title_bar ~= bar and h[2] == row and #h == 2)
  r.check("the old bar is freed and the new one has the icon and its callback",
    bar.freed == 1 and h.title_bar.opts.right_icon == "cre.render.reload" and h.title_bar.opts.right_callback == noop
    and h.title_bar.extra_right_button)
  r.check("the buttons follow the new bar", h.right_button == h.title_bar.right_button and h.left_button == h.title_bar.left_button)
  r.check("the height is unchanged", h:getHeight() == height)

  local second = h.title_bar
  h:update { right_icon = "cre.render.reload", right_callback = noop }
  r.check("the same icon is not a change: nothing is rebuilt", h.title_bar == second and second.freed == 0)
  h:update {}
  r.check("an empty update changes nothing", h.title_bar == second and h[2] == row)

  h:update { right_icon = false }
  r.check("false takes the icon away", h.title_bar ~= second and h.title_bar.opts.right_icon == nil
    and not h.title_bar.extra_right_button and second.freed == 1)
  local third = h.title_bar
  h:update { right_icon = false }
  r.check("and false again is not a change", h.title_bar == third)

  h:update { title = "Renamed" }
  r.check("a new title rebuilds the bar with it", h.title_bar ~= third and h.title_bar.opts.title == "Renamed" and h.title == "Renamed")

  h:update { buttons = {} }
  r.check("an empty row takes the row away, and its height", #h == 1 and #h.row_buttons == 0 and h:getHeight() == 100 and h.dimen.h == 100)
  h:update { buttons = { { text = "Search" } } }
  r.check("and a row can come back", #h == 2 and h:getHeight() == 100 + ROW_H)
end

r.finish()
