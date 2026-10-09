-- The plugin's settings, as a screen of their own.
--
-- The settings live in the reader / file browser menu; the home screen (which can
-- be launched from another plugin) needs a way in too. This shows the same item
-- tables as a page in the family's style: two tiles at the top (Sync and the
-- Account, when the menu has them), then the options as a list of plain rows with a hairline
-- between them, and at each row's end what tapping it does: a switch for an option that is on
-- or off, a radio mark for the chosen one of several, a chevron for a submenu or anything
-- that opens a screen or a picker, nothing for a plain action (which is bold), the row grey
-- when it is unavailable. A first "Back" row inside a submenu goes up one level; Back (or the
-- close icon) leaves the screen.
--
-- Not a Menu: rows are laid out whole and the page scrolls only when it is
-- taller than the screen, in which case every tappable row is clipped to what
-- the scroll area shows (see viewport.lua).

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Refresh = require("hardcover/lib/ui/refresh")
local SettingsItems = require("hardcover/lib/settings_items")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")
local Viewport = require("hardcover/lib/ui/viewport")

local Screen = Device.screen

local BACK_ARROW = "\226\128\185" -- single left angle quote

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

local text = Theme.text

-- One row of the list: its words at the left, and at the end the cue for what tapping does: a
-- switch (an option that is on or off), a radio mark (the chosen one of several), a chevron
-- (it opens a level, a screen or a picker) or an icon. A row has no box of its own: the
-- hairline under it and that cue are what make it a row you can tap. An action (nothing at
-- the end) is in bold, and an unavailable row is grey with nothing to tap at its end.
function SettingsScreen:buildRow(row, width, viewport)
  local h = Screen:scaleBySize(50)
  local right
  if row.back then
    right = nil
  elseif row.checkable and row.radio then
    right = Theme.radio(row.checked, not row.dim)
  elseif row.checkable then
    right = Theme.switch(row.checked, not row.dim)
  elseif row.icon then
    right = Theme.icon(row.icon, Theme.px(22))
  elseif (row.submenu or row.opens) and not row.dim then
    right = Theme.chevron()
  end
  local right_w = right and (right:getSize().w + Theme.space.m) or 0
  -- the Back row leads with an arrow icon, not a typed one
  local lead = row.back and Theme.icon("back", Theme.px(22)) or nil
  local lead_w = lead and (lead:getSize().w + Theme.space.s) or 0
  local is_action = not right and not row.back and not row.dim
  -- a menu label that ends in its value's colon ("Track progress settings: ")
  -- reads as a dangling colon here
  local shown = row.back and _("Back") or (row.text:gsub("[:%s]+$", ""))
  local label = text(shown, "body", {
    bold = is_action,
    grey = row.dim,
    width = width - right_w - lead_w,
  })
  local content = HorizontalGroup:new { align = "center" }
  if lead then
    table.insert(content, lead)
    table.insert(content, Theme.hspan("s"))
  end
  table.insert(content, label)
  if right then
    table.insert(content, Theme.hspan(math.max(0, width - lead_w - label:getSize().w - right:getSize().w)))
    table.insert(content, right)
  end
  local box = FrameContainer:new {
    bordersize = 0,
    padding = 0,
    margin = 0,
    width = width,
    height = h,
    background = Theme.WHITE,
    LeftContainer:new {
      dimen = Geom:new { w = width, h = h },
      content,
    },
  }
  local tap = TapRow:new {
    callback = row.choose,
    hold_callback = row.hold,
    viewport = viewport,
    feedback = true,
    box,
  }
  tap.text = row.text
  self.taps[#self.taps + 1] = { tap = tap, shows = row.text .. "|" .. tostring(row.checked) .. "|" .. tostring(row.dim) }
  return tap
end

-- One of the two header tiles: what it is (small, grey), then what it says
-- (wrapping, so a long status is not cut). `height` is the tallest tile's, so
-- the pair is level.
function SettingsScreen:buildTile(row, width, height, viewport)
  local inner = width - 2 * Theme.line.firm
  local value = row.text
  -- "Account: Signed in" under an "Account" label says the label twice
  local prefix = row.tile .. ": "
  if value:sub(1, #prefix) == prefix then value = value:sub(#prefix + 1) end
  local text_w = inner - 2 * Theme.space.m
  local content = VerticalGroup:new {
    align = "left",
    text(row.tile, "small", { grey = true, width = text_w }),
    TextBoxWidget:new {
      text = value,
      face = (Theme.serif("title")),
      bold = select(2, Theme.serif("title")),
      width = text_w,
      fgcolor = row.dim and Theme.DARK_GREY or Theme.BLACK,
    },
  }
  local h = height or (content:getSize().h + 2 * Theme.space.m)
  local box = FrameContainer:new {
    bordersize = Theme.line.firm,
    radius = Theme.controlRadius(width, h),
    padding = 0,
    margin = 0,
    width = width,
    height = h,
    color = row.dim and Theme.DARK_GREY or Theme.BLACK,
    background = row.dim and Theme.WASH or Theme.WHITE,
    LeftContainer:new {
      dimen = Geom:new { w = inner, h = h - 2 * Theme.line.firm },
      HorizontalGroup:new { Theme.hspan("m"), content },
    },
  }
  local tap = TapRow:new {
    callback = row.choose,
    hold_callback = row.hold,
    viewport = viewport,
    feedback = true,
    box,
  }
  tap.text = value
  tap.content_h = content:getSize().h + 2 * Theme.space.m
  if height then -- the measuring pass builds these too, and is not drawn
    self.taps[#self.taps + 1] = { tap = tap, shows = value .. "|" .. tostring(row.dim) }
  end
  return tap
end

-- The page's content for `rows`, laid out in `width`.
function SettingsScreen:buildContent(rows, width, viewport)
  local content = VerticalGroup:new { align = "left" }

  -- the tiles, side by side
  local tiles = {}
  for _, row in ipairs(rows) do
    if row.tile then tiles[#tiles + 1] = row end
  end
  local tile_w = math.floor((width - Theme.space.m) / 2)
  if #tiles > 0 then
    -- measure first, then build them all as tall as the tallest
    local tallest = Screen:scaleBySize(60)
    for _, row in ipairs(tiles) do
      tallest = math.max(tallest, self:buildTile(row, tile_w, nil, nil).content_h)
    end
    local line = HorizontalGroup:new {}
    for i, row in ipairs(tiles) do
      if i > 1 then table.insert(line, Theme.hspan("m")) end
      table.insert(line, self:buildTile(row, tile_w, tallest, viewport))
    end
    table.insert(content, line)
    table.insert(content, Theme.span("m"))
    table.insert(content, Theme.sectionHeader(_("Options"), width))
  else
    -- no heading to draw the list's top edge: a firm rule does
    table.insert(content, Theme.rule(width, true))
  end

  -- the rows are plain, a hairline under each (the heading's or the firm rule is the top);
  -- a group of rows ends with a little more room
  for _, row in ipairs(rows) do
    if not row.tile then
      table.insert(content, self:buildRow(row, width, viewport))
      table.insert(content, Theme.rule(width, false))
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

  if #self.stack > 0 then
    table.insert(rows, 1, {
      text = BACK_ARROW .. " " .. _("Back"),
      back = true,
      choose = function()
        self.current = table.remove(self.stack)
        self:render()
      end,
    })
  end

  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local title_bar = Theme.titleBar {
    title = (current.title:gsub("[:%s]+$", "")),
    back_callback = function() self:onClose() end,
    show_parent = self,
  }
  self.title_bar = title_bar
  local room = screen_h - title_bar:getSize().h

  -- first at full width; if that is taller than the screen, again narrower (to
  -- leave the scroll bar its gutter) inside a scrolling container
  local width = screen_w - 2 * M
  local content = self:buildContent(rows, width, nil)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    local gutter = 3 * (ScrollableContainer.scroll_bar_width or Screen:scaleBySize(6))
    width = screen_w - 2 * M - gutter
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = self,
    }
    local scroll = self.scroll
    self.taps = {} -- the first pass's rows are not the ones drawn
    content = self:buildContent(rows, width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
    body = scroll
  else
    body = HorizontalGroup:new { Theme.hspan(M), content }
  end
  self.content_width = width

  self.frame = FrameContainer:new {
    width = screen_w,
    height = screen_h,
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new { align = "left", title_bar, Theme.span("m"), body },
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
