-- "All details": every row of a book's metadata (publisher, edition, language, ISBN, pages,
-- credits...) as fixed-height list rows with dotted dividers, scrolled by page when there are more
-- than fit. The book's own screen shows the first five.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local ListItem = require("hardcover/lib/ui/components/list_item")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

local DetailsScreen = InputContainer:extend {
  name = "hardcover_details_screen",
  title = nil,
  rows = nil, -- { { label, value } }
}

function DetailsScreen:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  self.dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h }
  self.key_events.CloseDetails = { { "Back" } }

  local bar = TopBar.new { width = screen_w, title = self.title, on_back = function() self:onClose() end }
  local room = screen_h - bar:getSize().h

  local function content(width)
    local group = VerticalGroup:new { align = "left" }
    for i, row in ipairs(self.rows) do
      group[#group + 1] = ListItem.new {
        width = width, label = row.label, support = tostring(row.value), strong = true,
        divider = i < #self.rows and "dotted" or nil,
      }
    end
    return group
  end

  local group = content(screen_w)
  local body = group
  self.scroll = nil
  if group:getSize().h > room then
    group = content(screen_w - ScrollControl.gutter())
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room }, show_parent = self,
    }
    self.scroll[1] = group
    body = ScrollControl.wrap(self.scroll, group)
  end

  self[1] = FrameContainer:new {
    width = screen_w, height = screen_h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", bar, body },
  }
end

function DetailsScreen:onShow()
  UIManager:setDirty(self, "ui")
end

function DetailsScreen:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

function DetailsScreen:onCloseDetails()
  return self:onClose()
end

function DetailsScreen:onClose()
  UIManager:close(self)
  return true
end

return DetailsScreen
