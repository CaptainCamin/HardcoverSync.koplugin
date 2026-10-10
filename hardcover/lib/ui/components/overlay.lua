-- What every overlay component (popover, choice sheet, action sheet, dialog, snackbar) stands on: a
-- full-screen holder that paints one child at a place and nothing else, so the page behind is not
-- dimmed or covered, and only the child's box is refreshed. Static: no sliding in, no fade.
--
--   anchor  "bottom"   the child's bottom edge on the screen's bottom edge, centred
--           "center"   centred on the screen
--           "point"    the child's top-right corner at (x, y): a popover under its icon
--   modal   a tap outside the child dismisses it and goes no further (default); false leaves it
--           to the child's own taps only
--
-- The child's own taps are tried first (its rows are TapRows); what no child takes is handled here.

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local Overlay = InputContainer:extend {
  name = "hardcover_overlay",
  anchor = "bottom",
  modal = true,
  x = 0,
  y = 0,
  on_dismiss = nil, -- tap outside, or Back
  covers_fullscreen = false,
}

function Overlay:init()
  local sw, sh = Screen:getWidth(), Screen:getHeight()
  local child = self[1]
  local size = child:getSize()
  local x, y
  if self.anchor == "bottom" then
    x, y = math.floor((sw - size.w) / 2), sh - size.h
  elseif self.anchor == "center" then
    x, y = math.floor((sw - size.w) / 2), math.floor((sh - size.h) / 2)
  else
    x, y = self.x - size.w, self.y
  end
  self.region = Geom:new { x = x, y = y, w = size.w, h = size.h }
  self.dimen = Geom:new { x = 0, y = 0, w = sw, h = sh }
  if Device:isTouchDevice() then
    self.ges_events = {
      TapOutsideOverlay = { GestureRange:new { ges = "tap", range = Geom:new { x = 0, y = 0, w = sw, h = sh } } },
    }
  end
  if Device:hasKeys() then
    self.key_events = { Back = { { Device.input.group.Back } } }
  end
end

function Overlay:paintTo(bb)
  self[1]:paintTo(bb, self.region.x, self.region.y)
end

function Overlay:onTapOutsideOverlay(_, ges)
  if ges and ges.pos and ges.pos:intersectWith(self.region) then return true end -- on the child, not a row
  if not self.modal then return false end
  self:dismiss()
  return true
end

function Overlay:onBack()
  if not self.modal then return false end
  self:dismiss()
  return true
end

function Overlay:dismiss()
  self:close()
  if self.on_dismiss then self.on_dismiss() end
end

function Overlay:show()
  UIManager:show(self, "ui", self.region)
  return self
end

function Overlay:close()
  if self.closed then return end
  self.closed = true
  if self.timeout_task then UIManager:unschedule(self.timeout_task) end
  UIManager:close(self, "ui", self.region)
end

-- The mark on top of anything laid over a page: a 2 white band (so the black does not run into the
-- page behind) and a 3 black rule. Open gate: whether the band belongs above or below the rule.
function Overlay.top_rule(width)
  local rule, gap = Theme.mmd.rule.overlay, Theme.mmd.rule.gap
  return VerticalGroup:new { align = "left",
    Draw.drawn(width, gap, function(bb, x, y, w, h) bb:paintRect(x, y, w, h, Theme.WHITE) end),
    Draw.drawn(width, rule, function(bb, x, y, w, h) bb:paintRect(x, y, w, h, Theme.BLACK) end),
  }
end

return Overlay
