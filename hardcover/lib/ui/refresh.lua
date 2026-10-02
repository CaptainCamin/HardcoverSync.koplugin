-- Refresh part of the panel, not all of it.
--
-- UIManager:setDirty(widget, "ui") with no region refreshes the WHOLE screen,
-- whatever changed: a cover arriving in a 135-pixel box costs the same panel
-- time as redrawing the page. Every screen here is full-screen, so a bare
-- setDirty(self, "ui") is a full-panel refresh every time. Passing the region
-- that changed keeps the repaint (a CPU cost, cheap next to the panel) but limits
-- what the panel is asked to redraw.
--
-- A widget only knows where it is once it has been painted, so the region is
-- given as a function that UIManager calls after the paint (setDirty accepts
-- one). If a position is not known yet, the whole panel is refreshed: never
-- less than is needed.
--
-- Rectangles are plain {x, y, w, h}; nothing here needs KOReader until a
-- refresh is queued, so the geometry is testable under stock Lua.

local Viewport = require("hardcover/lib/ui/viewport")

local Refresh = {}

-- a rectangle with a position and a size (positions are set when a widget is painted)
function Refresh.valid(r)
  return type(r) == "table" and type(r.x) == "number" and type(r.y) == "number"
    and type(r.w) == "number" and type(r.h) == "number" and r.w > 0 and r.h > 0
end

-- the smallest rectangle holding both; either may be nil
function Refresh.union(a, b)
  if not Refresh.valid(a) then return Refresh.valid(b) and { x = b.x, y = b.y, w = b.w, h = b.h } or nil end
  if not Refresh.valid(b) then return { x = a.x, y = a.y, w = a.w, h = a.h } end
  local x1, y1 = math.min(a.x, b.x), math.min(a.y, b.y)
  local x2, y2 = math.max(a.x + a.w, b.x + b.w), math.max(a.y + a.h, b.y + b.h)
  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

local function screen_rect()
  local Screen = require("device").screen
  return { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

-- A copy of a rectangle that stays valid after the widget it came from moves
-- (dimen tables are updated in place on every paint).
function Refresh.copy(r)
  if not Refresh.valid(r) then return nil end
  return { x = r.x, y = r.y, w = r.w, h = r.h }
end

--
-- Repaint `window` and refresh the rectangle `get_rect()` returns, read after the
-- paint. A rectangle that is not known (nil, or never painted) means the whole
-- panel. `mode` defaults to "ui".
--
function Refresh.region(window, get_rect, mode)
  local UIManager = require("ui/uimanager")
  UIManager:setDirty(window, function()
    local r = get_rect and get_rect()
    if not Refresh.valid(r) then
      return mode or "ui"
    end
    local Geom = require("ui/geometry")
    return mode or "ui", Geom:new { x = r.x, y = r.y, w = r.w, h = r.h }
  end)
end

--
-- Repaint `window` and refresh just one widget's box (`get_dimen` returns its
-- dimen, read after the paint), cut to `get_clip()` (the visible part of a scroll
-- area; the screen when omitted). A box that is not on screen needs nothing
-- redrawn now, so nothing is queued: the picture is drawn when it scrolls into
-- view.
--
function Refresh.box(window, get_dimen, get_clip, mode)
  local before = get_dimen and get_dimen()
  local clip = get_clip and get_clip() or screen_rect()
  if Refresh.valid(before) and Refresh.valid(clip) and not Viewport.intersect(before, clip) then
    return false
  end
  Refresh.region(window, function()
    local d = get_dimen and get_dimen()
    local c = get_clip and get_clip() or screen_rect()
    if not Refresh.valid(d) then return nil end
    -- scrolled out of view by the time it painted: refresh the visible area (a
    -- queued repaint with no refresh would fall back to a full-panel one)
    return Viewport.intersect(d, c) or Refresh.copy(c)
  end, mode)
  return true
end

return Refresh
