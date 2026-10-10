-- Radio (MMD): a circle 26 with a 2px stroke; selected adds a 14 dot. Touch area 48 belongs to the
-- row that hosts it.

local Blitbuffer = require("ffi/blitbuffer")

local Draw = require("hardcover/lib/ui/components/draw")
local Theme = require("hardcover/lib/ui/theme")

local BLACK = Blitbuffer.COLOR_BLACK

local Radio = {}

-- opts { selected }
function Radio.new(opts)
  opts = opts or {}
  local m = Theme.mmd.radio
  local d = m.size
  return Draw.drawn(d, d, function(bb, x, y)
    local cx, cy = x + math.floor(d / 2), y + math.floor(d / 2)
    bb:paintCircle(cx, cy, math.floor(d / 2), BLACK, Theme.line.firm)
    if opts.selected then bb:paintCircle(cx, cy, math.floor(m.dot / 2), BLACK) end
  end)
end

return Radio
