-- The journal of the open book, reached from the reader panel: this book's status changes, notes,
-- quotes and reviews on Hardcover, newest first. A full screen of its own (the MMD top bar with a
-- back arrow) around the Activity tab's list, which it hosts the way the
-- shell hosts a tab: it is the window the body repaints through. A plus FAB at the
-- bottom right (`add_cb`) is the one place to write a note, a quote or a review of the book.

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local ActivityBody = require("hardcover/lib/ui/activity_body")
local Fab = require("hardcover/lib/ui/components/fab")
local TopBar = require("hardcover/lib/ui/components/top_bar")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local JournalScreen = InputContainer:extend {
  name = "hardcover_journal_screen",
  message = nil,    -- loading, offline: shown in place of the rows
  entries = nil,    -- Feed.parse's entries to start with (the saved ones)
  select_cb = nil,  -- function(entry)
  more_cb = nil,    -- function(), Load more
  add_cb = nil,     -- function(), the Add entry FAB (none: no FAB)
  close_callback = nil,
}

function JournalScreen:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  self.dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h }
  self.key_events.CloseJournal = { { "Back" } }

  local bar = TopBar.new { width = screen_w, title = _("Journal"), on_back = function() self:onClose() end }
  -- the Add entry FAB (a plus), anchored bottom right; the list stops above it, so it never
  -- covers a row
  local footer
  if self.add_cb then
    local fab = Fab.new { icon = "plus", scale = "medium", callback = self.add_cb }
    footer = VerticalGroup:new { align = "left",
      HorizontalGroup:new { Theme.hspan(screen_w - fab:getSize().w - Theme.px(12)), fab },
      Theme.span(Theme.px(12)) }
  end
  self.body = ActivityBody:new {
    shell = self, width = screen_w,
    height = screen_h - bar:getSize().h - (footer and footer:getSize().h or 0),
    message = self.message, entries = self.entries, select_cb = self.select_cb, more_cb = self.more_cb,
  }
  self[1] = FrameContainer:new {
    width = screen_w, height = screen_h, background = Theme.WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", bar, self.body, footer },
  }
end

-- the body asks its shell whether it is the one showing (see ui/hosted.lua)
function JournalScreen:isActive() return true end

function JournalScreen:setEntries(entries, has_more) self.body:setEntries(entries, has_more) end
function JournalScreen:setMessage(message) self.body:setMessage(message) end
function JournalScreen:setLoading(loading) self.body:setLoading(loading) end
function JournalScreen:loadMore() self.body:loadMore() end

function JournalScreen:onShow()
  UIManager:setDirty(self, "ui")
end

function JournalScreen:onCloseJournal()
  return self:onClose()
end

function JournalScreen:onClose()
  UIManager:close(self)
  if self.close_callback then self.close_callback() end
  return true
end

return JournalScreen
