-- The visual vocabulary in theme.lua: each signal keeps its one meaning.
--
--   border  = you can tap it          fill    = state (black active, grey unavailable)
--   chevron = opens something         font    = serif is a name, bold sans a control
--   shape   = one radius for controls static information has no fill and no border
--
-- These are cheap to break by accident (a new screen reaching for a grey, a disabled
-- button that stays black), and the emulator only shows it if someone looks, so the
-- rules are checked here against small stand-ins for KOReader's widgets.
--
-- Run with:  lua spec/theme_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
  })
end

-- a widget class whose instances are the table they were built from
local function widget(kind)
  local C = { kind = kind }
  C.__index = C
  function C:new(o)
    o = o or {}
    o.kind = kind
    return setmetatable(o, C)
  end
  function C:getSize() return { w = self.width or self.max_width or 40, h = self.height or 20 } end
  function C:free() end
  return C
end

local FONT_MISSING = false
local widgets = {
  ["ffi/blitbuffer"] = {
    COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_GRAY_5 = "dark grey",
    Color8 = function(v) return "grey" .. v end,
  },
  ["ui/font"] = { getFace = function(_, name, size)
    if FONT_MISSING and name == "NotoSerif-Bold.ttf" then return nil end
    return { name = name, size = size }
  end },
  ["ui/widget/textwidget"] = widget("Text"),
  ["ui/widget/textboxwidget"] = widget("TextBox"),
  ["ui/widget/iconwidget"] = widget("Icon"),
  ["ui/widget/widget"] = widget("Widget"),
  ["ui/widget/progresswidget"] = widget("Progress"),
  ["ui/widget/linewidget"] = widget("Line"),
  ["ui/widget/horizontalgroup"] = widget("HGroup"),
  ["ui/widget/horizontalspan"] = widget("HSpan"),
  ["ui/widget/verticalgroup"] = widget("VGroup"),
  ["ui/widget/verticalspan"] = widget("VSpan"),
  ["ui/widget/container/centercontainer"] = widget("Center"),
  ["ui/widget/container/framecontainer"] = widget("Frame"),
  ["ui/widget/container/leftcontainer"] = widget("Left"),
  ["ui/widget/titlebar"] = widget("TitleBar"),
  ["hardcover/lib/ui/tap_row"] = widget("TapRow"),
  ["ui/geometry"] = { new = function(_, t) return t end },
  ["device"] = { screen = {
    getWidth = function() return 1000 end,
    getHeight = function() return 1400 end,
    scaleBySize = function(_, n) return n end,
  } },
}

local real_require = require
_G.require = function(name)
  if widgets[name] then return widgets[name] end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local Theme = real_require("hardcover/lib/ui/theme")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- the first widget in a tree (depth first) for which `pred` holds
local function find(node, pred)
  if type(node) ~= "table" then return nil end
  if node.kind and pred(node) then return node end
  for _, child in ipairs(node) do
    local hit = find(child, pred)
    if hit then return hit end
  end
end

local function frame(node) return find(node, function(n) return n.kind == "Frame" end) end
local function icons(node)
  local out = {}
  local function walk(n)
    if type(n) ~= "table" then return end
    if n.kind == "Icon" then out[#out + 1] = n.file end
    for _, child in ipairs(n) do walk(child) end
  end
  walk(node)
  return out
end

print("\n== shape: one radius for controls ==")

check("a control's radius is the shared one, and never more than half its height", function()
  assert(Theme.controlRadius(500, 100) == Theme.px(12), "wide control")
  assert(Theme.controlRadius(500, 10) == 5, "a short control is capped at half its height")
end)

check("a button is a bordered control with that radius", function()
  local b = Theme.button("Save", 400, {})
  local f = frame(b)
  assert(f.radius == Theme.controlRadius(400, Theme.BUTTON_H), "radius " .. tostring(f.radius))
  assert(f.bordersize == Theme.line.firm and f.color == "black")
end)

check("a pill is a chip: fully round, bordered", function()
  local f = Theme.pill("Reading")
  assert(f.bordersize == Theme.line.firm and f.radius > 0)
end)

print("\n== fill: black is active, grey is unavailable ==")

check("a filled, available button is black with white words", function()
  local f = frame(Theme.button("Save", 400, { filled = true }))
  assert(f.background == "black")
  assert(find(f, function(n) return n.kind == "Text" end).fgcolor == "white")
end)

check("an outlined, available button is white with black words and border", function()
  local b = Theme.button("Cancel", 400, {})
  local f = frame(b)
  assert(f.background == "white" and f.color == "black")
  assert(b.label.fgcolor == "black")
end)

check("an unavailable button is grey: fill, border and words, and never black", function()
  for _, filled in ipairs({ false, true }) do
    local b = Theme.button("Save", 400, { filled = filled, enabled = false })
    local f = frame(b)
    assert(f.background == Theme.WASH, "fill is " .. tostring(f.background) .. " (filled=" .. tostring(filled) .. ")")
    assert(f.color == "dark grey", "border is " .. tostring(f.color))
    assert(b.label.fgcolor == "dark grey", "words are " .. tostring(b.label.fgcolor))
    assert(b.callback == nil, "an unavailable button must not respond")
  end
end)

check("a progress bar's empty track is the only grey it draws", function()
  local calls = {}
  local bb = { paintRect = function(_, x, y, w, h, c) calls[#calls + 1] = { x = x, w = w, c = c } end }
  local bar = Theme.progress { width = 200, height = 10, percentage = 0.5 }
  bar:paintTo(bb, 0, 0)
  assert(calls[1].c == Theme.MID and calls[1].w == 200, "the track comes first")
  assert(calls[2].c == "black" and calls[2].w == 100, "the fill is solid black, to the percentage")
end)

print("\n== static information has no fill and no border ==")

check("a note is words between two rules: no frame, no background", function()
  local n = Theme.note("You are offline", 400)
  assert(frame(n) == nil, "a note must not sit in a frame")
  local rules = 0
  for _, child in ipairs(n) do if child.kind == "Line" then rules = rules + 1 end end
  assert(rules == 2, "rules: " .. rules)
end)

check("a fact (Theme.label) is plain, regular text", function()
  local t = Theme.label("Waiting to sync")
  assert(t.kind == "Text" and not t.bold)
end)

print("\n== the switch is black when on ==")

check("an option that is on is a black pill with a white knob at the right", function()
  local calls = {}
  local bb = {
    paintRoundedRect = function(_, x, y, w, h, c) calls[#calls + 1] = { "pill", c, x, w } end,
    paintCircle = function(_, cx, cy, rad, c) calls[#calls + 1] = { "knob", c, cx } end,
  }
  local on = Theme.switch(true)
  on:paintTo(bb, 0, 0)
  assert(calls[1][1] == "pill" and calls[1][2] == "black" and #calls == 2, "an on switch is one black pill and a knob")
  assert(calls[2][2] == "white" and calls[2][3] > calls[1][4] / 2, "the knob is white and on the right")
end)

check("an option that is off is outlined, with a black knob at the left", function()
  local calls = {}
  local bb = {
    paintRoundedRect = function(_, x, y, w, h, c) calls[#calls + 1] = { "pill", c } end,
    paintCircle = function(_, cx, cy, rad, c) calls[#calls + 1] = { "knob", c, cx } end,
  }
  Theme.switch(false):paintTo(bb, 0, 0)
  assert(calls[1][2] == "black" and calls[2][2] == "white", "black outline, white inside")
  assert(calls[3][1] == "knob" and calls[3][2] == "black" and calls[3][3] < 26, "black knob at the left")
end)

check("an unavailable switch is dark grey, not black", function()
  local seen = {}
  local bb = {
    paintRoundedRect = function(_, x, y, w, h, c) seen[#seen + 1] = c end,
    paintCircle = function(_, cx, cy, rad, c) seen[#seen + 1] = c end,
  }
  Theme.switch(true, false):paintTo(bb, 0, 0)
  assert(seen[1] == "dark grey")
end)

check("one choice of several is a ring, with a solid centre on the chosen one", function()
  local function draw(selected, enabled)
    local calls = {}
    local bb = { paintCircle = function(_, cx, cy, rad, c, w) calls[#calls + 1] = { rad = rad, c = c, ring = w ~= nil } end }
    Theme.radio(selected, enabled):paintTo(bb, 0, 0)
    return calls
  end
  local off, on = draw(false), draw(true)
  assert(#off == 1 and off[1].ring and off[1].c == "black", "an unchosen one is a ring")
  assert(#on == 2 and on[2].rad < on[1].rad and not on[2].ring, "the chosen one has a solid centre")
  assert(draw(true, false)[1].c == "dark grey", "unavailable is grey")
end)

print("\n== chevron: opens something ==")

check("the chevron is the bundled icon", function()
  local c = Theme.chevron()
  assert(c.kind == "Icon" and c.file:match("icons/chevron%-right%.svg$"), tostring(c.file))
end)

check("a pill carries one when asked, a button only when it is available and unfilled", function()
  assert(#icons(Theme.pill("Reading", { chevron = true })) == 1)
  assert(#icons(Theme.pill("Reading")) == 0)
  assert(#icons(Theme.button("Shelf", 400, { chevron = true })) == 1)
  assert(#icons(Theme.button("Shelf", 400, { chevron = true, filled = true })) == 0, "a black chevron would vanish on a black button")
  assert(#icons(Theme.button("Shelf", 400, { chevron = true, enabled = false })) == 0, "an unavailable button opens nothing")
end)

print("\n== font: serif is a name, bold sans is a control ==")

check("serif text uses the serif face and does not ask for extra bold", function()
  FONT_MISSING = false
  local t = Theme.text("The Dispossessed", "title", { serif = true })
  assert(t.face.name == "NotoSerif-Bold.ttf" and not t.bold)
end)

check("without the serif font, text falls back to the UI face in bold", function()
  FONT_MISSING = true
  local t = Theme.text("The Dispossessed", "title", { serif = true })
  FONT_MISSING = false
  assert(t.face.name == "cfont" and t.bold == true)
end)

check("a control's label is bold sans", function()
  local b = Theme.button("Save", 400, {})
  assert(b.label.bold == true and b.label.face.name == "cfont")
end)

r.finish()
