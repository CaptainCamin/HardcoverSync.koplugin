-- Your reading goals: the ones running now as cards (a big number, a bar with a tick
-- where you should be today, how far ahead or behind, what finishing takes), then
-- past goals as plain rows. Choosing a goal opens it (ui/goal_dialog.lua).
--
-- Everything on it is worked out on the device from the saved goals and the date, so
-- it reads the same offline; `note` says when what is shown is a saved copy. A page
-- that is taller than the screen scrolls, with every tap clipped to what the scroll
-- area shows (see viewport.lua).

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local GoalWidgets = require("hardcover/lib/ui/goal_widgets")
local Goals = require("hardcover/lib/goals")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen
local text = GoalWidgets.text

local GoalsDialog = InputContainer:extend {
  name = "hardcover_goals",
  title = nil,
  goals = nil,            -- Goals.normalize rows; nil while loading
  today = nil,            -- days (Goals.today())
  finished_offline = 0,   -- books finished here and not yet counted by Hardcover
  note = nil,             -- "Offline. Showing your goals as of ..."
  message = nil,          -- shown instead of the goals
  open_cb = nil,          -- called with the chosen goal
  close_callback = nil,
}

function GoalsDialog:init()
  self.title = self.title or _("Goals")
  self.today = self.today or Goals.today()
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.CloseGoals = { { "Back" } }
  self:build()
end

function GoalsDialog:pace(goal)
  return Goals.pace(goal, self.today, Goals.extra(goal, self.today, self.finished_offline))
end

-- a past goal: its name and where it ended
function GoalsDialog:pastRow(goal, width, viewport)
  local p = self:pace(goal)
  local right = text(string.format("%d / %d", p.progress, p.target), "title", { bold = true })
  local name = text(goal.name, "body", { bold = true, width = width - right:getSize().w - Theme.space.l })
  local gap = math.max(0, width - name:getSize().w - right:getSize().w)
  local body = VerticalGroup:new {
    align = "left",
    HorizontalGroup:new { align = "center", name, Theme.hspan(gap), right },
    text(p.done and _("Reached") or _(p.status), "small", { grey = true }),
  }
  return VerticalGroup:new {
    align = "left",
    Theme.rule(width, false),
    Theme.span("s"),
    TapRow:new {
      callback = function() if self.open_cb then self.open_cb(goal) end end,
      viewport = viewport,
      body,
    },
    Theme.span("s"),
  }
end

function GoalsDialog:buildContent(width, viewport)
  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("m"))

  if self.note then
    table.insert(content, FrameContainer:new {
      bordersize = Theme.line.hair, color = Theme.DARK_GREY, radius = Theme.px(8),
      padding = Theme.space.s, margin = 0, background = Blitbuffer.COLOR_WHITE,
      TextBoxWidget:new { text = self.note, face = Theme.face("small"), width = width - 2 * Theme.space.s - 2 * Theme.line.hair },
    })
    table.insert(content, Theme.span("m"))
  end

  if self.message then
    table.insert(content, text(self.message, "body", { grey = true, width = width }))
    return content
  end

  local split = Goals.split(self.goals or {}, self.today)
  if #split.current > 0 then
    table.insert(content, Theme.sectionHeader(_("Current"), width, text(tostring(#split.current), "small", { grey = true })))
    table.insert(content, Theme.span("s"))
    for _i, goal in ipairs(split.current) do
      table.insert(content, GoalWidgets.card(goal, self:pace(goal), width, viewport,
        function() if self.open_cb then self.open_cb(goal) end end))
    end
    table.insert(content, Theme.span("m"))
  end
  if #split.past > 0 then
    table.insert(content, Theme.sectionHeader(_("Past goals"), width, text(tostring(#split.past), "small", { grey = true })))
    table.insert(content, Theme.span("s"))
    for _i, goal in ipairs(split.past) do
      table.insert(content, self:pastRow(goal, width, viewport))
    end
    table.insert(content, Theme.span("l"))
  end
  return content
end

function GoalsDialog:build()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local title_bar = Theme.titleBar {
    title = self.title,
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
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = self,
    }
    local scroll = self.scroll
    content = self:buildContent(width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
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

function GoalsDialog:rebuild()
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  UIManager:setDirty(self, "ui")
end

-- fresh (or saved) goals have arrived
function GoalsDialog:setGoals(goals, note, finished_offline)
  self.goals, self.note, self.message = goals, note, nil
  if finished_offline then self.finished_offline = finished_offline end
  if goals and #goals == 0 then
    self.message = _("No goals yet. Set one on hardcover.app and it will show up here.")
  end
  self:rebuild()
end

function GoalsDialog:setMessage(message, note)
  self.message, self.note = message, note
  self:rebuild()
end

function GoalsDialog:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

function GoalsDialog:onCloseGoals()
  return self:onClose()
end

function GoalsDialog:onClose()
  UIManager:close(self)
  if self.close_callback then self.close_callback() end
  return true
end

return GoalsDialog
