-- Note (MMD "info box"): a rounded box with a leading icon, a Black title, a line of supporting text
-- and, at the end, at most one small outlined button. Used above lists for something that needs
-- saying: changes waiting to sync. `dotted` draws the outline dotted (the sync box does, whether or not
-- anything is waiting; its two states differ by icon and words, and share one height so the page below
-- never moves). Without it the outline is a solid hairline.

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local VerticalGroup = require("ui/widget/verticalgroup")

local Button = require("hardcover/lib/ui/components/button")
local Draw = require("hardcover/lib/ui/components/draw")
local Theme = require("hardcover/lib/ui/theme")

local px = Theme.px
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local Note = {}

Note.MIN_H = px(62)

-- opts { width, icon_name (an SVG in icons/), title, text, dotted, action = { label, callback }, h }
-- `h` makes the box at least that tall (give both looks the taller one's height).
function Note.new(opts)
  local pad_x, pad_y, radius = px(14), px(12), px(10)
  local w = opts.width
  local icon = Theme.icon(opts.icon_name, px(26))

  local button
  if opts.action then
    local label = Theme.mmdText(opts.action.label, "strong", 18)
    local bw = label:getSize().w + px(32)
    label:free()
    button = Button.new { label = opts.action.label, w = bw, h = px(40), size = 18, callback = opts.action.callback }
  end

  local text_w = w - 2 * pad_x - icon:getSize().w - px(12) - (button and (button:getSize().w + px(12)) or 0)
  local words = VerticalGroup:new { align = "left",
    Theme.mmdText(opts.title, "strong", 21, { width = text_w }) }
  if opts.text then
    words[#words + 1] = Theme.span(px(3))
    words[#words + 1] = Theme.mmdText(opts.text, "text", 18, { secondary = true, width = text_w })
  end
  -- the words take the room, so the button sits at the far end of the box
  local row = HorizontalGroup:new { align = "center", icon, Theme.hspan(px(12)),
    LeftContainer:new { dimen = Geom:new { w = text_w, h = words:getSize().h }, words } }
  if button then
    row[#row + 1] = Theme.hspan(px(12))
    row[#row + 1] = button
  end

  local h = math.max(opts.h or Note.MIN_H, row:getSize().h + 2 * pad_y)
  local t = Theme.line.firm
  local border = Draw.drawn(w, h, function(bb, x, y)
    if opts.dotted then
      Draw.dottedBorder(bb, x, y, w, h, radius, t)
    else
      bb:paintRoundedRect(x, y, w, h, BLACK, radius)
      bb:paintRoundedRect(x + Theme.line.hair, y + Theme.line.hair, w - 2 * Theme.line.hair,
        h - 2 * Theme.line.hair, WHITE, math.max(0, radius - Theme.line.hair))
    end
  end)
  local inside = LeftContainer:new { dimen = Geom:new { w = w, h = h }, HorizontalGroup:new { Theme.hspan(pad_x), row } }
  return OverlapGroup:new { dimen = Geom:new { w = w, h = h }, allow_mirroring = false, border, inside }
end

return Note
