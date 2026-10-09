-- The top of a list screen: the shared title bar (Back, the title, the X, and a second
-- icon beside the X when there is something to reload) with a row of buttons directly
-- under it (Sort, Search, New search).
--
-- It is handed to KOReader's Menu as `custom_title_bar`, so it answers what the Menu asks
-- of a title bar:
--   * getHeight() is the height of the whole header (title bar and row), because the Menu
--     sizes its rows from it and the vendored list reads `dimen.h`; both are kept equal to
--     what the header paints.
--   * setTitle / setSubTitle / setLeftIcon are passed to the title bar.
--   * generateVerticalLayout() lists the buttons for key navigation.
-- The Menu wires no close or icon callbacks into a custom bar, so Back and the X are wired
-- here (Theme.titleBar does it; the X always quits the plugin).
--
-- The row is not part of the TitleBar: a child of an OverlapGroup does not count towards
-- its size, so the header is a VerticalGroup of the bar and the row.

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Device = require("device")

local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local ListHeader = VerticalGroup:extend {
  title = "",
  width = nil,
  -- Back at the left
  back_callback = nil,
  -- the second icon just left of the X (a reload), and what it does
  right_icon = nil,
  right_callback = nil,
  -- the row: { { text, callback, filled, chevron, narrow }, ... }. A narrow button is a
  -- small square (the x that clears a search); the others share the rest of the width.
  -- No buttons, no row (and no height for it).
  buttons = nil,
  show_parent = nil,
  align = "left",
}

function ListHeader:init()
  self.width = self.width or Screen:getWidth()
  -- the vendored list reads dimen.h, and Refresh and tests read the position, which
  -- paintTo fills in
  self.dimen = Geom:new { x = 0, y = 0, w = self.width, h = 0 }
  self.row_buttons = {}
  self:buildBar()
  self:assemble(self:buildRow())
end

function ListHeader:buildBar()
  self.title_bar = Theme.titleBar {
    title = self.title,
    width = self.width,
    back_callback = self.back_callback,
    right_icon = self.right_icon or nil,
    right_callback = self.right_callback,
    show_parent = self.show_parent,
  }
  -- callers and tests reach the buttons through the header, as through a TitleBar
  self.left_button = self.title_bar.left_button
  self.right_button = self.title_bar.right_button
end

-- The row of buttons, or nil when there are none. Every button is the same height, so
-- the row is one height whatever it shows.
function ListHeader:buildRow()
  self.row_buttons = {}
  local specs = self.buttons or {}
  if #specs == 0 then return nil end

  local gap = Theme.space.m
  local narrow_w = Theme.px(56)
  local room = self.width - 2 * Theme.margin - (#specs - 1) * gap
  local wide = 0
  for _, spec in ipairs(specs) do
    if spec.narrow then room = room - narrow_w else wide = wide + 1 end
  end
  local each = wide > 0 and math.max(narrow_w, math.floor(room / wide)) or 0
  -- the pixels left over go to the last wide button, so the row ends at the margin
  local extra = wide > 0 and math.max(0, room - each * wide) or 0

  local line = HorizontalGroup:new { align = "center", Theme.hspan(Theme.margin) }
  local last_wide
  for i, spec in ipairs(specs) do
    if not spec.narrow then last_wide = i end
  end
  for i, spec in ipairs(specs) do
    if i > 1 then table.insert(line, Theme.hspan(gap)) end
    local w = spec.narrow and narrow_w or (each + (i == last_wide and extra or 0))
    local button = Theme.button(spec.text, w, {
      filled = spec.filled,
      chevron = spec.chevron,
      callback = spec.callback,
    })
    table.insert(self.row_buttons, button)
    table.insert(line, button)
  end

  return LeftContainer:new {
    dimen = Geom:new { x = 0, y = 0, w = self.width, h = Theme.BUTTON_H + 2 * Theme.space.s },
    line,
  }
end

-- Put the bar and the row in place, and keep dimen the size of what is painted.
function ListHeader:assemble(row)
  table.insert(self, self.title_bar)
  if row then table.insert(self, row) end
  self:resetLayout()
  self.dimen.h = self:getSize().h
end

function ListHeader:getHeight()
  return self:getSize().h
end

-- The row is asked first. The bar's Back and X have tap zones that reach past the bar
-- (to be easy to hit), over the top edge of the row's outer buttons; a tap on one of
-- those buttons is theirs, and must not go back, or quit the plugin.
function ListHeader:propagateEvent(event)
  for i = #self, 1, -1 do
    if self[i]:handleEvent(event) then return true end
  end
  return false
end

function ListHeader:paintTo(bb, x, y)
  self.dimen.x, self.dimen.y = x, y
  VerticalGroup.paintTo(self, bb, x, y)
end

function ListHeader:setTitle(title, no_refresh)
  self.title = title
  self.title_bar:setTitle(title, no_refresh)
  self:resetLayout()
end

function ListHeader:setSubTitle(subtitle, no_refresh)
  self.title_bar:setSubTitle(subtitle, no_refresh)
  self:resetLayout()
end

-- (only the Menu's setTitleBarLeftIcon asks for this, which the plugin does not use)
function ListHeader:setLeftIcon(icon)
  self.title_bar:setLeftIcon(icon)
  self:resetLayout()
end

-- The bar's buttons, then the row's: the Menu merges this into its focus layout.
function ListHeader:generateVerticalLayout()
  local layout = self.title_bar:generateVerticalLayout()
  if #self.row_buttons > 0 then
    local row = {}
    for i, button in ipairs(self.row_buttons) do row[i] = button end
    table.insert(layout, row)
  end
  return layout
end

--
-- Change the title, the second icon and what it does, or the row, in place: the Menu
-- keeps a reference to this object, so it is not replaced. `right_icon = false` removes
-- the second icon. Only what changed is rebuilt (the bar when its title or icon changed,
-- the row when `buttons` is given), and the header stays the same height. The caller
-- refreshes the screen.
--
function ListHeader:update(opts)
  opts = opts or {}
  local bar_changed = false
  for _, key in ipairs({ "title", "right_icon", "right_callback" }) do
    local value = opts[key]
    if value ~= nil and (value or false) ~= (self[key] or false) then
      self[key] = value
      bar_changed = true
    end
  end
  local row_changed = opts.buttons ~= nil
  if row_changed then self.buttons = opts.buttons end
  if not (bar_changed or row_changed) then return end

  local old_bar, old_row = self.title_bar, self[2]
  while table.remove(self) do end -- the old children are freed below, once replaced
  if bar_changed then self:buildBar() end
  -- (not `a and b or c`: no buttons is a row of nil, which must not bring the old row back)
  local row = old_row
  if row_changed then row = self:buildRow() end
  self:assemble(row)
  if bar_changed then old_bar:free() end
  if row_changed and old_row then old_row:free() end
end

return ListHeader
