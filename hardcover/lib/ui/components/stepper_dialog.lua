-- Stepper dialog (a Dialog with number steppers in its body): for a number that is set rather than
-- typed, a rating or a page. Each field is a big value between a minus and a plus, 72 square, both
-- always on screen; a field with a `big_step` has a second row that moves by that much, so a long
-- range is not a hundred taps. Holding a minus or plus repeats the step and speeds up (a shortcut:
-- every move also has a button). The value is in a box: tap it to type the number. The value stops
-- at its ends, and the button that would go past one is drawn dotted and does nothing. Cancel and
-- Save are the Dialog's stacked buttons.
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
local InputDialog = require("hardcover/lib/ui/components/input_dialog")
local Draw = require("hardcover/lib/ui/components/draw")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
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

local HOLD_FIRST = 6 -- repeats at the plain step before it speeds up
local HOLD_FAST = 20 -- repeats before it speeds up again
local HOLD_EVERY = 0.25 -- seconds between repeats

-- A minus or plus. `enabled == false` (the value is at that end): a dotted box that does nothing.
-- A hold calls `on_hold` at the press; `on_release` runs when the finger lifts (the caller repeats in
-- between).
local StepButton = InputContainer:extend { name = "hardcover_step_button" }

function StepButton:init()
  local size = self[1]:getSize()
  self.dimen = Geom:new { x = 0, y = 0, w = size.w, h = size.h }
  local range = function() return self.dimen end
  self.ges_events = { TapStep = { GestureRange:new { ges = "tap", range = range } } }
  if self.on_hold then
    self.ges_events.HoldStep = { GestureRange:new { ges = "hold", range = range } }
    self.ges_events.HoldReleaseStep = { GestureRange:new { ges = "hold_release", range = range } }
  end
end

function StepButton:onTapStep()
  if self.callback then self.callback() end
  return true
end

function StepButton:onHoldStep()
  if self.on_hold then self.on_hold() end
  return true
end

function StepButton:onHoldReleaseStep()
  if self.on_release then self.on_release() end
  return true
end

local function stepButton(icon, enabled, callback, on_hold, on_release)
  local glyph = Draw.icon(icon, Theme.px(32))
  local box = Theme.box(SIZE, SIZE, glyph, { border = Theme.mmd.button.border, radius = 8, dotted = not enabled })
  if not enabled then return StepButton:new { text = icon, width = SIZE, box } end
  return StepButton:new { callback = callback, on_hold = on_hold, on_release = on_release, text = icon, width = SIZE, box }
end

function StepperDialog.show(opts)
  local fields = opts.fields or { opts }
  local inner_w = Dialog.innerWidth()
  local values = {}
  local overlay

  local rows, boxes = {}, {} -- per field: the minus/value/plus row, and the value's text
  local build_row
  local hold_gen = 0 -- bumped to drop a hold's pending timer

  local function refresh()
    for i = 1, #fields do
      local field = fields[i]
      boxes[i]:setText(field.format_fn(values[i]))
      local at_min, at_max = values[i] <= field.min, values[i] >= field.max
      if rows[i].at_min ~= at_min or rows[i].at_max ~= at_max then build_row(i) end
    end
    if overlay then
      UIManager:setDirty(overlay, function() return "ui", overlay:refreshRegion() end)
    end
  end

  local function setValue(i, v)
    values[i] = clamp(v, fields[i].min, fields[i].max)
    if opts.on_change then
      local changed = opts.on_change({ unpack(values) }, i)
      if changed then
        for j = 1, #fields do values[j] = clamp(changed[j] or values[j], fields[j].min, fields[j].max) end
      end
    end
    refresh()
  end

  local function move(i, delta) setValue(i, values[i] + delta) end

  local function stopHold()
    hold_gen = hold_gen + 1
  end

  -- how far one repeat of a hold goes: the plain step, then the field's big step (or five steps),
  -- then five of those
  local function holdDelta(field, n)
    local fast = field.big_step or field.step * 5
    if n < HOLD_FIRST then return field.step end
    if n < HOLD_FAST then return fast end
    return fast * 5
  end

  local function holdStep(i, dir)
    local field = fields[i]
    hold_gen = hold_gen + 1
    local gen = hold_gen
    local n = 0
    local function tick()
      if gen ~= hold_gen then return end
      local before = values[i]
      move(i, dir * holdDelta(field, n))
      n = n + 1
      if values[i] == before then return stopHold() end -- at the end (or pinned there by on_change)
      UIManager:scheduleIn(HOLD_EVERY, tick)
    end
    tick()
  end

  -- tap the number: type it. Out of range is pulled in to the nearest end, and a number between steps
  -- to the nearest step; something that is not a number leaves the value as it was.
  local function typeValue(i)
    local field = fields[i]
    local input
    input = InputDialog:new {
      title = field.label or opts.title,
      input = string.format("%g", values[i]),
      input_type = "number",
      buttons = {
        { label = _("Cancel"), callback = function() UIManager:close(input) end },
        { label = _("Set"), primary = true, callback = function()
          local typed = tonumber((input:getInputText():gsub(",", ".")))
          UIManager:close(input)
          if not typed then return end
          typed = clamp(typed, field.min, field.max)
          local snapped = field.min + math.floor((typed - field.min) / field.step + 0.5) * field.step
          setValue(i, snapped)
        end },
      },
    }
    UIManager:show(input)
    if input.onShowKeyboard then input:onShowKeyboard() end
  end

  build_row = function(i)
    local field = fields[i]
    local row = rows[i]
    row.at_min, row.at_max = values[i] <= field.min, values[i] >= field.max
    local function held(dir)
      return function() holdStep(i, dir) end
    end
    row[1] = stepButton("minus", not row.at_min, function() move(i, -field.step) end, held(-1), stopHold)
    row[#row] = stepButton("plus", not row.at_max, function() move(i, field.step) end, held(1), stopHold)
    row:resetLayout()
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
    boxes[i] = text
    local gap = Theme.px(6)
    local value_w = inner_w - 2 * SIZE - 2 * gap
    -- a fixed, outlined box, so the buttons stay where they are as the number changes width, and a
    -- tap on it is visibly a field
    local cell = TapRow:new { callback = function() typeValue(i) end, text = "value", width = value_w,
      Theme.box(value_w, SIZE, text, { border = Theme.mmd.button.border, radius = 8 }) }
    rows[i] = HorizontalGroup:new { align = "center", Theme.hspan(1), Theme.hspan(gap), cell, Theme.hspan(gap), Theme.hspan(1) }
    build_row(i)
    body[#body + 1] = rows[i]
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
