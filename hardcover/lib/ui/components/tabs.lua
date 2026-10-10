-- Tabs (MMD): a 50 tall row of two or three short labels. The active tab is Black with a thick (4)
-- black underline; the others are Medium over the thin rule that runs under the whole row. Tap only,
-- no swiping between them, and the content below redraws in full when one is chosen.

local Blitbuffer = require("ffi/blitbuffer")
local HorizontalGroup = require("ui/widget/horizontalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local BLACK = Blitbuffer.COLOR_BLACK

local Tabs = {}

-- opts { width, tabs = { { label, count (shown in brackets after the label), active, callback } }, viewport }
function Tabs.new(opts)
  local h = Theme.mmd.tabs.h
  local n = #opts.tabs
  local cell_w = math.floor(opts.width / n)
  local underline = Theme.px(4)
  local row = HorizontalGroup:new { align = "top" }
  for i, tab in ipairs(opts.tabs) do
    local w = (i == n) and (opts.width - (n - 1) * cell_w) or cell_w
    local label = HorizontalGroup:new { align = "center",
      Theme.mmdText(tab.label, tab.active and "strong" or "text", 15) }
    if tab.count then
      label[#label + 1] = Theme.hspan(Theme.px(6))
      label[#label + 1] = Theme.mmdText("(" .. tab.count .. ")", "text", 15, { secondary = true })
    end
    local size = label:getSize()
    local cell = Draw.drawn(w, h, function(bb, x, y)
      bb:paintRect(x, y + h - Theme.line.hair, w, Theme.line.hair, BLACK)
      label:paintTo(bb, x + math.floor((w - size.w) / 2), y + math.floor((h - underline - size.h) / 2))
      if tab.active then bb:paintRect(x, y + h - underline, w, underline, BLACK) end
    end)
    row[#row + 1] = TapRow:new { callback = tab.callback, viewport = opts.viewport, cell }
  end
  return row
end

return Tabs
