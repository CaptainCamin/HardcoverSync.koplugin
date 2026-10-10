-- Button (MMD): rectangular (radius 8), 2px border, Black label. `primary` is filled black with a
-- white label (one per screen); the rest are outlined. The whole box is the touch area, so keep
-- `h` at 48 or more.

local Blitbuffer = require("ffi/blitbuffer")

local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local Button = {}

Button.HEIGHT = Theme.px(64) -- dialog and sheet action buttons

-- opts { label, w, h (default HEIGHT), primary, callback, viewport }
function Button.new(opts)
  local w, h = opts.w, opts.h or Button.HEIGHT
  local t = Theme.mmd.button.border
  local label = Theme.mmdText(opts.label, "strong", 21,
    { color = opts.primary and WHITE or BLACK, width = w - 2 * (t + Theme.px(8)) })
  -- a real container tree (not a painted bitmap), so the label is on screen as text
  local box = Theme.box(w, h, label, { filled = opts.primary, border = t, radius = 8 })
  return TapRow:new { callback = opts.callback, viewport = opts.viewport, box }
end

return Button
