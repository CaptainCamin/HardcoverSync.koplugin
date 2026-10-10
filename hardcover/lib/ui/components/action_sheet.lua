-- Action sheet (MMD bottom sheet, button form): a short list of things to do with something, as
-- outlined buttons, closed by one filled Cancel at the bottom. Never a radio list (that is the
-- choice sheet). The 3px rule on top, a Black 25 title and an optional line of Medium 18 text.

local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Device = require("device")
local VerticalGroup = require("ui/widget/verticalgroup")

local Button = require("hardcover/lib/ui/components/button")
local Overlay = require("hardcover/lib/ui/components/overlay")
local Theme = require("hardcover/lib/ui/theme")

local ActionSheet = {}

-- opts { title, text, actions = { { label, callback } }, cancel_label (default "Cancel"), on_dismiss }
function ActionSheet.show(opts)
  local sw = Device.screen:getWidth()
  local side = Theme.px(12)
  local inner_w = sw - 2 * side
  local overlay
  local col = VerticalGroup:new { align = "left" }
  col[#col + 1] = Overlay.top_rule(sw)
  col[#col + 1] = Theme.span(Theme.px(24))
  if opts.title then
    col[#col + 1] = HorizontalGroup:new { Theme.hspan(side + Theme.px(4)),
      Theme.mmdText(opts.title, "strong", 25, { width = inner_w - Theme.px(8) }) }
    col[#col + 1] = Theme.span(Theme.px(6))
  end
  if opts.text then
    col[#col + 1] = HorizontalGroup:new { Theme.hspan(side + Theme.px(4)),
      Theme.mmdText(opts.text, "text", 18, { secondary = true, width = inner_w - Theme.px(8) }) }
    col[#col + 1] = Theme.span(Theme.px(6))
  end
  col[#col + 1] = Theme.span(Theme.px(10))
  for _, action in ipairs(opts.actions) do
    col[#col + 1] = HorizontalGroup:new { Theme.hspan(side), Button.new {
      label = action.label, w = inner_w,
      callback = function()
        overlay:close()
        if action.callback then action.callback() end
      end,
    } }
    col[#col + 1] = Theme.span(Theme.px(16))
  end
  col[#col + 1] = HorizontalGroup:new { Theme.hspan(side), Button.new {
    label = opts.cancel_label or "Cancel", w = inner_w, primary = true,
    callback = function() overlay:dismiss() end,
  } }
  col[#col + 1] = Theme.span(Theme.px(20))

  local sheet = FrameContainer:new { width = sw, bordersize = 0, padding = 0, margin = 0,
    background = Theme.WHITE, col }
  overlay = Overlay:new { anchor = "bottom", on_dismiss = opts.on_dismiss, sheet }
  return overlay:show()
end

return ActionSheet
