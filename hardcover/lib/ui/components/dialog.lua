-- Dialog (MMD): a question or notice in a box in the middle of the screen, outlined all round with
-- rounded corners (MMD's 3px rule on top is this outline here). A Black 25 heading that says what it is about ("No internet connection", not
-- "Connection Error"), Medium 21 text, and its actions side by side in one row, 64 high, the filled one on the right (MMD stacks
-- them; an e-reader is wide enough for a row).
-- The configurations are MMD's six:
--   standard             heading, text, a filled and an outlined button
--   warning              the same under a warning triangle, everything centred
--   close icon           heading, text and an X at the top right, no buttons: passive information
--   warning + close      the triangle, the X, and no buttons
--   single action        one outlined button: an acknowledgement, never "Okay" plus "Cancel"
--   warning single       the triangle and one button
-- A dialog interrupts, so it is for a decision or something that must be read, not for feedback on
-- what the user just did (that is a snackbar).

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

-- MMD hangs its dialogs off the bottom edge at the full width of a small phone-shaped screen. On the
-- larger, wider readers this plugin runs on that is a strip with a lot of air in it, so the dialog
-- floats instead, about 80% of the screen wide (docs/design/principles.md): never under MMD's 364.
local function width()
  local sw = Device.screen:getWidth()
  return math.min(sw - 2 * Theme.margin, math.max(Theme.px(364), math.floor(sw * 0.8)))
end
local SIDE = Theme.px(12)
local RADIUS = Theme.px(12) -- as the goal cards

Dialog.width = width
Dialog.RADIUS = RADIUS

-- Actions in one row, as wide as `inner_w` in all: the filled one on the right, the outlined one on its
-- left. `ordered` is the filled one first; `press(spec)` runs when one is tapped.
function Dialog.buttonRow(ordered, inner_w, gap, press)
  local bw = #ordered == 2 and math.floor((inner_w - gap) / 2) or inner_w
  local row = HorizontalGroup:new { align = "top" }
  for i = #ordered, 1, -1 do
    local spec = ordered[i]
    if i < #ordered then row[#row + 1] = Theme.hspan(gap) end
    row[#row + 1] = Button.new { label = spec.label, w = bw, primary = spec.primary,
      callback = function() press(spec) end }
  end
  return row
end

-- the width inside the padding: what a `body` can be as wide as
function Dialog.innerWidth()
  return width() - 2 * Theme.line.firm - 2 * SIDE
end

-- opts { title, text, warning (the triangle, and centred text), body (a widget under the text, up to
-- Dialog.innerWidth() wide: a field, a progress bar), buttons = { { label, callback, primary } }
-- (none, one or two, side by side: with none the dialog has an X instead), locked (a tap outside, Back and the X do
-- nothing: the dialog goes when its work is done, and has no X), on_dismiss }
function Dialog.show(opts)
  local w = width()
  local side = SIDE
  local inner_w = Dialog.innerWidth()
  local buttons = {}
  -- the filled one first; buttonRow puts it on the right
  for _, spec in ipairs(opts.buttons or {}) do if spec.primary then buttons[#buttons + 1] = spec end end
  for _, spec in ipairs(opts.buttons or {}) do if not spec.primary then buttons[#buttons + 1] = spec end end
  local overlay
  assert(#buttons <= 2, "a dialog has at most two buttons")
  local closable = #buttons == 0 and not opts.locked
  local align = opts.warning and "center" or "left"

  local function icon_widget(name)
    return Draw.drawn(Theme.px(28), Theme.px(28), function(bb, x, y)
      Draw.ICONS[name](bb, x, y, Theme.px(28), Theme.px(2.5))
    end)
  end
  local close
  if closable then
    close = TapRow:new {
      callback = function() overlay:dismiss() end,
      Draw.drawn(Theme.TOUCH_MIN, Theme.TOUCH_MIN, function(bb, x, y)
        local o = math.floor((Theme.TOUCH_MIN - Theme.px(28)) / 2)
        Draw.ICONS.close(bb, x + o, y + o, Theme.px(28), Theme.px(2.5))
      end),
    }
  end

  local tface, tbold = Theme.mmdFace("strong", 25)
  local col = VerticalGroup:new { align = "left", Theme.span(Theme.px(12)) }
  local function indented(widget)
    col[#col + 1] = HorizontalGroup:new { Theme.hspan(side), widget }
  end
  if opts.warning then
    -- the triangle in the middle, with the X, when there is one, at the right of the same row
    local icon = icon_widget("warning")
    local lead = math.floor((inner_w - Theme.px(28)) / 2)
    local row = HorizontalGroup:new { align = "center", Theme.hspan(lead), icon }
    if closable then
      row[#row + 1] = Theme.hspan(inner_w - lead - Theme.px(28) - Theme.TOUCH_MIN)
      row[#row + 1] = close
    end
    indented(row)
    col[#col + 1] = Theme.span(closable and Theme.px(2) or Theme.px(12))
    local title = TextBoxWidget:new { text = opts.title, face = tface, bold = tbold, width = inner_w,
      alignment = "center", fgcolor = Theme.BLACK }
    indented(title)
  elseif closable then
    local title = TextBoxWidget:new { text = opts.title, face = tface, bold = tbold,
      width = inner_w - Theme.TOUCH_MIN, fgcolor = Theme.BLACK }
    indented(HorizontalGroup:new { align = "top", title,
      Theme.hspan(inner_w - title:getSize().w - Theme.TOUCH_MIN), close })
  else
    indented(TextBoxWidget:new { text = opts.title, face = tface, bold = tbold, width = inner_w, fgcolor = Theme.BLACK })
  end
  if opts.text then
    local face, bold = Theme.mmdFace("text", 21)
    col[#col + 1] = Theme.span(Theme.px(10))
    indented(TextBoxWidget:new { text = opts.text, face = face, bold = bold, width = inner_w,
      alignment = align, fgcolor = Theme.BLACK })
  end
  if opts.body then
    col[#col + 1] = Theme.span(Theme.px(12))
    indented(opts.body)
  end
  if #buttons > 0 then
    col[#col + 1] = Theme.span(Theme.px(24))
    indented(Dialog.buttonRow(buttons, inner_w, Theme.px(12), function(spec)
      overlay:close()
      if spec.callback then spec.callback() end
    end))
  end
  col[#col + 1] = Theme.span(Theme.px(12))

  local box = FrameContainer:new { width = w, bordersize = Theme.line.firm, radius = RADIUS,
    padding = 0, margin = 0, color = Theme.BLACK, background = Theme.WHITE, col }
  overlay = Overlay:new { anchor = "center", on_dismiss = opts.on_dismiss, box }
  if opts.locked then overlay.dismiss = function() end end
  return overlay:show()
end

return Dialog
