-- The Library's Activity tab: what you and the readers you follow lately did on Hardcover, newest
-- first. One row per entry, every row the same height: a line in bold (the book for a status change,
-- the text for a note, quote or review) and a small line under it (the day, who, and what kind of
-- entry it is). A row that has something to open shows a chevron, and tapping it opens the whole text
-- or the book. Under the last row a visible "Load more" button asks for the next page while there is
-- one, and "No more activity" says there is none.
--
-- The body fetches nothing itself. DialogManager:showActivity feeds it (setEntries, setMessage) and
-- supplies `more_cb`. Row text comes from hardcover/lib/feed.lua.

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local Draw = require("hardcover/lib/ui/components/draw")
local Feed = require("hardcover/lib/feed")
local Hosted = require("hardcover/lib/ui/hosted")
local ListItem = require("hardcover/lib/ui/components/list_item")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Theme = require("hardcover/lib/ui/theme")

local ActivityBody = InputContainer:extend {
  name = "hardcover_activity",
  entries = nil,   -- Feed.parse's entries, in display order
  message = nil,   -- shown instead of the rows: loading, nothing yet, offline
  has_more = false,
  loading = false, -- the next page is on its way
  select_cb = nil, -- function(entry), for a row that has something to open
  more_cb = nil,   -- function(), the Load more button
  shell = nil,
  width = nil,
  height = nil,
  parent = nil,    -- the Library body that holds this tab
}

function ActivityBody:init()
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  self.entries = self.entries or {}
  self:build()
end

function ActivityBody:rows(width)
  local group = VerticalGroup:new { align = "left" }
  local icon = Theme.mmd.row.icon
  -- dividers start after the leading icon
  local divider_x = ListItem.PAD + icon + Theme.px(16)
  for _i, entry in ipairs(self.entries) do
    local row = Feed.row(entry)
    group[#group + 1] = ListItem.new {
      width = width, label = row.label, support = row.support,
      lead = Theme.icon(row.icon, icon),
      trailing = row.action and Draw.chevron("right") or nil,
      divider = "dotted", divider_x = divider_x,
      callback = row.action and function() if self.select_cb then self.select_cb(entry) end end or nil,
    }
  end

  -- the end of the list: a way to ask for more, or the word that there is none
  local M = Theme.margin
  group[#group + 1] = Theme.span("m")
  if self.has_more then
    group[#group + 1] = HorizontalGroup:new { Theme.hspan(M),
      Button.new { label = self.loading and _("Loading\226\128\166") or _("Load more"),
        w = width - 2 * M, h = Theme.BUTTON_H, callback = function() self:loadMore() end } }
  else
    local done = Theme.mmdText(_("No more activity"), "text", 18, { secondary = true })
    group[#group + 1] = HorizontalGroup:new {
      Theme.hspan(math.max(0, math.floor((width - done:getSize().w) / 2))), done }
  end
  group[#group + 1] = Theme.span("xl")
  return group
end

function ActivityBody:build()
  local w, h = Hosted.size(self)
  local body
  self.scroll = nil
  if self.message then
    local face, bold = Theme.mmdFace("text", 18)
    body = CenterContainer:new { dimen = Geom:new { w = w, h = h },
      TextBoxWidget:new { text = self.message, face = face, bold = bold, width = w - 4 * Theme.margin,
        alignment = "center", fgcolor = Theme.secondary() } }
  else
    local group = self:rows(w)
    body = group
    if group:getSize().h > h then
      group = self:rows(w - ScrollControl.gutter())
      self.scroll = ScrollableContainer:new { dimen = Geom:new { x = 0, y = 0, w = w, h = h },
        show_parent = Hosted.window(self) }
      self.scroll[1] = group
      body = ScrollControl.wrap(self.scroll, group)
    end
  end
  self[1] = FrameContainer:new { width = w, height = h, background = Theme.WHITE,
    bordersize = 0, padding = 0, margin = 0, body }
end

-- Build again from the current state, staying where the page was scrolled to.
function ActivityBody:rebuild()
  local offset = self.scroll and self.scroll:getScrolledOffset()
  if self[1] and type(self[1].free) == "function" then pcall(function() self[1]:free() end) end
  self[1] = nil
  self:build()
  if offset and self.scroll then self.scroll:setScrolledOffset(offset) end
  Hosted.dirty(self)
end

-- A single message in place of the rows.
function ActivityBody:setMessage(message)
  self.message = message
  self.has_more = false
  self.loading = false
  self:rebuild()
end

-- Show these entries (the first page, or the first page followed by later ones).
function ActivityBody:setEntries(entries, has_more)
  self.message = nil
  self.entries = entries or {}
  self.has_more = has_more == true
  self.loading = false
  if #self.entries == 0 then
    self:setMessage(_("No activity yet. Follow readers on hardcover.app to see theirs here."))
    return
  end
  self:rebuild()
end

-- The next page was asked for (or failed): the button says so.
function ActivityBody:setLoading(loading)
  self.loading = loading == true
  self:rebuild()
end

-- Guarded so a double tap cannot fire two requests.
function ActivityBody:loadMore()
  if self.loading or not self.has_more or not self.more_cb then return end
  self:setLoading(true)
  self.more_cb()
end

return ActivityBody
