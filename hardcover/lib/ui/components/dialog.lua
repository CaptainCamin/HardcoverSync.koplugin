-- Dialog (MMD): a question or notice in a box in the middle of the screen, with the 3px rule on top.
-- A Black 25 title that says what it is about ("No internet connection", not "Connection Error"),
-- one short Medium 18 text, an X, and at most two buttons: the primary filled, the other outlined.
-- A notice that only needs acknowledging has one button, never "Okay" plus "Cancel".

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")

local Button = require("hardcover/lib/ui/components/button")
local Draw = require("hardcover/lib/ui/components/draw")
local Overlay = require("hardcover/lib/ui/components/overlay")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Dialog = {}

-- opts { title, text, buttons = { { label, callback, primary } } (one or two), on_dismiss }
function Dialog.show(opts)
  local sw = Device.screen:getWidth()
  local w = math.min(sw - 2 * Theme.margin, Theme.px(560))
  local side = Theme.px(20)
  local inner_w = w - 2 * side
  local overlay
  assert(#opts.buttons >= 1 and #opts.buttons <= 2, "a dialog has one or two buttons")

  local close = TapRow:new {
    callback = function() overlay:dismiss() end,
    Draw.drawn(Theme.TOUCH_MIN, Theme.TOUCH_MIN, function(bb, x, y)
      local o = math.floor((Theme.TOUCH_MIN - Theme.px(28)) / 2)
      Draw.ICONS.close(bb, x + o, y + o, Theme.px(28), Theme.px(2.5))
    end),
  }
  local title = Theme.mmdText(opts.title, "strong", 25, { width = inner_w - Theme.TOUCH_MIN })
  local col = VerticalGroup:new { align = "left", Overlay.top_rule(w), Theme.span(Theme.px(12)) }
  col[#col + 1] = HorizontalGroup:new { align = "center", Theme.hspan(side), title,
    Theme.hspan(inner_w - title:getSize().w - Theme.TOUCH_MIN), close }
  if opts.text then
    local face, bold = Theme.mmdFace("text", 18)
    col[#col + 1] = Theme.span(Theme.px(6))
    col[#col + 1] = HorizontalGroup:new { Theme.hspan(side), TextBoxWidget:new {
      text = opts.text, face = face, bold = bold, width = inner_w, fgcolor = Theme.secondary() } }
  end
  col[#col + 1] = Theme.span(Theme.px(20))
  local row = HorizontalGroup:new { Theme.hspan(side) }
  local gap = Theme.px(16)
  local bw = (#opts.buttons == 1) and inner_w or math.floor((inner_w - gap) / 2)
  for i, spec in ipairs(opts.buttons) do
    if i > 1 then row[#row + 1] = Theme.hspan(gap) end
    row[#row + 1] = Button.new { label = spec.label, w = bw, primary = spec.primary,
      callback = function()
        overlay:close()
        if spec.callback then spec.callback() end
      end }
  end
  col[#col + 1] = row
  col[#col + 1] = Theme.span(Theme.px(20))

  local box = FrameContainer:new { width = w, bordersize = Theme.line.firm,
    padding = 0, margin = 0, color = Theme.BLACK, background = Theme.WHITE, col }
  overlay = Overlay:new { anchor = "center", on_dismiss = opts.on_dismiss, box }
  return overlay:show()
end

return Dialog
