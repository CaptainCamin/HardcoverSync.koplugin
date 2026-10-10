-- Navigation bar (MMD): 57 tall at the bottom edge, two to four destinations. A black rule across the
-- top with a 2 white gap under it; the active destination gets a 4 black indicator along its bottom edge and a
-- Black label, the others a Medium one. Each tab keeps its own scroll position (the caller's job).
-- An item's icon is `icon_name` (one of the plugin's SVGs in icons/) or `icon`, a
-- function(bb, x, y, size, stroke) drawing into a square.

local Blitbuffer = require("ffi/blitbuffer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local BLACK = Blitbuffer.COLOR_BLACK

local NavBar = {}

NavBar.HEIGHT = Theme.mmd.nav_bar.h

-- opts { width, items = { { label, icon_name | icon, active, callback } } }
function NavBar.new(opts)
  local h = Theme.mmd.nav_bar.h
  local rule, gap, indicator = Theme.line.firm, Theme.px(2), Theme.px(4)
  local n = #opts.items
  local cell_w = math.floor(opts.width / n)
  local icon_size = Theme.mmd.nav_bar.icon + Theme.px(6)
  local row = HorizontalGroup:new { align = "top" }
  for i, item in ipairs(opts.items) do
    local w = (i == n) and (opts.width - (n - 1) * cell_w) or cell_w
    local svg = item.icon_name and Theme.icon(item.icon_name, icon_size)
    local label = Theme.mmdText(item.label, item.active and "strong" or "text", 15, { width = w - Theme.px(8) })
    local cell = Draw.drawn(w, h - rule - gap, function(bb, x, y, cw, ch)
      if item.active then bb:paintRect(x + Theme.px(8), y + ch - indicator, cw - 2 * Theme.px(8), indicator, BLACK) end
      local ls = label:getSize()
      local block_h = icon_size + Theme.px(2) + ls.h
      local top = y + math.floor((ch - indicator - block_h) / 2)
      local ix = x + math.floor((cw - icon_size) / 2)
      if svg then svg:paintTo(bb, ix, top)
      elseif item.icon then item.icon(bb, ix, top, icon_size, Theme.px(2.5)) end
      label:paintTo(bb, x + math.floor((cw - ls.w) / 2), top + icon_size + Theme.px(2))
    end)
    row[#row + 1] = TapRow:new { callback = item.callback, cell }
  end
  return VerticalGroup:new { align = "left",
    Draw.drawn(opts.width, rule, function(bb, x, y, w, ch) bb:paintRect(x, y, w, ch, BLACK) end),
    Theme.span(gap),
    row,
  }
end

return NavBar
