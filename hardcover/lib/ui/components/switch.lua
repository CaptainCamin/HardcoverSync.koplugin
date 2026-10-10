-- Switch (MMD): a track 48 x 30 with a 20 knob. On = black track and a white knob at the right; off =
-- an outlined track and a black knob at the left. `unavailable` draws the knob hollow (a ring), so
-- that state shows without grey and without a broken-looking outline. The touch area (56) belongs to the
-- row that hosts it (see list_item), not to the switch.

local Blitbuffer = require("ffi/blitbuffer")

local Draw = require("hardcover/lib/ui/components/draw")
local Theme = require("hardcover/lib/ui/theme")

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local Switch = {}

-- opts { on, unavailable }
function Switch.new(opts)
  opts = opts or {}
  local m = Theme.mmd.switch
  local w, h, d = m.w, m.h, m.knob
  local t = Theme.line.firm
  local half = math.floor(h / 2)
  return Draw.drawn(w, h, function(bb, x, y)
    local cy = y + half
    if opts.on then
      bb:paintRoundedRect(x, y, w, h, BLACK, half)
      bb:paintCircle(x + w - half, cy, math.floor(d / 2), WHITE)
      return
    end
    bb:paintRoundedRect(x, y, w, h, BLACK, half)
    bb:paintRoundedRect(x + t, y + t, w - 2 * t, h - 2 * t, WHITE, math.floor((h - 2 * t) / 2))
    bb:paintCircle(x + half, cy, math.floor(d / 2), BLACK)
    if opts.unavailable then bb:paintCircle(x + half, cy, math.floor(d / 2) - t, WHITE) end
  end)
end

return Switch
