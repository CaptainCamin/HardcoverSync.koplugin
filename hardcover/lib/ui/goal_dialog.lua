-- One goal, big: the number and how you stand, you against where you should be today,
-- and what finishing takes. Reached from the Goals screen or the home screen's card.
-- Worked out on the device from the saved goal and the date (see goals_dialog.lua).

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local GoalWidgets = require("hardcover/lib/ui/goal_widgets")
local Goals = require("hardcover/lib/goals")
local ProgressBar = require("hardcover/lib/ui/components/progress_bar")
local Section = require("hardcover/lib/ui/components/section")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

local GoalDialog = InputContainer:extend {
  name = "hardcover_goal",
  goal = nil,             -- a Goals.normalize row
  today = nil,
  finished_offline = 0,
  note = nil,
  edit_cb = nil,          -- the "Edit goal" button appears when this is set
  close_callback = nil,
}

function GoalDialog:init()
  self.today = self.today or Goals.today()
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.CloseGoal = { { "Back" } }
  self:build()
end

function GoalDialog:buildContent(width, viewport)
  local goal = self.goal
  local p = Goals.pace(goal, self.today, Goals.extra(goal, self.today, self.finished_offline))
  local c = VerticalGroup:new { align = "left" }
  table.insert(c, Theme.span("m"))

  if self.note then
    table.insert(c, FrameContainer:new {
      bordersize = Theme.line.hair, color = Theme.DARK_GREY, radius = Theme.px(8),
      padding = Theme.space.s, margin = 0, background = Blitbuffer.COLOR_WHITE,
      TextBoxWidget:new { text = self.note, face = Theme.face("small"), width = width - 2 * Theme.space.s - 2 * Theme.line.hair },
    })
    table.insert(c, Theme.span("m"))
  end

  table.insert(c, Theme.mmdText(Goals.datesText(goal), "text", 15, { secondary = true, width = width }))
  table.insert(c, Theme.span("s"))
  table.insert(c, GoalWidgets.figure(p, width))
  table.insert(c, Theme.span("s"))
  table.insert(c, GoalWidgets.standing(p, width))
  table.insert(c, Theme.span("m"))

  if not p.upcoming then
    local b = Section.new(_("You, and where you should be"), width)
    table.insert(b, Theme.mmdText(_("You"), "strong", 15))
    table.insert(b, Theme.span("xs"))
    table.insert(b, ProgressBar.new { width = width, fraction = p.fraction })
    if not p.over then
      table.insert(b, Theme.span("m"))
      table.insert(b, Theme.mmdText(_("Pace for today"), "strong", 15))
      table.insert(b, Theme.span("xs"))
      table.insert(b, ProgressBar.new { width = width, fraction = p.pace_fraction })
    end
    table.insert(b, Theme.span("m"))
    table.insert(c, b)
  end

  if not p.done and not p.over and p.per_week_text then
    local b = Section.new(_("To finish"), width)
    local left = math.ceil(p.target - p.progress)
    table.insert(b, Theme.mmdText(string.format(_("%d %s left in %d days"), left, p.unit, p.days_left), "strong", 21, { width = width }))
    table.insert(b, Theme.mmdText(_(p.per_week_text), "text", 18, { secondary = true, width = width }))
    table.insert(b, Theme.span("m"))
    table.insert(c, b)
  elseif p.done then
    local b = Section.new(nil, width)
    table.insert(b, Theme.mmdText(_("You reached this goal."), "text", 18, { secondary = true, width = width }))
    table.insert(b, Theme.span("m"))
    table.insert(c, b)
  end

  if self.edit_cb then
    table.insert(c, Theme.span("s"))
    self.edit_button = Button.new {
      label = _("Edit goal"), w = width, h = Theme.px(56), size = 21, viewport = viewport,
      callback = function() self.edit_cb(goal) end,
    }
    table.insert(c, self.edit_button)
    table.insert(c, Theme.span("l"))
  end
  return c
end

function GoalDialog:build()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local title_bar = TopBar.new { width = screen_w, title = self.goal.name, on_back = function() self:onClose() end }
  local room = screen_h - title_bar:getSize().h
  local width = screen_w - 2 * M
  local content = self:buildContent(width, nil)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    local gutter = ScrollControl.gutter()
    width = screen_w - 2 * M - gutter
    self.scroll = ScrollableContainer:new { dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room }, show_parent = self }
    local scroll = self.scroll
    local rows = self:buildContent(width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), rows }
    body = ScrollControl.wrap(scroll, rows)
  else
    body = HorizontalGroup:new { Theme.hspan(M), content }
  end
  self.title_bar = title_bar
  self.frame = FrameContainer:new {
    width = screen_w, height = screen_h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", title_bar, body },
  }
  self[1] = self.frame
end

-- the goal was changed: show it as it is now
function GoalDialog:setGoal(goal)
  self.goal = goal
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  UIManager:setDirty(self, "ui")
end

function GoalDialog:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

function GoalDialog:onCloseGoal()
  return self:onClose()
end

function GoalDialog:onClose()
  UIManager:close(self)
  if self.close_callback then self.close_callback() end
  return true
end

return GoalDialog
