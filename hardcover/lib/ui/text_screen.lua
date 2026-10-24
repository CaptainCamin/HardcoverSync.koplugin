-- A screen of text of its own: a book's whole synopsis, one review in full. The MMD top bar (a back
-- arrow and a short title), the subject as a serif heading under a thick rule, then the text, which
-- scrolls by page with the scroll control when it is longer than the screen. A short text fits and
-- shows no control. `buttons` (your own note in the Journal tab: Edit, Delete) stay along the
-- bottom, under the text, however far it is scrolled.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Button = require("hardcover/lib/ui/components/button")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

local TextScreen = InputContainer:extend {
  name = "hardcover_text_screen",
  title = nil,   -- the top bar's
  heading = nil, -- the serif heading over the text (a book's title)
  text = nil,
  buttons = nil, -- { { label, callback }, ... }, side by side along the bottom
  close_callback = nil,
}

function TextScreen:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  self.dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h }
  self.key_events.CloseText = { { "Back" } }

  local bar = TopBar.new { width = screen_w, title = self.title, on_back = function() self:onClose() end }
  local room = screen_h - bar:getSize().h
  local M = Theme.margin

  local actions
  if self.buttons and #self.buttons > 0 then
    local gap = Theme.space.m
    local n = #self.buttons
    local w = math.floor((screen_w - 2 * M - (n - 1) * gap) / n)
    local row = HorizontalGroup:new { Theme.hspan(M) }
    for i, spec in ipairs(self.buttons) do
      if i > 1 then row[#row + 1] = Theme.hspan(gap) end
      row[#row + 1] = Button.new { label = spec.label, w = w, h = Theme.BUTTON_H, callback = spec.callback }
    end
    actions = VerticalGroup:new { align = "left", Theme.span("m"), row, Theme.span("m") }
    room = room - actions:getSize().h
  end

  local function content(width)
    local group = VerticalGroup:new { align = "left" }
    group[#group + 1] = Theme.span("m")
    if self.heading then group[#group + 1] = Theme.sectionHeader(self.heading, width) end
    group[#group + 1] = Theme.span("m")
    group[#group + 1] = TextBoxWidget:new {
      text = self.text, face = Theme.face("body"), width = width, alignment = "left",
      line_height = 0.35,
    }
    group[#group + 1] = Theme.span("xl")
    return group
  end

  local width = screen_w - 2 * M
  local group = content(width)
  local body
  self.scroll = nil
  if group:getSize().h > room then
    width = screen_w - 2 * M - ScrollControl.gutter()
    group = content(width)
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room }, show_parent = self,
    }
    self.scroll[1] = HorizontalGroup:new { Theme.hspan(M), group }
    body = ScrollControl.wrap(self.scroll, group)
  else
    body = HorizontalGroup:new { Theme.hspan(M), group }
    -- a short text leaves the buttons at the bottom all the same
    if actions then body = VerticalGroup:new { align = "left", body, Theme.span(room - group:getSize().h) } end
  end

  self[1] = FrameContainer:new {
    width = screen_w, height = screen_h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", bar, body, actions },
  }
end

function TextScreen:onShow()
  UIManager:setDirty(self, "ui")
end

function TextScreen:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

function TextScreen:onCloseText()
  return self:onClose()
end

function TextScreen:onClose()
  UIManager:close(self)
  if self.close_callback then self.close_callback() end
  return true
end

return TextScreen
