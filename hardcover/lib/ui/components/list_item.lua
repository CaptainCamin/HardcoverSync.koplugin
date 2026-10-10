-- List item (MMD): label Black 21 / 23, optional supporting line Medium 18 / 18, 4 between, padding
-- 16 at the sides and 15.5 above and below. The whole row is the touch target, so a switch, radio,
-- checkbox or chevron is only drawn, never a second button. A 1px divider closes the row, dotted
-- between rows, starting after the leading icon. Rows in one list share one fixed height, so they
-- stay put from page to page.

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")

local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local px = Theme.px

local ListItem = {}

ListItem.PAD = Theme.mmd.row.pad_x
-- 15.5 + 23 + 4 + 18 + 15.5, and the divider
ListItem.H = Theme.mmd.row.pad_y * 2 + px(23) + Theme.mmd.row.gap + px(18) + Theme.line.hair
-- a label alone
ListItem.H_SINGLE = px(56)

local function divider(kind, width)
  if kind == "dotted" then return Theme.dottedRule(width) end
  if kind == "solid" then
    return LineWidget:new { dimen = Geom:new { w = width, h = Theme.line.hair }, background = Theme.BLACK }
  end
end

-- opts { width, label, support, trailing (a drawn widget: switch, radio, chevron...), lead (a
-- widget before the label), divider ("dotted" | "solid" | nil), divider_x (where the divider starts,
-- default the side padding), h (default H, or H_SINGLE with no supporting line), callback, viewport,
-- strong (label in Black, default true; false for a choice list's plain labels) }
function ListItem.new(opts)
  local h = opts.h or (opts.support and ListItem.H or ListItem.H_SINGLE)
  local rule = divider(opts.divider, opts.width)
  local rule_h = rule and rule:getSize().h or 0
  local trailing = opts.trailing
  local trailing_w = trailing and trailing:getSize().w or 0
  local gap = trailing and px(12) or 0
  local lead_w = opts.lead and (opts.lead:getSize().w + px(16)) or 0
  local label_w = opts.width - 2 * ListItem.PAD - trailing_w - gap - lead_w

  local block = VerticalGroup:new { align = "left",
    Theme.mmdText(opts.label, opts.strong == false and "text" or "strong", 21, { width = label_w }) }
  if opts.support then
    block[#block + 1] = Theme.span(Theme.mmd.row.gap)
    block[#block + 1] = Theme.mmdText(opts.support, "text", 18, { secondary = true, width = label_w })
  end

  local line = HorizontalGroup:new { align = "center", Theme.hspan(ListItem.PAD) }
  if opts.lead then
    line[#line + 1] = opts.lead
    line[#line + 1] = Theme.hspan(px(16))
  end
  line[#line + 1] = LeftContainer:new { dimen = Geom:new { w = label_w, h = h - rule_h }, block }
  if trailing then
    line[#line + 1] = Theme.hspan(gap)
    line[#line + 1] = trailing
  end
  line[#line + 1] = Theme.hspan(ListItem.PAD)

  local column = VerticalGroup:new { align = "left", line }
  if rule then
    local from = opts.divider_x or ListItem.PAD
    column[#column + 1] = HorizontalGroup:new { Theme.hspan(from), divider(opts.divider, opts.width - from) }
  end
  return TapRow:new { callback = opts.callback, viewport = opts.viewport, column }
end

-- A section heading above a group of rows: Black 15 capitals, 20 above and 6 below.
function ListItem.section(text, width)
  return VerticalGroup:new { align = "left",
    Theme.span(px(20)),
    HorizontalGroup:new { Theme.hspan(ListItem.PAD),
      Theme.mmdText(string.upper(text), "strong", 15, { width = width - 2 * ListItem.PAD }) },
    Theme.span(px(6)) }
end

return ListItem
