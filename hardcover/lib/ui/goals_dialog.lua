-- Your reading goals, in two tabs: Current as cards (a big number, a bar with a tick where you
-- should be today, a chip for how you stand, what finishing takes), Past as plain rows. Choosing a goal opens it (ui/goal_dialog.lua).
--
-- Everything on it is worked out on the device from the saved goals and the date, so
-- it reads the same offline; `note` says when what is shown is a saved copy. A page
-- that is taller than the screen scrolls, with every tap clipped to what the scroll
-- area shows (see viewport.lua).

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local GoalWidgets = require("hardcover/lib/ui/goal_widgets")
local Goals = require("hardcover/lib/goals")
local Hosted = require("hardcover/lib/ui/hosted")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Tabs = require("hardcover/lib/ui/components/tabs")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local text = Theme.text

local GoalsDialog = InputContainer:extend {
  name = "hardcover_goals",
  title = nil,
  goals = nil,            -- Goals.normalize rows; nil while loading
  today = nil,            -- days (Goals.today())
  finished_offline = 0,   -- books finished here and not yet counted by Hardcover
  note = nil,             -- "Offline. Showing your goals as of ..."
  message = nil,          -- shown instead of the goals
  open_cb = nil,          -- called with the chosen goal
  new_cb = nil,           -- the "New goal" button appears when this is set (not in the shell: its top bar has +)
  close_callback = nil,
  -- as a tab of the shell (see hosted.lua): the shell, and the size it gives this body
  shell = nil,
  width = nil,
  height = nil,
}

function GoalsDialog:init()
  self.title = self.title or _("Goals")
  self.today = self.today or Goals.today()
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  if not self.shell then self.key_events.CloseGoals = { { "Back" } } end
  self:build()
end

function GoalsDialog:pace(goal)
  return Goals.pace(goal, self.today, Goals.extra(goal, self.today, self.finished_offline))
end

-- a past goal: its name and where it ended
function GoalsDialog:pastRow(goal, width, viewport)
  local p = self:pace(goal)
  local right = Theme.mmdText(string.format("%d / %d", p.progress, p.target), "strong", 18)
  local name = Theme.mmdText(goal.name, "strong", 18, { width = width - right:getSize().w - Theme.space.l })
  local gap = math.max(0, width - name:getSize().w - right:getSize().w)
  local body = VerticalGroup:new {
    align = "left",
    HorizontalGroup:new { align = "center", name, Theme.hspan(gap), right },
    Theme.mmdText(p.done and _("Reached") or _(p.status), "text", 15, { secondary = true }),
  }
  return VerticalGroup:new {
    align = "left",
    Theme.span("s"),
    TapRow:new {
      callback = function() if self.open_cb then self.open_cb(goal) end end,
      viewport = viewport,
      body,
    },
    Theme.span("s"),
    Theme.dottedRule(width),
  }
end

-- the goals of one tab: Current is what runs now, Past is what has ended
function GoalsDialog:shown()
  local split = Goals.split(self.goals or {}, self.today)
  if self.tab == nil then self.tab = (#split.current == 0 and #split.past > 0) and "past" or "current" end
  return self.tab, split
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

  local tab, split = self:shown()
  local list = split[tab]
  if #list == 0 then
    table.insert(content, text(tab == "past" and _("No past goals.") or _("No current goals."), "body", { grey = true, width = width }))
  elseif tab == "current" then
    for _i, goal in ipairs(list) do
      table.insert(content, GoalWidgets.card(goal, self:pace(goal), width, viewport,
        function() if self.open_cb then self.open_cb(goal) end end))
    end
  else
    for _i, goal in ipairs(list) do
      table.insert(content, self:pastRow(goal, width, viewport))
    end
  end

  -- in the shell the top bar's + does this
  if self.new_cb and not self.shell and tab == "current" then
    table.insert(content, Theme.span("m"))
    self.new_button = Button.new {
      label = _("New goal"), w = width, h = Theme.px(56), size = 21, viewport = viewport,
      callback = function() self.new_cb() end,
    }
    table.insert(content, self.new_button)
  end
  table.insert(content, Theme.span("l"))
  return content
end

-- Current | Past, with how many each holds; none while there is nothing to tell apart
function GoalsDialog:buildTabs(width)
  if self.message or not self.goals or #self.goals == 0 then return nil end
  local tab, split = self:shown()
  local function pick(id)
    return function()
      if self.tab == id then return end
      self.tab = id
      self:rebuild()
    end
  end
  return Tabs.new {
    width = width,
    tabs = {
      { label = _("Current"), count = #split.current, active = tab == "current", callback = pick("current") },
      { label = _("Past"), count = #split.past, active = tab == "past", callback = pick("past") },
    },
  }
end

function GoalsDialog:build()
  local screen_w, screen_h = Hosted.size(self)
  local M = Theme.margin
  -- on its own it has a top bar with a back arrow; in the shell the shell has the bar
  local head = VerticalGroup:new { align = "left" }
  local bar
  if not self.shell then
    bar = TopBar.new {
      width = screen_w, title = self.title, on_back = function() self:onClose() end,
      actions = self.new_cb and { { icon = "plus", callback = function() self.new_cb() end } } or nil,
    }
    table.insert(head, bar)
  end
  self.tabs = self:buildTabs(screen_w)
  if self.tabs then table.insert(head, self.tabs) end
  local room = screen_h - head:getSize().h

  local width = screen_w - 2 * M
  local content = self:buildContent(width, nil)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    local gutter = ScrollControl.gutter()
    width = screen_w - 2 * M - gutter
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = Hosted.window(self),
    }
    local scroll = self.scroll
    content = self:buildContent(width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
    body = ScrollControl.wrap(scroll, content)
  else
    body = HorizontalGroup:new { Theme.hspan(M), content }
  end

  self.title_bar = bar
  self.close_button = bar and bar.back_button or nil
  self.frame = FrameContainer:new {
    width = screen_w, height = screen_h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", head, body },
  }
  self[1] = self.frame
end

function GoalsDialog:rebuild()
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  Hosted.dirty(self)
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
  if not self.shell then UIManager:setDirty(nil, "ui") end
end

function GoalsDialog:onCloseGoals()
  return self:onClose()
end

function GoalsDialog:onClose()
  if self.shell then return true end -- the shell leaves, not a tab
  UIManager:close(self)
  if self.close_callback then self.close_callback() end
  return true
end

return GoalsDialog
