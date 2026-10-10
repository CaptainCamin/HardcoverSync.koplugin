-- Choice sheet (MMD bottom sheet, radio form): pick one of at most five or six. The 3px rule on top,
-- a Black 25 title with an X to close, and a radio list with the current choice selected. It has an X
-- and no Cancel, and it never carries action buttons: that is the action sheet. Choosing a row
-- closes the sheet and runs `on_choose(key)`.

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local VerticalGroup = require("ui/widget/verticalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Overlay = require("hardcover/lib/ui/components/overlay")
local Radio = require("hardcover/lib/ui/components/radio")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local ChoiceSheet = {}

-- opts { title, options = { { key, label } }, current (a key), on_choose(key), on_dismiss }
function ChoiceSheet.show(opts)
  local sw = Device.screen:getWidth()
  local side = Theme.px(12)
  local inner_w = sw - 2 * side
  local overlay
  local col = VerticalGroup:new { align = "left" }
  col[#col + 1] = Overlay.top_rule(sw)
  col[#col + 1] = Theme.span(Theme.px(24))

  local title = Theme.mmdText(opts.title, "strong", 25, { width = inner_w - Theme.TOUCH_MIN })
  local close = TapRow:new {
    callback = function() overlay:dismiss() end,
    Draw.drawn(Theme.TOUCH_MIN, Theme.TOUCH_MIN, function(bb, x, y)
      Draw.ICONS.close(bb, x + math.floor((Theme.TOUCH_MIN - Theme.px(28)) / 2),
        y + math.floor((Theme.TOUCH_MIN - Theme.px(28)) / 2), Theme.px(28), Theme.px(2.5))
    end),
  }
  col[#col + 1] = HorizontalGroup:new { align = "center", Theme.hspan(side + Theme.px(4)), title,
    Theme.hspan(inner_w - Theme.px(4) - title:getSize().w - Theme.TOUCH_MIN), close }
  col[#col + 1] = Theme.span(Theme.px(8))

  for i, option in ipairs(opts.options) do
    col[#col + 1] = HorizontalGroup:new { Theme.hspan(side), ListItem.new {
      width = inner_w, label = option.label, strong = false, h = Theme.px(56),
      trailing = Radio.new { selected = option.key == opts.current },
      divider = (i < #opts.options) and "dotted" or nil,
      callback = function()
        overlay:close()
        if opts.on_choose then opts.on_choose(option.key) end
      end,
    } }
  end
  col[#col + 1] = Theme.span(Theme.px(18))

  local sheet = FrameContainer:new { width = sw, bordersize = 0, padding = 0, margin = 0,
    background = Theme.WHITE, col }
  overlay = Overlay:new { anchor = "bottom", on_dismiss = opts.on_dismiss, sheet }
  return overlay:show()
end

return ChoiceSheet
