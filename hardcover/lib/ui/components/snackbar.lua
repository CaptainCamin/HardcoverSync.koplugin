-- Snackbar (MMD): a short message along the bottom edge after something the reader did, never from
-- the system alone ("Saved", "Added to Want to read"). 64 tall under the 3px rule, a Medium 21
-- message, at most one action (Undo, Retry), and an X. It goes away on its own after `timeout` seconds
-- (default 4) or on a tap anywhere else; that tap is spent closing it, because KOReader sends a tap to
-- one window only (a toast would pass it on, but then an Undo tap would also hit the page under it).
-- Static, no sliding.

local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Device = require("device")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local Overlay = require("hardcover/lib/ui/components/overlay")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Snackbar = {}

local HEIGHT = Theme.px(64)

-- opts { message, action = { label, callback }, timeout (seconds, default 4) }
function Snackbar.show(opts)
  local sw = Device.screen:getWidth()
  local side = Theme.px(16)
  local overlay
  local close = TapRow:new {
    callback = function() overlay:dismiss() end,
    Draw.drawn(Theme.TOUCH_MIN, Theme.TOUCH_MIN, function(bb, x, y)
      local o = math.floor((Theme.TOUCH_MIN - Theme.px(28)) / 2)
      Draw.ICONS.close(bb, x + o, y + o, Theme.px(28), Theme.px(2.5))
    end),
  }
  local right = HorizontalGroup:new { align = "center" }
  if opts.action then
    local label = Theme.mmdText(opts.action.label, "strong", 21)
    right[#right + 1] = TapRow:new {
      callback = function()
        overlay:close()
        if opts.action.callback then opts.action.callback() end
      end,
      LeftContainer:new { dimen = Geom:new { w = label:getSize().w + Theme.px(24), h = Theme.TOUCH_MIN }, label },
    }
  end
  right[#right + 1] = close
  local room = sw - 2 * side - right:getSize().w
  local line = HorizontalGroup:new { align = "center", Theme.hspan(side),
    LeftContainer:new { dimen = Geom:new { w = room, h = HEIGHT },
      Theme.mmdText(opts.message, "text", 21, { width = room - Theme.px(8) }) },
    right, Theme.hspan(side - Theme.px(4)) }
  local bar = FrameContainer:new { width = sw, bordersize = 0, padding = 0, margin = 0,
    background = Theme.WHITE, VerticalGroup:new { align = "left", Overlay.top_rule(sw), line } }

  overlay = Overlay:new { anchor = "bottom", bar }
  overlay.timeout_task = function() overlay:close() end
  UIManager:scheduleIn(opts.timeout or 4, overlay.timeout_task)
  return overlay:show()
end

return Snackbar
