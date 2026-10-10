-- Making a goal, or changing one: a form of five rows (name, what is counted, the
-- target, the period, who can see it), a Save button, and for an existing goal an
-- Archive button.
--
-- A row shows what it holds and opens the widget that changes it (a text box, a list
-- of choices, a date picker). The values live in `self.form` (see Goals.validate and
-- Goals.input for the rules); Save checks them and hands the form to `on_save`, which
-- sends it. The form stays open until the save has gone through, so a failure (no
-- connection, a refusal) keeps what was typed, with the reason shown at the top.

local Blitbuffer = require("ffi/blitbuffer")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Goals = require("hardcover/lib/goals")
local Button = require("hardcover/lib/ui/components/button")
local Draw = require("hardcover/lib/ui/components/draw")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Picker = require("hardcover/lib/ui/picker")
local TopBar = require("hardcover/lib/ui/components/top_bar")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local CHEVRON = "\226\128\186"

local GoalFormDialog = InputContainer:extend {
  name = "hardcover_goal_form",
  goal = nil,        -- the goal being changed (Goals.normalize row), nil for a new one
  today = nil,       -- days
  on_save = nil,     -- called with a copy of the form once it passes Goals.validate
  on_archive = nil,  -- called to archive the goal (only offered for an existing one)
  close_callback = nil,
}

function GoalFormDialog:init()
  self.today = self.today or Goals.today()
  self.form = self.goal and Goals.formFrom(self.goal) or Goals.newForm(self.today)
  -- what it was when it opened, to know whether anything was changed
  self.original = {}
  for k, v in pairs(self.form) do self.original[k] = v end
  self.message = nil
  self.busy = false
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.CloseForm = { { "Back" } }
  self:build()
end

local text = Theme.text

-- has anything been changed since the form opened?
function GoalFormDialog:dirty()
  for _i, key in ipairs({ "name", "metric", "target", "start_date", "end_date", "privacy_setting_id" }) do
    if tostring(self.form[key]) ~= tostring(self.original[key]) then return true end
  end
  return false
end

-- what each row shows
function GoalFormDialog:rows()
  local f = self.form
  local target = tonumber(f.target)
  local unit = f.metric == "page" and _("pages") or _("books")
  return {
    { key = "name", label = _("Name"), value = f.name ~= "" and f.name or _("Not set"), edit = function() self:editName() end },
    { key = "metric", label = _("Counting"), value = _(Goals.metricLabel(f.metric)), edit = function() self:pickMetric() end },
    { key = "target", label = _("Target"),
      value = target and string.format("%d %s", target, unit) or tostring(f.target or ""),
      edit = function() self:editTarget() end },
    { key = "period", label = _("Period"), value = Goals.periodText(f.start_date, f.end_date), edit = function() self:pickPeriod() end },
    { key = "privacy", label = _("Visible to"),
      value = f.privacy_setting_id and _(Goals.privacyLabel(f.privacy_setting_id) or "") or _("Same as your account"),
      edit = function() self:pickPrivacy() end },
  }
end

-- One field as a list row: its name over what it holds, a chevron, a dotted divider under it.
function GoalFormDialog:buildRow(row, width, viewport, last)
  local item = ListItem.new {
    width = width, label = row.label, support = row.value, trailing = Draw.chevron("right"),
    divider = (not last) and "dotted" or nil, viewport = viewport,
    callback = function() if not self.busy then row.edit() end end,
  }
  item.text = row.label
  self.row_taps[row.key] = item
  return item
end

function GoalFormDialog:buildContent(width, viewport)
  self.row_taps = {}
  local c = VerticalGroup:new { align = "left" }
  table.insert(c, Theme.span("s"))

  if self.message then
    -- the reason, whole: it can be a sentence long
    local face, bold = Theme.mmdFace("text", 18)
    table.insert(c, Theme.mmdText(_("Not saved"), "strong", 21, { width = width }))
    table.insert(c, Theme.span(Theme.px(4)))
    table.insert(c, TextBoxWidget:new { text = self.message, face = face, bold = bold, width = width,
      fgcolor = Theme.secondary() })
    table.insert(c, Theme.span("s"))
    table.insert(c, Theme.dottedRule(width))
  end

  local rows = self:rows()
  for i, row in ipairs(rows) do
    table.insert(c, self:buildRow(row, width, viewport, i == #rows))
  end
  table.insert(c, Theme.span("l"))

  self.save_button = Button.new { label = self.busy and _("Saving\226\128\166") or _("Save"), w = width,
    primary = true, viewport = viewport, enabled = not self.busy,
    callback = (not self.busy) and function() self:save() end or nil }
  table.insert(c, self.save_button)

  if self.goal and self.on_archive then
    table.insert(c, Theme.span(Theme.px(16)))
    self.archive_button = Button.new { label = _("Archive this goal"), w = width, viewport = viewport,
      enabled = not self.busy, callback = (not self.busy) and function() self:archive() end or nil }
    table.insert(c, self.archive_button)
    table.insert(c, Theme.span("xs"))
    table.insert(c, Theme.mmdText(_("It stays on Hardcover, hidden. Bring it back from the website."), "text", 18,
      { secondary = true, width = width }))
  end
  table.insert(c, Theme.span("l"))
  return c
end

function GoalFormDialog:build()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  -- the back arrow is Cancel (it asks first when something was changed)
  local title_bar = TopBar.new { width = screen_w, title = self.goal and _("Edit goal") or _("New goal"),
    on_back = function() self:cancel() end }
  local room = screen_h - title_bar:getSize().h

  local width = screen_w - 2 * M
  local content = self:buildContent(width, nil)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    local gutter = ScrollControl.gutter()
    width = screen_w - 2 * M - gutter
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = self,
    }
    local scroll = self.scroll
    content = self:buildContent(width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
    body = ScrollControl.wrap(scroll, content)
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

function GoalFormDialog:rebuild()
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  UIManager:setDirty(self, "ui")
end

-- ----------------------------------------------------------------- editing

function GoalFormDialog:change(key, value)
  self.form[key] = value
  self.message = nil
  self:rebuild()
end

function GoalFormDialog:editName()
  local input
  input = InputDialog:new {
    title = _("Goal name"),
    input = self.form.name or "",
    buttons = { {
      { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
      { text = _("Set"), is_enter_default = true, callback = function()
          local value = input:getInputText()
          UIManager:close(input)
          self:change("name", value)
        end },
    } },
  }
  UIManager:show(input)
  if input.onShowKeyboard then input:onShowKeyboard() end
end

function GoalFormDialog:editTarget()
  local input
  input = InputDialog:new {
    title = self.form.metric == "page" and _("Pages to read") or _("Books to read"),
    input = tostring(self.form.target or ""),
    input_type = "number",
    buttons = { {
      { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
      { text = _("Set"), is_enter_default = true, callback = function()
          local raw = input:getInputText()
          UIManager:close(input)
          -- kept as typed when it is not a number, so Save can say what is wrong
          self:change("target", tonumber(raw) or raw)
        end },
    } },
  }
  UIManager:show(input)
  if input.onShowKeyboard then input:onShowKeyboard() end
end

-- a choose-one list; `choices` is { { text, value, current } }
function GoalFormDialog:choose(title, choices, on_choose)
  local picker
  local rows = {}
  for _i, choice in ipairs(choices) do
    rows[#rows + 1] = {
      text = choice.text,
      current = choice.current and true or false,
      callback = function()
        UIManager:close(picker)
        on_choose(choice.value)
      end,
    }
  end
  picker = Picker.new { title = title, rows = rows }
  UIManager:show(picker)
  return picker
end

function GoalFormDialog:pickMetric()
  local choices = {}
  for _i, m in ipairs(Goals.METRICS) do
    choices[#choices + 1] = { text = _(m.label), value = m.key, current = self.form.metric == m.key }
  end
  self:choose(_("Count"), choices, function(key) self:change("metric", key) end)
end

function GoalFormDialog:pickPrivacy()
  local choices = {}
  -- a new goal can leave it to the account's own setting; an existing one has its own
  if not self.goal or self.goal.privacy_setting_id == nil then
    choices[#choices + 1] = { text = _("Same as your account"), value = false, current = self.form.privacy_setting_id == nil }
  end
  for _i, p in ipairs(Goals.PRIVACY) do
    choices[#choices + 1] = { text = _(p.label), value = p.id, current = self.form.privacy_setting_id == p.id }
  end
  self:choose(_("Who can see this goal"), choices, function(value)
    self:change("privacy_setting_id", value or nil)
  end)
end

-- Choosing a period: a preset (which also names the goal, if the name was still the
-- last preset's), or two dates.
function GoalFormDialog:pickPeriod()
  local presets = Goals.presets(self.today)
  local choices = {}
  for _i, p in ipairs(presets) do
    choices[#choices + 1] = { text = p.label, value = p,
      current = self.form.start_date == p.start_date and self.form.end_date == p.end_date }
  end
  choices[#choices + 1] = { text = _("Choose dates\226\128\166"), value = "custom" }
  self:choose(_("Period"), choices, function(value)
    if value == "custom" then
      self:pickDates()
      return
    end
    -- the name follows the period while it is still a name a preset would give
    local auto = false
    for _i, p in ipairs(presets) do
      if self.form.name == p.name then auto = true end
    end
    self.form.start_date, self.form.end_date = value.start_date, value.end_date
    if auto or self.form.name == "" then self.form.name = value.name end
    self.message = nil
    self:rebuild()
  end)
end

-- two date pickers: the first day, then the last day (the stored end is the day after)
function GoalFormDialog:pickDates()
  local function show(title, days, done)
    local y, m, d = Goals.civil(days)
    UIManager:show(DateTimeWidget:new {
      year = y, month = m, day = d,
      ok_text = _("Set date"),
      title_text = title,
      callback = function(t)
        done(Goals.days(t.year, t.month, t.day))
      end,
    })
  end
  local start_days = Goals.parseDate(self.form.start_date) or self.today
  local end_days = Goals.parseDate(self.form.end_date) or (start_days + 365)
  show(_("First day"), start_days, function(first)
    local last_default = math.max(first, end_days - 1)
    show(_("Last day"), last_default, function(last)
      self.form.start_date = Goals.dateString(first)
      self.form.end_date = Goals.dateString(last + 1)
      self.message = nil
      self:rebuild()
    end)
  end)
end

-- ----------------------------------------------------------------- actions

function GoalFormDialog:save()
  if self.busy then return end
  local problem = Goals.validate(self.form)
  if problem then
    self.message = problem
    self:rebuild()
    return
  end
  self.message = nil
  if self.on_save then
    local copy = {}
    for k, v in pairs(self.form) do copy[k] = v end
    self.on_save(copy)
  end
end

function GoalFormDialog:archive()
  if self.busy then return end
  StatusDialogs.confirm {
    title = _("Archive this goal?"),
    text = _("It stays on Hardcover, hidden, and you can bring it back from the website."),
    ok_text = _("Archive"),
    ok_callback = function()
      if self.on_archive then self.on_archive() end
    end,
  }
end

-- the manager shows the progress of a save, and what went wrong
function GoalFormDialog:setBusy(busy)
  self.busy = busy and true or false
  self:rebuild()
end

function GoalFormDialog:setMessage(message)
  self.message = message
  self:rebuild()
end

function GoalFormDialog:cancel()
  if self.busy then return true end
  if not self:dirty() then return self:onClose() end
  StatusDialogs.confirm {
    title = _("Discard your changes?"),
    ok_text = _("Discard"),
    cancel_text = _("Keep editing"),
    ok_callback = function() self:onClose() end,
  }
  return true
end

function GoalFormDialog:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

function GoalFormDialog:onCloseForm()
  return self:cancel()
end

function GoalFormDialog:onClose()
  UIManager:close(self)
  if self.close_callback then self.close_callback() end
  return true
end

return GoalFormDialog
