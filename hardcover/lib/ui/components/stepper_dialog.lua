-- Stepper dialog (a Dialog with number steppers in its body): for a number that is set rather than
-- typed, a rating or a page. Each field is a big value between a minus and a plus, 72 square, both
-- always on screen; a field with a `big_step` has a second row that moves by that much, so a long
-- range is not a hundred taps (the stock spinner did that with a long press, which nothing here
-- relies on). The value stops at its ends. Cancel and Save are the Dialog's stacked buttons.
--
--   StepperDialog.show {
--     title = "Set rating", text = "optional line",
--     value = 2.5, min = 0, max = 5, step = 0.5, big_step = nil, format = function(v) return ... end,
--     save_label = "Save", on_save = function(value) ... end,
--   }
--
-- Or several fields, each { label, value, min, max, step, big_step, format }, with `on_change(values,
-- index)` returning the values to show once field `index` moved (the other one follows it), and
-- `on_save(first, second, ...)`.
--
-- `toggle = { label, support, on }` adds a switch row under the steppers (the whole row is the tap);
-- its state is the last argument of `on_save`.

local UIManager = require("ui/uimanager")

local Button = require("hardcover/lib/ui/components/button")
local Dialog = require("hardcover/lib/ui/components/dialog")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Switch = require("hardcover/lib/ui/components/switch")
local Draw = require("hardcover/lib/ui/components/draw")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")

local _ = require("gettext")

local StepperDialog = {}

local SIZE = Theme.px(72) -- a step button: well over the minimum touch target
local BIG_H = Theme.px(48)

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function defaultFormat(field)
  if field.step % 1 == 0 then return function(v) return string.format("%d", v) end end
  return function(v) return string.format("%.1f", v) end
end

local function stepButton(icon, callback)
  local glyph = Draw.icon(icon, Theme.px(32))
  local box = Theme.box(SIZE, SIZE, glyph, { border = Theme.mmd.button.border, radius = 8 })
  return TapRow:new { callback = callback, text = icon, width = SIZE, box }
end

function StepperDialog.show(opts)
  local fields = opts.fields or { opts }
  local inner_w = Dialog.innerWidth()
  local values, cells = {}, {}
  local overlay

  local function refresh()
    for i, cell in ipairs(cells) do
      local field = fields[i]
      cell.text:setText(field.format_fn(values[i]))
    end
    if overlay then
      UIManager:setDirty(overlay, function() return "ui", overlay:refreshRegion() end)
    end
  end

  local function move(i, delta)
    local field = fields[i]
    values[i] = clamp(values[i] + delta, field.min, field.max)
    if opts.on_change then
      local changed = opts.on_change({ unpack(values) }, i)
      if changed then
        for j = 1, #fields do values[j] = clamp(changed[j] or values[j], fields[j].min, fields[j].max) end
      end
    end
    refresh()
  end

  local body = VerticalGroup:new { align = "left" }
  for i, field in ipairs(fields) do
    values[i] = clamp(field.value or field.min, field.min, field.max)
    field.format_fn = field.format or defaultFormat(field)
    if i > 1 then body[#body + 1] = Theme.span(Theme.px(12)) end
    if field.label then
      body[#body + 1] = Theme.mmdText(field.label, "text", 21, { width = inner_w })
      body[#body + 1] = Theme.span(Theme.px(6))
    end
    local text = Theme.mmdText(field.format_fn(values[i]), "strong", 40)
    local value_w = inner_w - 2 * SIZE
    -- a fixed box, so the buttons stay where they are as the number changes width
    local cell = CenterContainer:new { dimen = Geom:new { w = value_w, h = SIZE }, text }
    cell.text = text
    cells[i] = cell
    body[#body + 1] = HorizontalGroup:new { align = "center",
      stepButton("minus", function() move(i, -field.step) end), cell,
      stepButton("plus", function() move(i, field.step) end) }
    if field.big_step then
      body[#body + 1] = Theme.span(Theme.px(8))
      local half = math.floor((inner_w - Theme.px(8)) / 2)
      local label = string.format(field.big_step % 1 == 0 and "%d" or "%.1f", field.big_step)
      body[#body + 1] = HorizontalGroup:new {
        Button.new { label = "-" .. label, w = half, h = BIG_H, callback = function() move(i, -field.big_step) end },
        Theme.hspan(Theme.px(8)),
        Button.new { label = "+" .. label, w = half, h = BIG_H, callback = function() move(i, field.big_step) end },
      }
    end
  end

  local toggled = opts.toggle and opts.toggle.on == true
  if opts.toggle then
    local item
    local function build()
      item = ListItem.new { width = inner_w, label = opts.toggle.label, support = opts.toggle.support,
        divider = nil, trailing = Switch.new { on = toggled },
        callback = function()
          toggled = not toggled
          body[#body] = build()
          refresh()
        end }
      return item
    end
    body[#body + 1] = Theme.span(Theme.px(12))
    body[#body + 1] = build()
  end

  overlay = Dialog.show {
    title = opts.title,
    text = opts.text,
    body = body,
    buttons = {
      { label = _("Cancel") },
      { label = opts.save_label or _("Save"), primary = true, callback = function()
        if opts.on_save then
          local args = { unpack(values) }
          if opts.toggle then args[#fields + 1] = toggled end
          opts.on_save(unpack(args, 1, #fields + (opts.toggle and 1 or 0)))
        end
      end },
    },
  }
  return overlay
end

return StepperDialog
