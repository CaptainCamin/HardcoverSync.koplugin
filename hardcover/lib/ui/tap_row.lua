-- A tappable wrapper for any widget: a cover with its labels, a card.
--
-- Button only takes text or an icon, so anything laid out freely needs this. It
-- follows Button's pattern: the tap range is the widget's own rectangle, which
-- KOReader fills in when the widget is painted.
--
-- Given `viewport` (a function returning the visible rectangle of the scroll
-- area it sits in), taps outside that rectangle are ignored; see viewport.lua
-- for why that matters.

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")

local Viewport = require("hardcover/lib/ui/viewport")

local TapRow = InputContainer:extend {
  name = "hardcover_tap_row",
  callback = nil,
  viewport = nil,
}

function TapRow:init()
  -- not every widget's getSize returns a Geom (a HorizontalGroup's is a plain
  -- table), and a gesture range must be one
  local size = self[1]:getSize()
  self.dimen = Geom:new { x = 0, y = 0, w = size.w, h = size.h }

  local range = function() return self.dimen end
  if self.viewport then
    range = Viewport.range(function() return self.dimen end, self.viewport)
  end

  self.ges_events = {
    TapSelectRow = {
      GestureRange:new {
        ges = "tap",
        range = range,
      },
    },
  }
end

function TapRow:onTapSelectRow()
  if self.callback then
    self.callback()
  end
  return true
end

return TapRow
