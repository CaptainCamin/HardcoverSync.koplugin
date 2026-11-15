-- Reading history: one fixed-height row per read of a book, newest first, and the way into the
-- form that changes a read's dates or edition. It makes no API calls: the caller passes the reads
-- it has (from Hardcover, or the saved copy) and the state of each queued edit.
--
--   ReadHistoryDialog:new {
--     book = { title = "..." }, reads = detail.reads, states = { [read_id] = { text = "...",
--       kind = "waiting" | "decision" | "checking" } }, checked_at = os.time,
--     on_open_read = function(read) ... end, on_add = function() ... end,
--   }
--
-- `reads == nil` is "no saved copy", which is not the same as an empty list: offline with nothing
-- saved, the screen asks for one connection instead of showing an empty history.

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Draw = require("hardcover/lib/ui/components/draw")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Note = require("hardcover/lib/ui/components/note")
local ReadHistory = require("hardcover/lib/read_history")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

local ReadHistoryDialog = InputContainer:extend {
  name = "hardcover_read_history",
  book = nil,
  reads = nil,       -- nil: no saved copy; {}: known to have no reads
  states = nil,      -- [read id] = { text, kind }
  checked_at = nil,  -- when Hardcover last confirmed these reads (os.time)
  today = nil,       -- YYYY-MM-DD, for a test; the device's day otherwise
  on_open_read = nil,
  on_add = nil,
  on_close = nil,
}

-- "3 reads", "1 read", "No reads yet"
local function countText(count)
  if count == 0 then return _("No reads yet") end
  if count == 1 then return _("1 read") end
  return string.format(_("%d reads"), count)
end

-- "Hardcover checked today, 09:12", "Hardcover checked 12 Nov" or "… 12 Nov 2025".
local function checkedText(checked_at, today)
  if not (checked_at and checked_at > 0) then return nil end
  local day = os.date("%Y-%m-%d", checked_at)
  if day == today then
    return string.format(_("Hardcover checked today, %s"), os.date("%H:%M", checked_at))
  end
  return string.format(_("Hardcover checked %s"), ReadHistory.shortDate(day, today))
end

local function stateOf(states, read)
  local state = states and (states[read.id] or states[tostring(read.id)])
  if type(state) == "string" then state = { text = state, kind = "waiting" } end
  return type(state) == "table" and state.text and state or nil
end

local function stateIcon(kind)
  if kind == "decision" then return Draw.icon("warning", Theme.px(18)) end
  -- waiting and checking: Hardcover has it, or may already have it
  return Theme.icon("sync", Theme.px(18))
end

-- What a read's second line says when it is not a state: its format and pages.
function ReadHistoryDialog.supportFor(read)
  local format = ReadHistory.formatName(read)
  local pages = ReadHistory.editionPages(read)
  if format and pages then return string.format(_("%s · %d pages"), format, pages) end
  if format then return format end
  if pages then return string.format(_("%d pages"), pages) end
  return _("Edition not recorded")
end

function ReadHistoryDialog:init()
  self.checked_at = self.checked_at or 0
  self.today = self.today or os.date("%Y-%m-%d")
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.CloseReadHistory = { { "Back" } }
  self:build()
end

function ReadHistoryDialog:headerSupport()
  local count = countText(#(self.reads or {}))
  local checked = checkedText(self.checked_at, self.today)
  return checked and (count .. " · " .. checked) or count
end

function ReadHistoryDialog:readRow(read, width, viewport)
  local state = stateOf(self.states, read)
  local support = state and state.text or ReadHistoryDialog.supportFor(read)
  local icon = state and stateIcon(state.kind) or nil
  local item = ListItem.new {
    width = width,
    label = ReadHistory.rangeText(read),
    support = support,
    support_icon = icon,
    support_strong = state ~= nil,
    trailing = Draw.chevron("right"),
    divider = "dotted",
    viewport = viewport,
    callback = self.on_open_read and function() self.on_open_read(read) end or nil,
  }
  if not self.on_open_read then item.ges_events = {} end
  -- what the row shows, for a test to read without walking the widget tree
  item.support_strong = state ~= nil
  item.support_icon = icon
  self.items[#self.items + 1] = { read = read, row = item, label = item.text, support = support,
    state = state }
  return item
end

function ReadHistoryDialog:buildContent(width, viewport)
  self.items = {}
  self.add_row = nil
  self.offline_note = nil
  self.hint_text = nil
  self.empty_text = nil
  -- `cond and nil or value` would call headerSupport even when there is no saved copy
  if self.reads == nil then
    self.support_text = nil
  else
    self.support_text = self:headerSupport()
  end

  local c = VerticalGroup:new { align = "left", Theme.span("s") }
  c[#c + 1] = Theme.mmdText(self.book and self.book.title or "", "strong", 25, { width = width })
  if self.support_text then
    c[#c + 1] = Theme.span(Theme.px(4))
    c[#c + 1] = Theme.mmdText(self.support_text, "text", 18, { secondary = true, width = width })
  end
  c[#c + 1] = Theme.span("m")

  if self.reads == nil then
    -- no saved copy: do not show an empty history, and do not offer an addition that may duplicate
    self.empty_text = _("Connect once to load this book's reading history.")
    c[#c + 1] = Theme.mmdText(self.empty_text, "text", 18, { width = width })
    c[#c + 1] = Theme.span("l")
    return c
  end

  local rows = ReadHistory.normalize(self.reads)
  for _, read in ipairs(rows) do
    c[#c + 1] = self:readRow(read, width, viewport)
  end

  self.add_row = ListItem.new {
    width = width,
    label = _("Add a past read"),
    lead = Draw.icon("plus", Theme.px(22)),
    viewport = viewport,
    callback = self.on_add,
  }
  if not self.on_add then self.add_row.ges_events = {} end
  c[#c + 1] = self.add_row
  c[#c + 1] = Theme.span("m")

  -- how the screen works, not a state: the note stays whether or not there is a connection
  self.offline_note = Note.new {
    width = width,
    icon_name = "offline",
    title = _("Works offline."),
    text = _("Changes you make here are saved on this device and sent in order when you are connected."),
    text_wrap = true,
    dotted = true,
  }
  c[#c + 1] = self.offline_note
  c[#c + 1] = Theme.span(Theme.px(10))
  self.hint_text = _("Tap a read to change its dates or edition.")
  c[#c + 1] = Theme.mmdText(self.hint_text, "text", 18, { secondary = true, width = width })
  c[#c + 1] = Theme.span("l")
  return c
end

function ReadHistoryDialog:build()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local title_bar = TopBar.new {
    width = screen_w,
    title = _("Reading history"),
    on_back = function() self:close() end,
  }
  self.title_bar = title_bar
  local room = screen_h - title_bar:getSize().h

  local width = screen_w - 2 * Theme.margin
  local content = self:buildContent(width, nil)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    local gutter = ScrollControl.gutter()
    width = screen_w - 2 * Theme.margin - gutter
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = self,
    }
    local scroll = self.scroll
    content = self:buildContent(width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(Theme.margin), content }
    body = ScrollControl.wrap(scroll, content)
  else
    body = HorizontalGroup:new { Theme.hspan(Theme.margin), content }
  end
  self.content_width = width

  self.frame = FrameContainer:new {
    width = screen_w,
    height = screen_h,
    background = Theme.WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new { align = "left", title_bar, body },
  }
  self[1] = self.frame
end

function ReadHistoryDialog:close()
  UIManager:close(self)
  if self.on_close then self.on_close() end
  return true
end

function ReadHistoryDialog:onCloseReadHistory()
  return self:close()
end

function ReadHistoryDialog:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

return ReadHistoryDialog
