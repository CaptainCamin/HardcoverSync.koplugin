-- Button (MMD): rectangular (radius 8), 2px border, Black label. `primary` is filled black with a
-- white label (one per screen); the rest are outlined. The whole box is the touch area, so keep
-- `h` at 48 or more.

local Blitbuffer = require("ffi/blitbuffer")

local VerticalGroup = require("ui/widget/verticalgroup")

local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local Button = {}

Button.HEIGHT = Theme.px(64) -- dialog and sheet action buttons

-- opts { label, w, h (default HEIGHT, or the height of `scale`), scale ("small" | "medium" | "large", see Theme.mmd.button.height; `h` wins), primary, enabled (false: Black label in a dotted box, never filled, no tap), size (label size, default 21), callback, viewport }
function Button.new(opts)
  local w, h = opts.w, opts.h or Theme.mmd.button.height[opts.scale] or Button.HEIGHT
  local t = Theme.mmd.button.border
  local off = opts.enabled == false
  local label = Theme.mmdText(opts.label, "strong", opts.size or 21,
    { color = (opts.primary and not off) and WHITE or BLACK, width = w - 2 * (t + Theme.px(8)) })
  -- a real container tree (not a painted bitmap), so the label is on screen as text
  local box = Theme.box(w, h, label, { filled = opts.primary and not off, border = t, radius = 8, dotted = off })
  -- the label and width ride on the result, where a screen's focus order and its tests look for them
  return TapRow:new { callback = opts.callback, viewport = opts.viewport, text = opts.label, width = w, box }
end

-- A round button: an outlined circle holding an icon, with or without a label under it.
-- opts { icon (name in icons/ or a path), label (optional), scale ("small" | "medium" | "large", default
-- "medium"), label_size (default Theme.mmd.round_button.label), label_width (optional maximum),
-- enabled (false: dotted circle, no tap), callback, viewport }. The tap area is the circle and
-- its label, and the circle is never under TOUCH_MIN.
function Button.round(opts)
  local m = Theme.mmd.round_button
  local d = m.size[opts.scale or "medium"] or m.size.medium
  local off = opts.enabled == false
  local icon = Theme.icon(opts.icon, math.floor(d * m.icon))
  local circle = Theme.box(d, d, icon, { border = Theme.mmd.button.border, round = true, dotted = off })
  local content = circle
  if opts.label and opts.label ~= "" then
    local label = Theme.mmdText(opts.label, "strong", opts.label_size or m.label,
      { width = opts.label_width or math.max(d, Theme.px(96)) })
    content = VerticalGroup:new { align = "center", circle, Theme.span(m.gap), label }
  end
  return TapRow:new { callback = (not off) and opts.callback or nil, viewport = opts.viewport,
    text = opts.label, width = content:getSize().w, content }
end

return Button
