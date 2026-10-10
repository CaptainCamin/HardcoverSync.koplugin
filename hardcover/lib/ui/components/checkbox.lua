-- Checkbox (MMD): a square 28 with a 2px outline; checked = filled black with a white tick.
-- Touch area 48 belongs to the row that hosts it.

local Blitbuffer = require("ffi/blitbuffer")

local Draw = require("hardcover/lib/ui/components/draw")
local Theme = require("hardcover/lib/ui/theme")

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local Checkbox = {}

-- opts { checked }
function Checkbox.new(opts)
  opts = opts or {}
  local s = Theme.mmd.checkbox.size
  local t = Theme.line.firm
  local r = Theme.px(4)
  return Draw.drawn(s, s, function(bb, x, y)
    bb:paintRoundedRect(x, y, s, s, BLACK, r)
    if opts.checked then
      Draw.paintCheck(bb, x + t, y + t, s - 2 * t, t + 1, WHITE)
    else
      bb:paintRoundedRect(x + t, y + t, s - 2 * t, s - 2 * t, WHITE, math.max(0, r - t))
    end
  end)
end

return Checkbox
