-- A tappable wrapper for any widget: a cover with its labels, a card.
--
-- Button only takes text or an icon, so anything laid out freely needs this. It
-- follows Button's pattern: the tap range is the widget's own rectangle, which
-- KOReader fills in when the widget is painted.
--
-- Given `viewport` (a function returning the visible rectangle of the scroll
-- area it sits in), taps outside that rectangle are ignored; see viewport.lua
-- for why that matters.
--
-- Touch feedback: a tap inverts `feedback` for a moment before the callback runs,
-- so the press is seen, as KOReader's own buttons do. `feedback` says what inverts,
-- relative to the row:
--   true             the whole row (a button, a line of text)
--   { x, y, w, h }   a rectangle inside the row. A row that shows a cover gives only
--                    its label: a cover is never inverted
--   nil              nothing (the default: a row that does not ask is not flashed)
-- KOReader's own "flash_ui" setting turns it off here too, as it does for its buttons.

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")

local Viewport = require("hardcover/lib/ui/viewport")

local TapRow = InputContainer:extend {
  name = "hardcover_tap_row",
  callback = nil,
  -- optional: a long press does this (Sync's "discard what is queued")
  hold_callback = nil,
  viewport = nil,
  -- optional: what inverts on a tap (see above)
  feedback = nil,
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
  if self.hold_callback then
    self.ges_events.HoldSelectRow = {
      GestureRange:new {
        ges = "hold",
        range = range,
      },
    }
  end
end

function TapRow:onHoldSelectRow()
  if self.hold_callback then
    self.hold_callback()
  end
  return true
end

-- The rectangle `feedback` names, on the screen and cut to the visible part of the
-- scroll area (nil when none of it is showing). Read after the row is painted, when
-- its position is known.
function TapRow:feedbackRect()
  local f = self.feedback
  if not f or not self.dimen then return nil end
  local r
  if f == true then
    r = { x = self.dimen.x, y = self.dimen.y, w = self.dimen.w, h = self.dimen.h }
  else
    r = { x = self.dimen.x + f.x, y = self.dimen.y + f.y, w = f.w, h = f.h }
  end
  if self.viewport then
    r = Viewport.intersect(r, self.viewport())
  end
  return r
end

-- Invert the rectangle, draw it now, and put it back, the way KOReader's buttons do.
-- forceRePaint sends the highlight before the callback runs, and inverting the same
-- pixels twice is exact, so nothing is repainted: only the rectangle is refreshed.
local function flash(widget, r)
  local UIManager = require("ui/uimanager")
  -- a harness's stand-in UIManager may not have the panel calls: then there is no flash
  if not (UIManager.widgetInvert and UIManager.forceRePaint and UIManager.yieldToEPDC) then
    return
  end
  local rect = Geom:new { x = r.x, y = r.y, w = r.w, h = r.h }
  UIManager:widgetInvert(widget, r.x, r.y, r.w, r.h)
  UIManager:setDirty(nil, "fast", rect)
  UIManager:forceRePaint()
  UIManager:yieldToEPDC()
  UIManager:widgetInvert(widget, r.x, r.y, r.w, r.h)
  UIManager:setDirty(nil, "fast", rect)
end

function TapRow:onTapSelectRow()
  if self.callback then
    local r = self:feedbackRect()
    local flash_on = not (G_reader_settings and G_reader_settings:isFalse("flash_ui"))
    if r and flash_on then
      flash(self, r)
    end
    self.callback()
  end
  return true
end

return TapRow
