-- The pieces the goal screens share: the progress bar with a tick where you should
-- be today, a goal's big number, and the cards built from them. What each says comes
-- from Goals.pace; this only lays it out.

local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Goals = require("hardcover/lib/goals")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local GoalWidgets = {}

local function text(str, size, opts)
  opts = opts or {}
  return TextWidget:new {
    text = str,
    face = Theme.face(size),
    bold = opts.bold,
    max_width = opts.width,
    fgcolor = opts.grey and Theme.DARK_GREY or Theme.BLACK,
  }
end
GoalWidgets.text = text

-- The bar; a tick marks where you should be today, except on a goal that is done,
-- over, or not started (no "should be" to point at).
function GoalWidgets.bar(width, height, p, no_tick)
  local tick = not (no_tick or p.over or p.done or p.upcoming)
  return ProgressWidget:new {
    width = width,
    height = height,
    percentage = p.fraction,
    ticks = tick and { math.floor(p.pace_fraction * 1000) } or nil,
    last = 1000,
  }
end

-- "46" big, "/ 70 books" beside it, a "+1 finished offline" pill when a book finished
-- here has not been counted by Hardcover yet, and a "Waiting to sync" pill when the
-- goal itself was changed here and not sent
function GoalWidgets.figure(p)
  local row = HorizontalGroup:new {
    align = "bottom",
    text(string.format("%d", p.progress), "display", { bold = true }),
    Theme.hspan("s"),
    text(string.format(_("/ %d %s"), p.target, p.unit), "body", { grey = true }),
  }
  if p.extra and p.extra > 0 then
    table.insert(row, Theme.hspan("m"))
    table.insert(row, Theme.pill(string.format(_("+%d finished offline"), p.extra), { size = "small" }))
  end
  if p.pending then
    -- a change made here that Hardcover has not got yet
    table.insert(row, Theme.hspan("m"))
    table.insert(row, Theme.pill(p.held and _("Not sent") or _("Waiting to sync"), { size = "small" }))
  end
  return row
end

-- "6 behind pace  ·  91 days left"
function GoalWidgets.statusLine(p)
  local line = _(p.status)
  local left = Goals.leftText(p)
  if left ~= "" and not p.done and not p.over then line = line .. "  \194\183  " .. left end
  return line
end

--
-- One goal as a card: name, figure, bar, status line, what finishing takes. Tappable
-- when `on_tap` is given (it opens the goal).
--
function GoalWidgets.card(goal, p, width, viewport, on_tap)
  local body = VerticalGroup:new { align = "left" }
  table.insert(body, text(goal.name, "title", { bold = true, width = width }))
  table.insert(body, Theme.span("xs"))
  table.insert(body, GoalWidgets.figure(p))
  table.insert(body, Theme.span("s"))
  table.insert(body, GoalWidgets.bar(width, Screen:scaleBySize(16), p))
  table.insert(body, Theme.span("s"))
  table.insert(body, text(GoalWidgets.statusLine(p), "small", { bold = true, width = width }))
  if p.per_week_text then
    table.insert(body, text(_(p.per_week_text), "small", { grey = true, width = width }))
  end

  local tappable = on_tap and TapRow:new { callback = on_tap, viewport = viewport, body } or body
  local out = VerticalGroup:new { align = "left" }
  table.insert(out, Theme.rule(width, false))
  table.insert(out, Theme.span("m"))
  table.insert(out, tappable)
  table.insert(out, Theme.span("m"))
  out.text = goal.name
  return out
end

--
-- The card on the home screen: a "Goals ›" heading that opens the Goals screen, and
-- under it the chosen goal (opens that goal).
--
function GoalWidgets.homeCard(goal, p, width, viewport, on_goal, on_all)
  local out = VerticalGroup:new { align = "left" }
  local more = text("\226\128\186", "title", { bold = true })
  table.insert(out, TapRow:new {
    callback = on_all,
    viewport = viewport,
    Theme.sectionHeader(_("Goals"), width, more),
  })
  table.insert(out, Theme.span("s"))

  local body = VerticalGroup:new { align = "left" }
  table.insert(body, text(goal.name, "body", { bold = true, width = width }))
  table.insert(body, Theme.span("xs"))
  local line = HorizontalGroup:new {
    align = "bottom",
    text(string.format("%d", p.progress), "display", { bold = true }),
    Theme.hspan("s"),
    text(string.format(_("/ %d %s  \194\183  %s"), p.target, p.unit, _(p.status)), "body", { width = width }),
  }
  table.insert(body, line)
  table.insert(body, Theme.span("s"))
  table.insert(body, GoalWidgets.bar(width, Screen:scaleBySize(14), p))
  table.insert(body, Theme.span("xs"))
  local small = Goals.leftText(p)
  if p.extra and p.extra > 0 then
    small = string.format(_("+%d finished offline"), p.extra) .. (small ~= "" and ("  \194\183  " .. small) or "")
  end
  if small ~= "" then table.insert(body, text(small, "small", { grey = true, width = width })) end

  table.insert(out, TapRow:new { callback = on_goal, viewport = viewport, body })
  return out
end

--
-- The card when there is no current goal to show (none made, none running, or they
-- have not loaded): the same "Goals ›" heading, and a line saying where to go. The
-- Goals screen is where a goal is made.
--
function GoalWidgets.homeEmpty(width, viewport, on_all)
  local out = VerticalGroup:new { align = "left" }
  local more = text("\226\128\186", "title", { bold = true })
  table.insert(out, TapRow:new {
    callback = on_all,
    viewport = viewport,
    Theme.sectionHeader(_("Goals"), width, more),
  })
  table.insert(out, Theme.span("s"))
  table.insert(out, TapRow:new {
    callback = on_all,
    viewport = viewport,
    text(_("No current goal. Tap to see your goals or set a new one."), "small", { grey = true, width = width }),
  })
  return out
end

return GoalWidgets
