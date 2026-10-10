-- Progress bar (mock 7): a thin outlined track with a thick black fill, rounded at both ends. Not
-- KOReader's ProgressWidget (a mid-grey fill that washes out on the panel). An optional tick marks
-- where you should be today; it has a white edge so it stays visible over the fill.

local Blitbuffer = require("ffi/blitbuffer")

local Draw = require("hardcover/lib/ui/components/draw")
local Theme = require("hardcover/lib/ui/theme")

local px = Theme.px
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local ProgressBar = {}

ProgressBar.height = px(14)
local FILL_H, FILL_Y = px(10), px(2)
local TRACK_H, TRACK_Y = px(6), px(4)

-- opts { width, fraction (0 to 1), tick (0 to 1, optional) }
function ProgressBar.new(opts)
  local w = opts.width
  local fraction = math.max(0, math.min(1, opts.fraction or 0))
  return Draw.drawn(w, ProgressBar.height, function(bb, x, y)
    local edge = Theme.line.hair
    -- the track: a black outline, white inside
    bb:paintRoundedRect(x, y + TRACK_Y, w, TRACK_H, BLACK, math.floor(TRACK_H / 2))
    bb:paintRoundedRect(x + edge, y + TRACK_Y + edge, w - 2 * edge, TRACK_H - 2 * edge, WHITE,
      math.max(0, math.floor(TRACK_H / 2) - edge))
    -- the fill, at least a dot wide so a start is visible
    if fraction > 0 then
      local fw = math.max(FILL_H, math.floor(w * fraction + 0.5))
      bb:paintRoundedRect(x, y + FILL_Y, fw, FILL_H, BLACK, math.floor(FILL_H / 2))
    end
    if opts.tick then
      local t = Theme.line.firm
      local tx = x + math.max(0, math.min(w - t, math.floor(w * opts.tick + 0.5) - math.floor(t / 2)))
      bb:paintRect(tx - edge, y, t + 2 * edge, ProgressBar.height, WHITE)
      bb:paintRect(tx, y, t, ProgressBar.height, BLACK)
    end
  end)
end

return ProgressBar
