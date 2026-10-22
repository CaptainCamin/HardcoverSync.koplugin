-- The journal of the open book, reached from the reader panel: this book's status changes, notes,
-- quotes and reviews on Hardcover, newest first. A full screen of its own (the MMD top bar with a
-- back arrow) around the Journal tab's list, which it hosts the way the shell hosts a tab: it is
-- the window the body repaints through.

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local JournalBody = require("hardcover/lib/ui/journal_body")
local TopBar = require("hardcover/lib/ui/components/top_bar")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local JournalScreen = InputContainer:extend {
  name = "hardcover_journal_screen",
  message = nil,    -- loading, offline: shown in place of the rows
  entries = nil,    -- Journal.parse's entries to start with (the saved ones)
  select_cb = nil,  -- function(entry)
  more_cb = nil,    -- function(), Load more
  close_callback = nil,
}

function JournalScreen:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  self.dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h }
  self.key_events.CloseJournal = { { "Back" } }

  local bar = TopBar.new { width = screen_w, title = _("Journal"), on_back = function() self:onClose() end }
  self.body = JournalBody:new {
    shell = self, width = screen_w, height = screen_h - bar:getSize().h,
    message = self.message, entries = self.entries, select_cb = self.select_cb, more_cb = self.more_cb,
  }
  self[1] = FrameContainer:new {
    width = screen_w, height = screen_h, background = Theme.WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", bar, self.body },
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

-- leaving: late covers must find it gone, and the body lets go of the ones it decoded
function JournalScreen:onCloseWidget()
  self.closed = true
  self.body:onCloseWidget()
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
