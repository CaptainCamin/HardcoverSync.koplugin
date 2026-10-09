-- A hatched layer: the page behind a popup is pushed back (see Theme.hatchRect).
--
-- It is a widget of its own in the window stack, just under whatever it hatches over.
-- Hatching adds up when it is painted twice over the same pixels, so the layer must be
-- painted only when what is under it has just been painted: UIManager repaints a widget
-- when it, or anything under it, is dirty. Nothing marks a Backdrop dirty by itself, so
-- it is painted exactly when the page under it is, and drawn once over those fresh
-- pixels. When something above it closes, everything under is repainted without
-- hatching and the layer hatches again: the hatching survives whatever happens above.
--
--   Backdrop:new { top = 0, bottom = h }   hatch the rows from `top` down to `bottom`
--                                          (numbers or functions; the whole screen by default)
--   Backdrop.show(popup)                   show `popup` over a hatched layer; the layer closes
--                                          with the popup, in the same tick
--
-- A widget that has already hatched the top of the screen (the reader panel hatches the
-- page above its sheet) says so with `hatched_to`, the first row not hatched yet: a popup
-- opened over it hatches from there down, so the page is not hatched twice.

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")

local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local Backdrop = Widget:extend {
  name = "hardcover_backdrop",
  top = nil,
  bottom = nil,
}

function Backdrop:init()
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

local function value(v, default)
  if type(v) == "function" then v = v() end
  return v or default
end

-- the rows hatched: from `top` to `bottom`
function Backdrop:rows()
  local h = Screen:getHeight()
  local top = math.max(0, value(self.top, 0))
  local bottom = math.min(h, value(self.bottom, h))
  return top, math.max(top, bottom)
end

function Backdrop:paintTo(bb, x, y)
  local top, bottom = self:rows()
  Theme.hatchRect(bb, x, y + top, self.dimen.w, bottom - top)
end

-- Leaving the layer shows what was under it again, which was repainted without
-- hatching: refresh the screen once, not a part of it per widget that closed. The
-- same on opening (see Backdrop.show), so the popup and its layer arrive in one
-- non-flashing refresh.
function Backdrop:onCloseWidget()
  UIManager:setDirty(nil, "ui", self.dimen:copy())
end

-- the widget directly under this layer in the window stack
function Backdrop:widgetUnder()
  local stack = UIManager._window_stack
  for i = #stack, 2, -1 do
    if stack[i].widget == self then return stack[i - 1].widget end
  end
end

function Backdrop.show(popup)
  -- what is under the layer is looked up when it is painted, not now: the popup may be
  -- shown while something else (a Wi-Fi question) is still on top, and goes away after
  local layer
  layer = Backdrop:new {
    top = function()
      local under = layer:widgetUnder()
      return under and under.hatched_to or 0
    end,
  }
  UIManager:show(layer, "ui", layer.dimen:copy())
  UIManager:show(popup)
  -- the layer goes when the popup does: chained onto its own handler, because a popup
  -- closes itself (UIManager:close) and nothing tells the layer
  local on_close = popup.onCloseWidget
  popup.onCloseWidget = function(this, ...)
    if UIManager:isWidgetShown(layer) then UIManager:close(layer) end
    if on_close then return on_close(this, ...) end
  end
  return popup
end

return Backdrop
