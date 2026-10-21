-- What every overlay component (popover, choice sheet, action sheet, dialog, snackbar) stands on: a
-- full-screen holder that paints one child at a place and nothing else, so the page behind is not
-- dimmed or covered, and only the child's box is refreshed. Static: no sliding in, no fade.
--
--   anchor  "bottom"   the child's bottom edge on the screen's bottom edge, centred
--           "center"   centred on the screen
--           "point"    the child's top-right corner at (x, y): a popover under its icon
--   modal   a tap outside the child dismisses it and goes no further (default); false leaves it
--           to the child's own taps only
--   toast   the page stays usable: KOReader sends every event to the toast first and then on to the
--           window below, whatever the toast does with it. A gesture that lands on the child is taken
--           here (marked spent, so the window below ignores it); anywhere else it passes untouched,
--           and neither a tap outside nor Back dismisses it. Keep `modal` true with it: KOReader
--           also reads that flag to stack a window, and a non-modal toast lands under an open sheet.
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
  toast = false,
  snackbar = false, -- set by Snackbar.show, so a caller can tell the notice from the window under it
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

-- What a toast's own gesture handling leaves: UIManager hands the same gesture table to the window
-- below even after the toast took it, so a tap on "Undo" would also press whatever is under the bar.
-- Renaming the gesture makes every GestureRange below miss it.
local SPENT = "hardcover_spent"

function Overlay:handleEvent(event)
  local handled = InputContainer.handleEvent(self, event)
  if self.toast and event.handler == "onGesture" then
    local ges = event.args and event.args[1]
    if ges and ges.pos and ges.pos:intersectWith(self.region) then
      ges.ges = SPENT
      return true
    end
  end
  return handled
end

function Overlay:onTapOutsideOverlay(_, ges)
  if ges and ges.pos and ges.pos:intersectWith(self.region) then return true end -- on the child, not a row
  if self.toast or not self.modal then return false end
  self:dismiss()
  return true
end

function Overlay:onBack()
  if self.toast or not self.modal then return false end
  self:dismiss()
  return true
end

function Overlay:dismiss()
  self:close()
  if self.on_dismiss then self.on_dismiss() end
end

-- The region a refresh covers. A refresh of exactly the box lost the right edge of a dialog on a real
-- panel (the border was missing the moment it opened, and came back with a full redraw), so a dialog
-- or sheet refreshes the whole width of the screen across its height, plus a few pixels above and
-- below; the page behind is repainted there unchanged. A toast keeps its exact box.
local PAD = 8
function Overlay:refreshRegion()
  local sw, sh = Screen:getWidth(), Screen:getHeight()
  local r = self.region
  if self.toast then return r end
  local y = math.max(0, r.y - PAD)
  return Geom:new { x = 0, y = y, w = sw, h = math.min(sh, r.y + r.h + PAD) - y }
end

function Overlay:show()
  UIManager:show(self, "ui", self:refreshRegion())
  return self
end

-- `replaced_by` (an overlay already shown over this one, same box): close without a refresh, since the
-- new one is refreshed over the same area. Closing the old one first and showing the new one is two
-- refreshes of the same box, which is the flicker and ghost of a dialog that redraws as it changes.
-- Whoever closes an overlay (this class's close, or UIManager:close(overlay) as the plugin's pickers
-- and sheets are closed in many places) gets the box's area refreshed, as KOReader's own widgets do
-- in onCloseWidget; without it the sheet stayed on the panel after it was gone, until something
-- else redrew that area.
function Overlay:onCloseWidget()
  if self.quiet_close then return end
  UIManager:setDirty(nil, function() return "ui", self:refreshRegion() end)
end

function Overlay:close(replaced_by)
  if self.closed then return end
  self.closed = true
  if self.timeout_task then UIManager:unschedule(self.timeout_task) end
  if replaced_by and replaced_by.region and replaced_by.region:equalSize(self.region)
    and replaced_by.region.x == self.region.x and replaced_by.region.y == self.region.y then
    self.quiet_close = true
    UIManager:close(self)
    return
  end
  UIManager:close(self)
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
