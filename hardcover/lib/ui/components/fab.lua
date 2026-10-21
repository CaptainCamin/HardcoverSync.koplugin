-- Floating action button (MMD): a rounded square that holds one icon, for the one primary action of
-- a screen that has no room for a button in its flow. 72 / 64 / 48 square (large / medium / small),
-- a 2 border, the icon about 40% of the side, and a white halo around it so it stays legible where it
-- sits over content. Outlined, never filled or grey: an unavailable one is a dotted square with no tap.
--
-- The rules: at most 3 on a screen, one size within a context, anchored to an edge, and the body it
-- floats over must leave it room (a scrolling list reserves a footer the FAB's height, so it never
-- covers a row). An icon alone is ambiguous, so use a familiar one (plus) and put the action's name in
-- a label next to the screen's title or in the snackbar that follows the tap.
--
-- The whole box, halo included, is the touch area; the smallest is 52, over TOUCH_MIN.

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")

local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Fab = {}

Fab.SCALES = { "small", "medium", "large" }

-- opts { icon (a Theme.icon name, e.g. "plus"), scale ("small" | "medium" | "large", default large),
--        enabled (false: a dotted square, no tap), callback, viewport }
function Fab.new(opts)
  local m = Theme.mmd.fab
  local scale = opts.scale or "large"
  local size = m.size[scale]
  local off = opts.enabled == false
  local icon = Theme.icon(opts.icon, m.icon[scale])
  local box = Theme.box(size, size, icon, { border = m.border, radius = m.radius[scale], dotted = off })
  local halo = m.halo[scale]
  local halod = FrameContainer:new {
    bordersize = 0, padding = halo, margin = 0, background = Blitbuffer.COLOR_WHITE, box,
  }
  -- the size rides on the result, where a screen's layout and its tests look for it
  return TapRow:new { callback = (not off) and opts.callback or nil, viewport = opts.viewport,
    width = size + 2 * halo, halod }
end

-- Where a FAB of `fab_w` x `fab_h` goes in an area `w` x `h`: the bottom corner on `edge` ("right",
-- default, or "left"), `Theme.mmd.fab.margin` in from both sides. Returns x, y in the area.
function Fab.position(w, h, fab_w, fab_h, edge)
  local margin = Theme.mmd.fab.margin
  local x = (edge == "left") and margin or (w - fab_w - margin)
  return x, h - fab_h - margin
end

-- How much of the bottom of a scrolling body to keep clear so a FAB of this scale never covers a row.
function Fab.reserve(scale)
  local m = Theme.mmd.fab
  scale = scale or "large"
  return m.size[scale] + 2 * m.halo[scale] + 2 * m.margin
end

return Fab
