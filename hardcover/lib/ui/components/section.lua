-- A section's start (mocks 4, 7, 8): a dotted rule and a small Black label, tight. The heavy rule
-- under a big heading is for screens of their own. A page is a stack of these, each one block for the
-- scroll control: the block carries its own spacing, so a page step lands on a block's edge.

local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")

local Theme = require("hardcover/lib/ui/theme")

local Section = {}

-- opts { right = a widget at the far end of the label's line (a count) }. `label` may be nil: a
-- rule with no words, for a block that starts with its own content.
function Section.new(label, width, opts)
  opts = opts or {}
  local group = VerticalGroup:new { align = "left", Theme.span("s"), Theme.dottedRule(width), Theme.span("s") }
  if label then
    local right = opts.right
    local text = Theme.mmdText(label, "strong", 18, { width = right and (width - right:getSize().w - Theme.space.m) or width })
    if right then
      local gap = math.max(0, width - text:getSize().w - right:getSize().w)
      table.insert(group, HorizontalGroup:new { align = "center", text, Theme.hspan(gap), right })
    else
      table.insert(group, text)
    end
    table.insert(group, Theme.span("xs"))
  end
  return group
end

return Section
