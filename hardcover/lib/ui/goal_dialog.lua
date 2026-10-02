-- One goal, big: the number and how you stand, you against where you should be today,
-- and what finishing takes. Reached from the Goals screen or the home screen's card.
-- Worked out on the device from the saved goal and the date (see goals_dialog.lua).

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local GoalWidgets = require("hardcover/lib/ui/goal_widgets")
local Goals = require("hardcover/lib/goals")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen
local text = GoalWidgets.text

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

  table.insert(c, text(Goals.datesText(goal), "small", { grey = true, width = width }))
  table.insert(c, Theme.span("s"))
  table.insert(c, GoalWidgets.figure(p))
  table.insert(c, Theme.span("s"))
  table.insert(c, Theme.pill(_(p.status), { filled = true, size = "body" }))
  table.insert(c, Theme.span("l"))

  if not p.upcoming then
    table.insert(c, Theme.sectionHeader(_("You, and where you should be"), width))
    table.insert(c, Theme.span("m"))
    table.insert(c, text(_("You"), "small", { bold = true }))
    table.insert(c, ProgressWidget:new { width = width, height = Screen:scaleBySize(20), percentage = p.fraction })
    if not p.over then
      table.insert(c, Theme.span("m"))
      table.insert(c, text(_("Pace for today"), "small", { bold = true }))
      table.insert(c, ProgressWidget:new { width = width, height = Screen:scaleBySize(20), percentage = p.pace_fraction })
    end
    table.insert(c, Theme.span("l"))
  end

  if not p.done and not p.over and p.per_week_text then
    table.insert(c, Theme.sectionHeader(_("To finish"), width))
    table.insert(c, Theme.span("m"))
    local left = math.ceil(p.target - p.progress)
    table.insert(c, text(string.format(_("%d %s left in %d days"), left, p.unit, p.days_left), "title", { bold = true, width = width }))
    table.insert(c, text(_(p.per_week_text), "body", { grey = true, width = width }))
    table.insert(c, Theme.span("l"))
  elseif p.done then
    table.insert(c, text(_("You reached this goal."), "body", { grey = true, width = width }))
    table.insert(c, Theme.span("l"))
  end

  if self.edit_cb then
    table.insert(c, Theme.button(_("Edit goal"), width, {
      size = "body", viewport = viewport,
      callback = function() self.edit_cb(goal) end,
    }))
    table.insert(c, Theme.span("l"))
  end
  return c
end

function GoalDialog:build()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local title_bar = Theme.titleBar {
    title = self.goal.name,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }
  local room = screen_h - title_bar:getSize().h
  local width = screen_w - 2 * M
  local content = self:buildContent(width, nil)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    local gutter = 3 * (ScrollableContainer.scroll_bar_width or Screen:scaleBySize(6))
    width = screen_w - 2 * M - gutter
    self.scroll = ScrollableContainer:new { dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room }, show_parent = self }
    local scroll = self.scroll
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), self:buildContent(width, function() return scroll.dimen end) }
    body = scroll
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
