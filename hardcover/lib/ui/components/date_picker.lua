-- Date picker (after MMD's DatePicker, as a Dialog): the month and the year each between a minus
-- and a plus, then the month as a grid of 48 square days, Sunday first, with the chosen day filled
-- black. The grid is always six weeks tall, so nothing below it moves from one month to the next.
-- Tapping a day chooses it; Save keeps it. Each change draws the dialog again.
--
--   DatePicker.show { title = "First day", year = 2026, month = 10, day = 2,
--                     save_label = "Set date", on_save = function(year, month, day) ... end }

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")

local Button = require("hardcover/lib/ui/components/button")
local Dialog = require("hardcover/lib/ui/components/dialog")
local Draw = require("hardcover/lib/ui/components/draw")
local Goals = require("hardcover/lib/goals")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local _ = require("gettext")

local DatePicker = {}

local STEP = Theme.px(56) -- the month and year buttons
local CELL = Theme.px(48) -- MMD's date cell

local MONTHS = { _("January"), _("February"), _("March"), _("April"), _("May"), _("June"), _("July"),
  _("August"), _("September"), _("October"), _("November"), _("December") }
local WEEKDAYS = { _("S"), _("M"), _("T"), _("W"), _("T"), _("F"), _("S") }

local function daysInMonth(y, m)
  local ny, nm = y, m + 1
  if nm > 12 then ny, nm = y + 1, 1 end
  return Goals.days(ny, nm, 1) - Goals.days(y, m, 1)
end

local function stepButton(icon, callback)
  local box = Theme.box(STEP, STEP, Draw.icon(icon, Theme.px(28)),
    { border = Theme.mmd.button.border, radius = 8 })
  return TapRow:new { callback = callback, text = icon, width = STEP, box }
end

-- the row  [-]  label  [+]  across `width`
local function stepRow(width, label, on_minus, on_plus)
  local text = Theme.mmdText(label, "strong", 25)
  local cell = CenterContainer:new { dimen = Geom:new { w = width - 2 * STEP, h = STEP }, text }
  return HorizontalGroup:new { align = "center", stepButton("minus", on_minus), cell,
    stepButton("plus", on_plus) }
end

function DatePicker.show(opts)
  local state = { y = opts.year, m = opts.month, d = opts.day }
  local overlay
  local render

  local function shift(dm, dy)
    local m = state.m + dm
    local y = state.y + dy
    if m < 1 then m, y = 12, y - 1 elseif m > 12 then m, y = 1, y + 1 end
    state.y, state.m = math.max(1, y), m
    state.d = math.min(state.d, daysInMonth(state.y, state.m))
    render()
  end

  function render()
    if overlay then overlay:close() end
    local inner_w = Dialog.innerWidth()
    local cw = math.floor(inner_w / 7)
    local body = VerticalGroup:new { align = "left",
      stepRow(inner_w, MONTHS[state.m], function() shift(-1, 0) end, function() shift(1, 0) end),
      Theme.span(Theme.px(8)),
      stepRow(inner_w, tostring(state.y), function() shift(0, -1) end, function() shift(0, 1) end),
      Theme.span(Theme.px(12)),
    }
    local head = HorizontalGroup:new {}
    for i = 1, 7 do
      head[#head + 1] = CenterContainer:new { dimen = Geom:new { w = cw, h = CELL },
        Theme.mmdText(WEEKDAYS[i], "strong", 21) }
    end
    body[#body + 1] = head

    local first_wd = (Goals.days(state.y, state.m, 1) + 4) % 7 -- 1970-01-01 was a Thursday
    local count = daysInMonth(state.y, state.m)
    for week = 0, 5 do
      local row = HorizontalGroup:new {}
      for col = 0, 6 do
        local day = week * 7 + col - first_wd + 1
        if day < 1 or day > count then
          row[#row + 1] = Theme.hspan(cw)
        else
          local chosen = day == state.d
          local label = Theme.mmdText(tostring(day), chosen and "strong" or "text", 21,
            { color = chosen and Theme.WHITE or Theme.BLACK })
          local face = chosen and Theme.box(cw, CELL, label, { filled = true, border = 0, radius = 8 })
            or CenterContainer:new { dimen = Geom:new { w = cw, h = CELL }, label }
          row[#row + 1] = TapRow:new { text = tostring(day), width = cw,
            callback = function() state.d = day; render() end, face }
        end
      end
      body[#body + 1] = row
    end

    overlay = Dialog.show {
      title = opts.title,
      body = body,
      buttons = {
        { label = _("Cancel") },
        { label = opts.save_label or _("Save"), primary = true, callback = function()
          if opts.on_save then opts.on_save(state.y, state.m, state.d) end
        end },
      },
    }
  end

  render()
end

return DatePicker
