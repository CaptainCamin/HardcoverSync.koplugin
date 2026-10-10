-- Your lists, and the lists you follow: one row each, with the covers of its first
-- books, its name and how many books it holds. Choosing one opens it (the caller
-- shows its books in the shelf screen).
--
-- Not a Menu: rows are laid out whole and the page scrolls only when it is taller
-- than the screen, in which case every tappable row is clipped to what the scroll
-- area shows (see viewport.lua). Covers arrive after the rows are drawn, into
-- boxes that are already their final size, so nothing moves when they do.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local CoverCells = require("hardcover/lib/ui/cover_cells")
local Lists = require("hardcover/lib/lists")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local CHEVRON = "\226\128\186"

local ListsDialog = InputContainer:extend {
  name = "hardcover_lists",
  title = nil,
  mine = nil,        -- rows (see Lists.normalize); nil while loading
  following = nil,
  message = nil,     -- shown instead of the rows ("Loading your lists…", an empty state)
  mine_title = nil,       -- the first group's heading (default "Your lists")
  following_title = nil,  -- the second group's heading (default "Following")
  select_cb = nil,   -- called with the chosen row
  close_callback = nil,
  image_loader = nil,
}

function ListsDialog:init()
  self.closed = false
  self.title = self.title or _("Lists")
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.CloseLists = { { "Back" } }
  -- pictures already decoded are kept across rebuilds (see cover_cells.lua)
  self.covers = CoverCells:new {
    window = self,
    loader = function() return self.image_loader or require("hardcover/lib/ui/image_loader") end,
    -- a cover scrolled out of view needs no refresh
    clip = function() return self.scroll and self.scroll.dimen or nil end,
  }
  self:build()
end

local text = Theme.text

-- a cover box of the final size, with the generic book icon until the picture comes
function ListsDialog:coverCell(url, w, h)
  return self.covers:cell(url, w, h)
end

-- One list: its first covers, its name over its small print, and a chevron.
function ListsDialog:buildRow(row, width, viewport)
  local cw = Screen:scaleBySize(48)
  local ch = math.floor(cw * 1.5)
  local gap = Theme.space.xs
  -- a cover is drawn inside a hairline frame, so its slot is wider than the picture
  local slot = cw + 2 * Theme.line.hair
  local strip_w = Lists.COVERS * slot + (Lists.COVERS - 1) * gap

  local strip = HorizontalGroup:new { align = "center" }
  for i = 1, Lists.COVERS do
    if i > 1 then table.insert(strip, Theme.hspan(gap)) end
    if row.covers[i] then
      table.insert(strip, self:coverCell(row.covers[i], cw, ch))
    else
      table.insert(strip, Theme.hspan(slot)) -- keeps the names lined up
    end
  end

  local chevron = text(CHEVRON, "display", { bold = true })
  local text_w = width - strip_w - Theme.space.l - chevron:getSize().w - Theme.space.m
  local info = VerticalGroup:new {
    align = "left",
    text(row.name, "title", { bold = true, width = text_w }),
    Theme.span("xs"),
    text(Lists.subtitle(row), "small", { grey = true, width = text_w }),
  }
  -- left-aligned and centred vertically, so every name starts at the same x
  local middle = LeftContainer:new { dimen = Geom:new { w = text_w, h = ch }, info }

  local line = HorizontalGroup:new {
    align = "center",
    strip,
    Theme.hspan("l"),
    middle,
    Theme.hspan(Theme.space.m),
    chevron,
  }
  local tap = TapRow:new {
    callback = function()
      if self.select_cb then self.select_cb(row) end
    end,
    viewport = viewport,
    line,
  }
  tap.text = row.name
  return VerticalGroup:new {
    align = "left",
    Theme.rule(width, false),
    Theme.span("s"),
    tap,
    Theme.span("s"),
  }
end

function ListsDialog:buildContent(width, viewport)
  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("m"))

  local function section(title, rows)
    if not rows or #rows == 0 then return end
    local count = text(tostring(#rows), "small", { grey = true })
    table.insert(content, Theme.sectionHeader(title, width, count))
    table.insert(content, Theme.span("s"))
    for _i, row in ipairs(rows) do
      table.insert(content, self:buildRow(row, width, viewport))
    end
    table.insert(content, Theme.span("l"))
  end

  if self.message then
    table.insert(content, text(self.message, "body", { grey = true, width = width }))
    return content
  end
  section(self.mine_title or _("Your lists"), self.mine)
  section(self.following_title or _("Following"), self.following)
  return content
end

function ListsDialog:build()
  self.covers:begin()

  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local title_bar = Theme.titleBar {
    title = self.title,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }
  local room = screen_h - title_bar:getSize().h

  -- first at full width; if that is taller than the screen, again narrower (to
  -- leave the scroll bar its gutter) inside a scrolling container
  local width = screen_w - 2 * M
  local content = self:buildContent(width, nil)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    self.covers:begin() -- the first pass's boxes are not used
    local gutter = ScrollControl.gutter()
    width = screen_w - 2 * M - gutter
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = self,
    }
    local scroll = self.scroll
    content = self:buildContent(width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
    body = ScrollControl.wrap(scroll, content)
  else
    body = HorizontalGroup:new { Theme.hspan(M), content }
  end

  self.title_bar = title_bar
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
  self.covers:finish()
end

-- UIManager:show() queues no refresh of its own (it relies on a full-panel
-- fallback that only happens when nothing else is queued), and this screen queues
-- small refreshes of its own as covers and counts arrive. Ask for the first
-- full draw explicitly so it can never be skipped in favour of a small one.
function ListsDialog:onShow()
  UIManager:setDirty(self, "ui")
end

function ListsDialog:releaseCovers()
  self.covers:release()
end

function ListsDialog:rebuild()
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  UIManager:setDirty(self, "ui")
end

-- The lists have arrived (or there are none: pass a message).
function ListsDialog:setLists(mine, following, message)
  self.mine, self.following, self.message = mine, following, message
  self:rebuild()
end

function ListsDialog:setMessage(message)
  self.message = message
  self:rebuild()
end

-- leaving the screen must repaint what was under it
function ListsDialog:onCloseWidget()
  self.closed = true
  self:releaseCovers()
  UIManager:setDirty(nil, "ui")
end

function ListsDialog:onCloseLists()
  return self:onClose()
end

function ListsDialog:onClose()
  UIManager:close(self)
  if self.close_callback then self.close_callback() end
  return true
end

return ListsDialog
