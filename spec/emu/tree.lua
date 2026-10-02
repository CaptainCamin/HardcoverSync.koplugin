--[[--
Walk a painted widget tree and collect what is actually on screen.

A PNG proves pixels changed; it does not say *what* changed. This walks the
widget tree the same way KOReader's own showtext/debug tooling does and returns
the visible text plus each widget's geometry, so a scenario can assert
("this row says X", "these two buttons do not overlap", "the title is not
truncated") rather than only asserting that a file appeared.

Geometry is read from .dimen, which is assigned during paint -- so this must be
called after a repaint, and the dimensions it reports are the ones the device
would use.
]]

local M = {}

--[[--
Make text widgets remember where they were last painted.

A bare TextWidget/TextBoxWidget never gets a .dimen, so a scenario could read
its words but not tap or measure them. Wrapping paintTo to note the rectangle
gives every text node absolute coordinates. Call once after KOReader's
frontend is loaded.
]]
function M.instrument()
  for _, name in ipairs({ "ui/widget/textwidget", "ui/widget/textboxwidget" }) do
    local class = require(name)
    if not class._emu_instrumented then
      class._emu_instrumented = true
      local paint = class.paintTo
      class.paintTo = function(self, bb, x, y)
        -- only what is painted straight onto the screen has screen
        -- coordinates; inside a ScrollableContainer the target is its own
        -- buffer and the numbers would mean something else
        local ok, size = pcall(self.getSize, self)
        if ok and size and bb == require("device").screen.bb then
          self._emu_rect = { x = x, y = y, w = size.w, h = size.h }
        else
          self._emu_rect = nil
        end
        return paint(self, bb, x, y)
      end
    end
  end
end

--[[--
Depth-first over a widget's children.

KOReader children live in the widget table itself (numeric keys), not in a
single .children field, so iterate numerically to find sub-widgets.
]]
local function children(widget)
  local out = {}
  for k, v in pairs(widget) do
    if type(k) == "number" and type(v) == "table" and v.paintTo then
      out[#out + 1] = { key = k, widget = v }
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

local function text_of(widget)
  -- TextWidget and TextBoxWidget both keep their string in .text
  if type(widget.text) == "string" then
    return widget.text
  end
  return nil
end

--[[--
A widget's painted rectangle, or nil if it has none.

Only some widgets assign .dimen during paint -- a bare TextWidget inside a
VerticalGroup does not, while a Button inside a HorizontalGroup does. Requiring
.dimen therefore hides most of a screen's text, so fall back to getSize() and
treat the coordinates as relative rather than absolute when it is missing.
]]
local function rect_of(widget)
  -- the painted rectangle recorded by M.instrument, when there is one
  if widget._emu_rect then
    return widget._emu_rect
  end
  if widget.dimen and widget.dimen.w and widget.dimen.w > 0 then
    return widget.dimen
  end

  local ok, size = pcall(function() return widget:getSize() end)
  if ok and type(size) == "table" and size.w and size.w > 0 then
    -- x/y are unknown here; mark them so a caller can tell absolute from
    -- relative geometry rather than silently reading a bogus 0.
    return { x = size.x, y = size.y, w = size.w, h = size.h, relative = true }
  end

  return nil
end

--[[--
Collect visible text nodes, in paint order.

Paint order is what the reader actually sees top to bottom, and for KOReader's
layout containers it is exactly depth-first order through the tree. So the walk
records in visit order and does NOT re-sort afterwards.

Sorting by y looks tempting and is wrong: only some widgets assign .dimen, so a
sorted list interleaves nodes that have absolute coordinates with ones that do
not, and the result is scrambled. Metadata rows came out label-value-label-value
for exactly that reason.

Returns a list of { text, x, y, w, h, class, relative }.
]]
function M.collect(root)
  local nodes = {}
  local visited = {}

  local function add(widget, text, class)
    local rect = rect_of(widget)
    nodes[#nodes + 1] = {
      text = text,
      x = rect and rect.x or nil,
      y = rect and rect.y or nil,
      w = rect and rect.w or nil,
      h = rect and rect.h or nil,
      relative = (rect == nil) or rect.relative == true,
      class = class or widget.name or widget.class or "?",
    }
  end

  local function walk(widget, parent_text)
    if type(widget) ~= "table" or visited[widget] then return end
    visited[widget] = true

    local text = text_of(widget)

    -- A Button keeps its label in .text AND repeats it in a child TextWidget.
    -- Recording both lists "Close" twice, so skip a child whose text merely
    -- repeats its parent's.
    if text and text ~= "" and text ~= parent_text then
      add(widget, text)
    end

    -- Dialogs carry their heading in .title rather than as a child widget.
    if widget.text == nil and type(widget.title) == "string" and widget.title ~= "" then
      add(widget, widget.title, (widget.name or "widget") .. ".title")
    end

    local child_parent_text = text or parent_text
    for _, child in ipairs(children(widget)) do
      walk(child.widget, child_parent_text)
    end
  end

  walk(root, nil)
  return nodes
end

--[[--
All visible text as one newline-joined string.

Handy for a scenario assertion like:
    assert(emu:screenText()):find("Want to Read", 1, true)
]]
function M.text(root)
  local nodes = M.collect(root)
  local parts = {}
  for _, n in ipairs(nodes) do
    parts[#parts + 1] = n.text
  end
  return table.concat(parts, "\n")
end

--[[--
Do two rectangles overlap by more than `slop` pixels on both axes?

Returns the boolean plus the two overlap extents, so a caller can report how
bad a clash is rather than only that one happened. A small slop absorbs
KOReader's own padding.
]]
function M.overlaps(a, b, slop)
  slop = slop or 0
  local overlap_x = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x) - slop
  local overlap_y = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y) - slop
  return overlap_x > 0 and overlap_y > 0, overlap_x, overlap_y
end

--[[--
Report any pair of same-class interactive widgets that overlap.

Catches a FocusManager grid whose cells are sized wrong for the screen, which
is exactly the class of bug that only shows up at one resolution.
]]
function M.overlapping_pairs(root, classes)
  classes = classes or { Button = true, ["ui.widget.button"] = true }
  local nodes = {}
  local seen = {}

  local function walk(widget)
    if type(widget) ~= "table" or seen[widget] then return end
    seen[widget] = true
    if widget.dimen and widget.dimen.w and widget.dimen.w > 0 and classes[widget.name] then
      nodes[#nodes + 1] = { rect = widget.dimen, text = widget.text, name = widget.name }
    end
    for _, child in ipairs(children(widget)) do walk(child.widget) end
  end

  walk(root)

  local clashes = {}
  for i = 1, #nodes do
    for j = i + 1, #nodes do
      local hit, ox, oy = M.overlaps(nodes[i].rect, nodes[j].rect, 2)
      if hit then
        clashes[#clashes + 1] = {
          a = nodes[i].text or nodes[i].name,
          b = nodes[j].text or nodes[j].name,
          overlap_x = ox,
          overlap_y = oy,
        }
      end
    end
  end
  return clashes
end

return M
