-- Tap ranges for widgets inside a ScrollableContainer.
--
-- ScrollableContainer paints its content in screen coordinates shifted by the
-- scroll offset, so a tappable widget scrolled out of view keeps a tap range at
-- the shifted position -- which can be directly over something else, such as the
-- Close button under the scroll area. Widgets earlier in the event order win, so
-- an off-screen cover could take a tap meant for Close.
--
-- A gesture range may be a function (GestureRange:match calls it when matching),
-- so each tappable widget in the scroll area is given one that returns its own
-- rectangle cut down to what the container is actually showing.

local Geom = require("ui/geometry")

local Viewport = {}

--
-- The overlap of two rectangles ({x, y, w, h}), or nil when they do not overlap
-- or either is not positioned yet (positions are set when a widget is painted).
--
function Viewport.intersect(a, b)
  if not (a and b and a.x and a.y and b.x and b.y and a.w and a.h and b.w and b.h) then
    return nil
  end

  local x1, y1 = math.max(a.x, b.x), math.max(a.y, b.y)
  local x2, y2 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
  if x2 <= x1 or y2 <= y1 then
    return nil
  end

  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

--
-- A range function for GestureRange: the widget's rectangle, cut to the
-- viewport's. Both are fetched when a tap arrives, never when this is built,
-- because neither has a position until it has been painted.
--
function Viewport.range(get_dimen, get_viewport)
  return function()
    local overlap = Viewport.intersect(get_dimen(), get_viewport())
    if not overlap then return nil end
    return Geom:new(overlap)
  end
end

--
-- Restrict a Button's tap to the viewport. The button builds its own gesture
-- events when it is created; this swaps the range on the tap one.
--
function Viewport.limitButton(button, get_viewport)
  local tap = button.ges_events and button.ges_events.TapSelectButton
  local gesture = tap and tap[1]
  if gesture then
    gesture.range = Viewport.range(function() return button.dimen end, get_viewport)
  end
  return button
end

return Viewport
