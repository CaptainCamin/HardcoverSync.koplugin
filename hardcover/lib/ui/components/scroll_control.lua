-- Scroll control: the one way a long screen scrolls.
--
-- Mudita Mindful Design (appendix, "Scroll"): a slim black bar over a hollow double-line track at the
-- right edge, with a bare triangle at each end. A triangle is solid while the content can move that way
-- and dotted once that end is reached. Every control is visible, so a tap on a triangle steps a page
-- (swipe stays as a shortcut). No boxed arrow buttons, no page counter.
--
-- It wraps a ScrollableContainer rather than replacing it, so swipes, pan and the page keys keep working
-- and every screen's tap ranges (viewport.lua) stay as they are. Pages land on row edges: pass the
-- VerticalGroup whose children are the rows and the container steps to them instead of cutting a row in
-- half. The container's own thin bar is switched off; its gutter (3 bar widths at the right) is where
-- the control lives, so nothing is ever drawn over text.
--
-- State is read from the container's scroll offset each time it paints, never stored here, so the
-- triangles cannot drift from what is on screen.
--
-- Usage, where the screen builds its ScrollableContainer today:
--   scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
--   body = ScrollControl.wrap(scroll, content)
-- and size the content `ScrollControl.gutter()` narrower than the screen less its margins.

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local BLACK = Theme.BLACK
local px = Theme.px

local TRI_W, TRI_H = px(16), px(11)
local TRACK_W = px(14)
local BAR_W = px(4)
local MIN_BAR_H = px(28)

local ScrollControl = InputContainer:extend {
  name = "hardcover_scroll_control",
  scroll = nil, -- the ScrollableContainer this controls
  width = 0,
  height = 0,
}

-- The column the control occupies at the right edge: what the container already keeps free for its own
-- bar, so content built `gutter()` narrower never sits under it.
function ScrollControl.gutter()
  return 3 * (ScrollableContainer.scroll_bar_width or Screen:scaleBySize(6))
end

-- Row edges for the container's page steps: one { top, bottom } per child of `group`, in content
-- coordinates. Nil when `group` has no children to step by (free scrolling then).
function ScrollControl.grid(group)
  if type(group) ~= "table" or #group == 0 then return nil end
  local rows, y = {}, 0
  for i = 1, #group do
    local h = group[i]:getSize().h
    rows[#rows + 1] = { top = y, bottom = y + h - 1 }
    y = y + h
  end
  return rows
end

-- A triangle `w` x `h` centred on `cx` pointing `dir`. Solid when `active`, dotted (every other pixel)
-- when not, so the state shows without grey.
local function triangle(bb, cx, y, w, h, dir, active)
  for i = 0, h - 1 do
    local frac = (dir == "up") and (i / (h - 1)) or (1 - i / (h - 1))
    local half = math.max(0, math.floor((w / 2) * frac + 0.5))
    local ry = y + i
    if active then
      bb:paintRect(cx - half, ry, 2 * half + 1, 1, BLACK)
    else
      for xx = cx - half, cx + half do
        if (xx + ry) % 2 == 0 then bb:paintRect(xx, ry, 1, 1, BLACK) end
      end
    end
  end
end

-- How far the container is scrolled, how far it can go, and how tall its viewport is; nil when it has
-- nothing to scroll (then the control draws nothing).
function ScrollControl:metrics()
  local s = self.scroll
  if not (s and s._is_scrollable and s._max_scroll_offset_y and s._max_scroll_offset_y > 0) then
    return nil
  end
  return s._scroll_offset_y or 0, s._max_scroll_offset_y, s._crop_h or self.height
end

function ScrollControl:init()
  self.dimen = Geom:new { x = 0, y = 0, w = self.width, h = self.height }
  self.ges_events = {
    TapScrollControl = { GestureRange:new { ges = "tap", range = function() return self.dimen end } },
  }
end

function ScrollControl:getSize()
  return self.dimen
end

function ScrollControl:paintTo(bb, x, y)
  self.dimen.x, self.dimen.y = x, y
  local offset, max, view_h = self:metrics()
  if not offset then return end

  local w, h = self.dimen.w, self.dimen.h
  local touch = Theme.TOUCH_MIN
  local cx = x + math.floor(w / 2)
  triangle(bb, cx, y + math.floor((touch - TRI_H) / 2), TRI_W, TRI_H, "up", offset > 0)
  triangle(bb, cx, y + h - math.floor((touch + TRI_H) / 2), TRI_W, TRI_H, "down", offset < max)

  -- the hollow double-line track between the triangles
  local ty, th = y + touch, h - 2 * touch
  local lx = cx - math.floor(TRACK_W / 2)
  bb:paintRect(lx, ty, Theme.line.hair, th, BLACK)
  bb:paintRect(lx + TRACK_W - Theme.line.hair, ty, Theme.line.hair, th, BLACK)

  -- the slim bar: its length is the share of the content in view, its place is the offset
  local content_h = max + view_h
  local bar_h = math.max(MIN_BAR_H, math.floor(th * view_h / content_h))
  local clamped = math.max(0, math.min(max, offset))
  local by = ty + math.floor((th - bar_h) * clamped / max)
  bb:paintRoundedRect(cx - math.floor(BAR_W / 2), by, BAR_W, bar_h, BLACK, math.floor(BAR_W / 2))
end

-- A tap on the top touch area steps a page up, on the bottom one a page down; anywhere else on the
-- column does nothing. A tap on a dotted triangle is swallowed too, so it cannot reach something under.
function ScrollControl:onTapScrollControl(_, ges)
  if not (self:metrics() and ges and ges.pos) then return false end
  local touch = Theme.TOUCH_MIN
  local dy = ges.pos.y - self.dimen.y
  if dy < touch then
    self.scroll:onScrollPageUp()
  elseif dy >= self.dimen.h - touch then
    self.scroll:onScrollPageDown()
  end
  return true
end

-- Put the control on `scroll` and return the widget to show in its place. `rows` (optional) is the
-- VerticalGroup the content is made of, so pages land on row edges. Call after `scroll[1]` is set.
function ScrollControl.wrap(scroll, rows)
  local total_w, total_h = scroll.dimen.w, scroll.dimen.h
  local gutter = ScrollControl.gutter()

  -- The container makes its thin bar whenever it works out its state (on first paint, or again after
  -- a reset); drop it each time so only the control is drawn.
  local init_state = scroll.initState
  if type(init_state) ~= "function" then return scroll end -- not a real container (a spec stand-in)
  scroll.initState = function(self)
    init_state(self)
    self._v_scroll_bar = nil
  end
  -- Work out the container's state first, then give it the row grid: with a grid in place initState
  -- snaps to a row, which queues a refresh of the whole scroll area, and a screen redrawn in place
  -- (an option ticked) must not cost that.
  scroll:initState()
  if rows then scroll.step_scroll_grid = ScrollControl.grid(rows) end

  local control = ScrollControl:new { scroll = scroll, width = gutter, height = total_h }
  control.overlap_offset = { total_w - gutter, 0 }
  return OverlapGroup:new {
    dimen = Geom:new { w = total_w, h = total_h },
    allow_mirroring = false,
    scroll,
    control,
  }
end

return ScrollControl
