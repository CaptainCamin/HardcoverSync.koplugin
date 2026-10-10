-- The pieces the goal screens share: the progress bar with a tick where you should
-- be today, a goal's big number, and the cards built from them. What each says comes
-- from Goals.pace; this only lays it out.

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Goals = require("hardcover/lib/goals")
local ProgressBar = require("hardcover/lib/ui/components/progress_bar")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local GoalWidgets = {}

local text = Theme.text

-- The bar (components/progress_bar.lua); a tick marks where you should be today, except on a goal
-- that is done, over, or not started (no "should be" to point at).
function GoalWidgets.bar(width, _height, p, no_tick)
  local tick = not (no_tick or p.over or p.done or p.upcoming)
  return ProgressBar.new {
    width = width,
    fraction = p.fraction,
    tick = tick and p.pace_fraction or nil,
  }
end

-- "46" big, "of 70 books" beside it, a "+1 finished offline" pill when a book finished
-- here has not been counted by Hardcover yet, and a "Waiting to sync" pill when the
-- goal itself was changed here and not sent
function GoalWidgets.figure(p, width)
  local row = HorizontalGroup:new {
    align = "bottom",
    Theme.mmdText(string.format("%d", p.progress), "strong", 44),
    Theme.hspan("s"),
    Theme.mmdText(string.format(_("of %d %s"), p.target, p.unit), "text", 21, { secondary = true }),
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

-- The chip and the words beside it ("On track" "3 books ahead  ·  20 days left"): side by side when
-- they fit, the words under the chip when they do not.
function GoalWidgets.standing(p, width)
  local label, filled = Goals.chip(p)
  local chip = FrameContainer:new {
    bordersize = Theme.line.firm, radius = Theme.px(18), color = Theme.BLACK,
    background = filled and Theme.BLACK or Theme.WHITE,
    padding = Theme.px(4), padding_left = Theme.px(14), padding_right = Theme.px(14), margin = 0,
    Theme.mmdText(_(label), "strong", 18, { color = filled and Theme.WHITE or Theme.BLACK }),
  }
  local line = Goals.paceText(p)
  if not line then return chip end
  local gap = Theme.space.m
  local room = width - chip:getSize().w - gap
  local words = Theme.mmdText(_(line), "text", 18, { secondary = true, width = math.max(room, width) })
  if words:getSize().w <= room then
    return HorizontalGroup:new { align = "center", chip, Theme.hspan(gap), words }
  end
  return VerticalGroup:new { align = "left", chip, Theme.span("xs"), words }
end

--
-- One goal as a card (mock 7): a firm outline around the name, the figure, the bar, the chip with
-- how you stand, and what finishing takes. Tappable when `on_tap` is given (it opens the goal).
--
function GoalWidgets.card(goal, p, width, viewport, on_tap)
  local border, pad = Theme.px(3), Theme.px(14)
  local inner = width - 2 * (border + pad)
  local body = VerticalGroup:new { align = "left" }
  table.insert(body, Theme.mmdText(goal.name, "strong", 21, { width = inner }))
  table.insert(body, Theme.span("xs"))
  table.insert(body, GoalWidgets.figure(p, inner))
  table.insert(body, Theme.span("s"))
  table.insert(body, GoalWidgets.bar(inner, nil, p))
  table.insert(body, Theme.span("s"))
  table.insert(body, GoalWidgets.standing(p, inner))
  if p.per_week_text then
    table.insert(body, Theme.span("xs"))
    table.insert(body, Theme.mmdText(_(p.per_week_text), "text", 18, { secondary = true, width = inner }))
  end

  local framed = FrameContainer:new {
    bordersize = border, radius = Theme.px(12), color = Theme.BLACK, background = Theme.WHITE,
    padding = pad, margin = 0, width = width,
    body,
  }
  local tappable = on_tap and TapRow:new { callback = on_tap, viewport = viewport, framed } or framed
  local out = VerticalGroup:new { align = "left", tappable, Theme.span("m") }
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
