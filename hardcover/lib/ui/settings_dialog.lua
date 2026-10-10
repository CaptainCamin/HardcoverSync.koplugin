-- The plugin's settings, as a screen of their own.
--
-- The settings live in the reader / file browser menu; the home screen (which can be launched from
-- another plugin) needs a way in too. This shows the same item tables as a flat list in the MMD style:
-- a top bar with a back arrow (up one level inside a submenu, out of the screen at the top), then one
-- row per option with a real switch for an option that is on or off, a chevron for a submenu and
-- nothing for a plain action. The Sync and Account tiles at the head of the menu become the first two
-- rows, with their status as the supporting line. An unavailable option shows a hollow-knob switch (or a
-- plain label), never grey alone, and does nothing when tapped. Dotted dividers, one fixed height per
-- kind of row.
--
-- Not a Menu: rows are laid out whole and the page scrolls only when it is taller than the screen, by
-- pages that land on row edges with the scroll control (see components/scroll_control.lua), every
-- tappable row clipped to what the scroll area shows (see viewport.lua).

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Draw = require("hardcover/lib/ui/components/draw")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Refresh = require("hardcover/lib/ui/refresh")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local SettingsItems = require("hardcover/lib/settings_items")
local Switch = require("hardcover/lib/ui/components/switch")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")
local Viewport = require("hardcover/lib/ui/viewport")

local Screen = Device.screen

local SettingsScreen = InputContainer:extend {
  name = "hardcover_settings",
  opts = nil,
}

function SettingsScreen:init()
  self.stack = {} -- { title, items } for the levels above this one
  self.current = { title = self.opts.title or _("Settings"), items = self.opts.items }
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.CloseSettings = { { "Back" } }
  self:render()
end

-- One option as a list item: its words, and at the end a switch, a chevron or nothing.
function SettingsScreen:buildRow(row, width, viewport)
  -- a menu label that ends in its value's colon ("Track progress settings: ") reads as a dangling
  -- colon here
  local label = (row.text:gsub("[:%s]+$", ""))
  local support
  if row.tile then
    -- "Account: Signed in" under an "Account" label says the label twice
    local prefix = row.tile .. ": "
    support = row.text:sub(1, #prefix) == prefix and row.text:sub(#prefix + 1) or row.text
    label = row.tile
  end
  local trailing
  if row.checkable then
    trailing = Switch.new { on = row.checked, unavailable = row.dim and not row.checked }
  elseif row.submenu or row.tile then
    trailing = Draw.chevron("right")
  end
  local item = ListItem.new {
    width = width,
    label = label,
    support = support,
    trailing = trailing,
    divider = "dotted",
    dim = row.dim,
    callback = row.choose,
    hold_callback = row.hold,
    viewport = viewport,
  }
  item.text = row.text
  self.taps[#self.taps + 1] = { tap = item, shows = row.text .. "|" .. tostring(row.checked) .. "|" .. tostring(row.dim) }
  return item
end

-- The page's content for `rows`, laid out in `width`.
function SettingsScreen:buildContent(rows, width, viewport)
  local content = VerticalGroup:new { align = "left" }
  -- the Sync and Account tiles first, in the order the menu gives them
  for _, row in ipairs(rows) do
    if row.tile then table.insert(content, self:buildRow(row, width, viewport)) end
  end
  for _, row in ipairs(rows) do
    if not row.tile then
      table.insert(content, self:buildRow(row, width, viewport))
      if row.separator then table.insert(content, Theme.span("m")) end
    end
  end
  table.insert(content, Theme.span("l"))
  return content
end

-- Where each row is and what it shows, for comparing after a re-render.
function SettingsScreen:snapshot()
  local snap = {}
  for i, t in ipairs(self.taps or {}) do
    snap[i] = { shows = t.shows, rect = Refresh.copy(t.tap.dimen) }
  end
  return snap
end

-- The part of the screen a re-render changed, read after it is painted: the rows
-- that say something different, where they were and where they are. nil (the
-- whole panel) when the rows cannot be compared one for one.
function SettingsScreen:changedRegion(before)
  local after = self:snapshot()
  if #after ~= #before then return nil end
  local clip = self.scroll and self.scroll.dimen or { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  local region
  for i, now in ipairs(after) do
    local was = before[i]
    local moved = not (Refresh.valid(was.rect) and Refresh.valid(now.rect))
      or was.rect.y ~= now.rect.y or was.rect.h ~= now.rect.h or was.rect.x ~= now.rect.x
    if was.shows ~= now.shows or moved then
      if not (Refresh.valid(was.rect) and Refresh.valid(now.rect)) then return nil end
      local both = Refresh.union(was.rect, now.rect)
      region = Refresh.union(region, Viewport.intersect(both, clip) or nil)
    end
  end
  if region then return region end
  -- nothing the panel shows differs, or what differs is scrolled out of sight:
  -- the smallest refresh there is
  return { x = clip.x, y = clip.y, w = 1, h = 1 }
end

-- Painting is when the rows learn where they are.
function SettingsScreen:paintTo(...)
  InputContainer.paintTo(self, ...)
  self.painted = true
  self.pending_before = nil
end

--
-- Draw the current level. `keep` says it is the same level with some rows changed
-- (an option was ticked): the page then stays where it was scrolled to, and only
-- the rows that changed are redrawn on the panel. Without it (a new level, the
-- first draw) it starts at the top and redraws everything.
--
function SettingsScreen:render(keep)
  -- an option's callback may ask for a redraw twice (the menu's updateItems and
  -- our own); the second compares with what was last on screen, not with the
  -- first one's unpainted result
  local before = keep and (self.painted and self:snapshot() or self.pending_before) or nil
  local offset = keep and self.scroll and self.scroll.getScrolledOffset and self.scroll:getScrolledOffset() or nil
  self.taps = {}
  local opts, current = self.opts, self.current
  local items = current.items
  if current.source and current.source.sub_item_table_func then
    items = current.source.sub_item_table_func()
  end
  local rows = SettingsItems.rows(items, function(title, children, item)
    self.stack[#self.stack + 1] = self.current
    -- asked again on every draw, so a level shows what is true now (the
    -- account's Sign in / Sign out rows change when you sign in)
    self.current = { title = title, items = children, source = item }
    self:render()
  end, function()
    self:render(true)
  end)

  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local title_bar = TopBar.new {
    width = screen_w,
    title = (current.title:gsub("[:%s]+$", "")),
    on_back = function() self:goBack() end,
  }
  self.title_bar = title_bar
  local room = screen_h - title_bar:getSize().h

  -- first at full width; if that is taller than the screen, again narrower (to leave the scroll
  -- control its gutter) inside a scrolling container
  local width = screen_w
  local content = self:buildContent(rows, width, nil)
  local body
  self.scroll = nil
  if content:getSize().h > room then
    width = screen_w - ScrollControl.gutter()
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = self,
    }
    local scroll = self.scroll
    self.taps = {} -- the first pass's rows are not the ones drawn
    content = self:buildContent(rows, width, function() return scroll.dimen end)
    scroll[1] = content
    body = ScrollControl.wrap(scroll, content)
  else
    body = content
  end
  self.content_width = width

  self.frame = FrameContainer:new {
    width = screen_w,
    height = screen_h,
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new { align = "left", title_bar, body },
  }
  self[1] = self.frame

  if offset and self.scroll and self.scroll.setScrolledOffset then
    self.scroll:setScrolledOffset(offset)
  end
  self.painted = false
  self.pending_before = before
  if not before then
    UIManager:setDirty(self, "ui")
    return
  end
  Refresh.region(self, function() return self:changedRegion(before) end)
end

-- show() queues no refresh of its own: ask for the first full draw, which a small
-- refresh queued in the same tick must not replace.
function SettingsScreen:onShow()
  UIManager:setDirty(self, "ui")
end

-- leaving the screen must repaint what was under it
function SettingsScreen:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

-- The top bar's back arrow: up one level inside a submenu, out of the screen at the top.
function SettingsScreen:goBack()
  if #self.stack > 0 then
    self.current = table.remove(self.stack)
    self:render()
    return true
  end
  return self:onClose()
end

function SettingsScreen:onCloseSettings()
  return self:onClose()
end

function SettingsScreen:onClose()
  UIManager:close(self)
  if self.opts.on_close then self.opts.on_close() end
  return true
end

local SettingsDialog = {}

function SettingsDialog.show(opts)
  local screen = SettingsScreen:new { opts = opts }
  UIManager:show(screen)
  return screen
end

return SettingsDialog
