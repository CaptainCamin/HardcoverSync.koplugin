-- Popover menu (MMD "Menu"): a small rounded box with a 2px border and dotted dividers, anchored
-- under the icon that opened it (the sort menu under the sort icon). The current choice has a tick in
-- front and a Black label. Tapping an item closes the menu and runs its callback; a tap anywhere
-- else closes it. At most five or six items.

local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Overlay = require("hardcover/lib/ui/components/overlay")
local Theme = require("hardcover/lib/ui/theme")

local Popover = {}

Popover.WIDTH = Theme.px(320)

-- opts { items = { { label, current, callback } }, x, y (the box's top-right corner), on_dismiss }
-- Returns the shown overlay.
function Popover.show(opts)
  local w = Popover.WIDTH
  local border = Theme.line.firm
  local overlay
  local list = VerticalGroup:new { align = "left" }
  local tick = Theme.px(18)
  for i, item in ipairs(opts.items) do
    list[#list + 1] = ListItem.new {
      width = w - 2 * border,
      label = item.label,
      strong = item.current and true or false,
      h = Theme.px(56),
      lead = item.current and Draw.check(tick, Theme.px(3)) or Draw.drawn(tick, tick, function() end),
      divider = (i < #opts.items) and "dotted" or nil,
      callback = function()
        overlay:close()
        if item.callback then item.callback() end
      end,
    }
  end
  local menu = FrameContainer:new {
    bordersize = border, radius = Theme.px(10), padding = 0, margin = 0,
    color = Theme.BLACK, background = Theme.WHITE, list,
  }
  overlay = Overlay:new { anchor = "point", x = opts.x, y = opts.y, on_dismiss = opts.on_dismiss, menu }
  return overlay:show()
end

return Popover
