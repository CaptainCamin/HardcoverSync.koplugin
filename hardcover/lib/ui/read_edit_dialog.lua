-- One read's dates and edition, as a form: Started, Finished (with Day/Month/Year precision), and
-- the edition it was in. Save writes only what changed; a sentence under the row it is about says
-- why Save is not available. The read in progress has no finish: "Still reading" is its state.
--
--   ReadEditDialog:new {
--     book = { title = "...", pages = 304, edition_format = "Paperback" },
--     read = detail.reads[1], today = "2026-11-15",
--     on_save = function(change, clear) ... end, on_close = function() ... end,
--   }
--
-- The caller sends `change` (only the fields that differ) and `clear` (fields to remove, as
-- json.util.null) through the read queue. Nothing here calls the API or the queue.
--
-- Built on goal_form_dialog's layout: a top bar, one row per value, the change it will write above
-- the buttons, a filled Save and an outlined Cancel. Dates use components/date_picker.lua.

local DatePicker = require("hardcover/lib/ui/components/date_picker")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local Draw = require("hardcover/lib/ui/components/draw")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Picker = require("hardcover/lib/ui/picker")
local ReadHistory = require("hardcover/lib/read_history")
local StepperDialog = require("hardcover/lib/ui/components/stepper_dialog")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

local ReadEditDialog = InputContainer:extend {
  name = "hardcover_read_edit",
  book = nil,
  read = nil,
  adding = false,  -- an empty form for a past read; Finished is required
  default_edition = nil, -- the edition preselected on an addition
  on_remove = nil, -- function(read) after Remove this read is confirmed
  on_abandon = nil, -- function(read) after Abandon reread is confirmed
  today = nil,     -- YYYY-MM-DD, for a test; the device's day otherwise
  -- function(current_edition_id, callback) that shows the edition picker and calls back with the
  -- chosen edition (the normalized row: edition_id, pages, edition_format, reading_format_id)
  choose_edition = nil,
  -- an offline fallback: editions already saved on the device
  editions = nil,
  on_save = nil,   -- function(change, clear, chosen_edition)
  on_close = nil,
}

local PRECISION = { { label = _("Day"), value = 1 }, { label = _("Month"), value = 2 },
  { label = _("Year"), value = 3 } }

local function copyFields(fields)
  local out = {}
  for key, value in pairs(fields) do out[key] = value end
  return out
end

local function dateParts(value)
  local year, month, day = tostring(value or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  return tonumber(year), tonumber(month), tonumber(day)
end

local function precisionLabel(value)
  value = tonumber(value) or 1
  for _, choice in ipairs(PRECISION) do
    if choice.value == value then return choice.label end
  end
  return PRECISION[1].label
end

function ReadEditDialog:init()
  self.today = self.today or os.date("%Y-%m-%d")
  local read = self.read or {}
  self.original = copyFields {
    started_at = read.started_at,
    finished_at = read.finished_at,
    finished_at_precision = read.finished_at_precision,
    edition_id = read.edition_id or (self.default_edition and self.default_edition.edition_id),
    progress_pages = read.progress_pages,
    edition = read.edition or self.default_edition,
  }
  self.form = copyFields(self.original)
  if self.form.finished_at and not self.form.finished_at_precision then
    self.form.finished_at_precision = 1
  end
  self.busy = false
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.CloseReadEdit = { { "Back" } }
  self:build()
end

-- The read being corrected is still in progress: the form leaves out a finish entirely. A new
-- form (no read yet) is not "in progress": it is waiting for a finish.
function ReadEditDialog:inProgress()
  return not self.adding and self.read ~= nil and self.original.finished_at == nil
end

function ReadEditDialog:formProblem()
  if self.adding and not self.form.finished_at then
    return _("A finish date is required."), "finished_at"
  end
  return ReadHistory.validate(self.form, self.today)
end

function ReadEditDialog:editionPages()
  local edition = self.form and self.form.edition
  return (type(edition) == "table" and tonumber(edition.pages)) or tonumber((self.book or {}).pages)
end

function ReadEditDialog:editionText()
  local book = self.book or {}
  local edition = self.form and self.form.edition
  local format = ReadHistory.formatName({ edition = edition }, book.edition_format)
  local pages = (type(edition) == "table" and tonumber(edition.pages)) or tonumber(book.pages)
  if format and pages then return string.format(_("%s · %d pages"), format, pages) end
  if format then return format end
  if pages then return string.format(_("%d pages"), pages) end
  return _("Edition not recorded")
end

function ReadEditDialog:canChooseEdition()
  return self.choose_edition ~= nil or (type(self.editions) == "table" and #self.editions > 0)
end

function ReadEditDialog:pageText()
  local conversion = self.page_conversion
  if not conversion then return nil end
  if conversion.unknown then return _("The page could not be converted") end
  return string.format(_("%d of %d → %d of %d"), conversion.from, conversion.old_pages,
    tonumber(self.form.progress_pages) or conversion.to, conversion.new_pages)
end

function ReadEditDialog:rows()
  local rows = {
    { key = "started_at", label = _("Started"),
      value = self.form.started_at and ReadHistory.dateText(self.form.started_at, 1) or _("Not set"),
      edit = function() self:pickDate("started_at", _("Start date")) end },
  }
  if self:inProgress() then
    rows[#rows + 1] = { key = "status", label = _("Status"), value = _("Still reading"), static = true }
  else
    rows[#rows + 1] = { key = "finished_at", label = _("Finished"),
      value = self.form.finished_at and ReadHistory.dateText(self.form.finished_at,
        self.form.finished_at_precision) or _("Not set"),
      edit = function() self:pickDate("finished_at", _("Finish date")) end }
    rows[#rows + 1] = { key = "finished_at_precision", label = _("Finish precision"),
      value = precisionLabel(self.form.finished_at_precision),
      edit = function() self:pickPrecision() end }
  end
  rows[#rows + 1] = { key = "edition", label = _("Edition"), value = self:editionText(),
    static = not self:canChooseEdition(),
    edit = function() self:pickEdition() end }
  if self.page_conversion then
    rows[#rows + 1] = { key = "progress_pages", label = _("Page reached"),
      value = self:pageText(), edit = function() self:pickPage() end }
  end
  if self.read and not self:inProgress() and self.on_remove then
    rows[#rows + 1] = { key = "remove", label = self.read.pending_add and _("Discard this read")
      or _("Remove this read"), remove = true }
  end
  if self.read and self:inProgress() and self.on_abandon then
    rows[#rows + 1] = { key = "abandon", label = _("Abandon reread"), remove = true }
  end
  return rows
end

function ReadEditDialog:summaryLines()
  local change, clear = ReadHistory.diff(self.original, self.form)
  local lines = {}

  if clear.started_at then
    lines[#lines + 1] = _("Start date cleared")
  elseif change.started_at then
    local new = ReadHistory.dateText(change.started_at, 1)
    if self.original.started_at then
      local old = ReadHistory.shortDate(self.original.started_at,
        tostring(change.started_at):sub(1, 4) .. "-01-01")
      lines[#lines + 1] = string.format(_("Started %s → %s"), old, new)
    else
      lines[#lines + 1] = string.format(_("Started %s"), new)
    end
  end

  if clear.finished_at then
    lines[#lines + 1] = _("Finish date cleared")
  elseif change.finished_at then
    local new = ReadHistory.dateText(change.finished_at, self.form.finished_at_precision)
    if self.original.finished_at then
      local old = ReadHistory.dateText(self.original.finished_at,
        self.original.finished_at_precision)
      lines[#lines + 1] = string.format(_("Finished %s → %s"), old, new)
    else
      lines[#lines + 1] = string.format(_("Finished %s"), new)
    end
  elseif change.finished_at_precision then
    lines[#lines + 1] = string.format(_("Finish precision %s → %s"),
      precisionLabel(self.original.finished_at_precision), precisionLabel(change.finished_at_precision))
  end

  local edition_line
  if change.edition_id or clear.edition_id then
    local old_name = ReadHistory.formatName({ edition = self.original.edition })
    local new_name = ReadHistory.formatName({ edition = self.form.edition })
    if clear.edition_id then
      edition_line = _("Edition cleared")
    elseif old_name and new_name and old_name ~= new_name then
      edition_line = string.format(_("Edition %s → %s"), old_name, new_name)
    else
      edition_line = _("Edition changed")
    end
    lines[#lines + 1] = edition_line
  end
  if change.progress_pages or clear.progress_pages then
    local page_line = string.format(_("Page %s → %s"), tostring(self.original.progress_pages or 0),
      tostring(self.form.progress_pages or 0))
    -- an edition move and its converted page are one change
    if edition_line then lines[#lines] = edition_line .. " · " .. page_line
    else lines[#lines + 1] = page_line end
  end

  if #lines == 0 then return { _("No changes yet") } end
  -- at most two lines: the form must not grow with the change
  if #lines > 2 then
    local rest = {}
    for i = 3, #lines do rest[#rest + 1] = lines[i] end
    lines[2] = lines[2] .. " · " .. table.concat(rest, " · ")
    for i = #lines, 3, -1 do lines[i] = nil end
  end
  return lines
end

function ReadEditDialog:saveAllowed()
  if self.busy then return false end
  local change, clear = ReadHistory.diff(self.original, self.form)
  if next(change) == nil and next(clear) == nil then return false end
  return self:formProblem() == nil
end

function ReadEditDialog:buildRemoveRow(row, width, viewport, divider)
  local item = ListItem.new {
    width = width,
    label = row.label,
    divider = divider and "dotted" or nil,
    viewport = viewport,
    strong = true,
    callback = function()
      if self.busy then return end
      if row.key == "abandon" then self:confirmAbandon() else self:confirmRemove() end
    end,
  }
  item.text = row.label
  self.row_taps[row.key] = item
  return item
end

function ReadEditDialog:buildRow(row, width, viewport, divider)
  local item = ListItem.new {
    width = width,
    label = row.label,
    support = row.value,
    trailing = (not row.static) and Draw.chevron("right") or nil,
    divider = divider and "dotted" or nil,
    viewport = viewport,
    strong = true,
    callback = (not row.static) and function()
      if not self.busy then row.edit() end
    end or nil,
  }
  if row.static then item.ges_events = {} end
  item.text = row.label
  if not row.static then self.row_taps[row.key] = item end
  return item
end

function ReadEditDialog:buildContent(width, viewport)
  self.row_taps = {}
  local c = VerticalGroup:new { align = "left", Theme.span("s") }

  self.problem, self.message_field = self:formProblem()
  local rows = self:rows()
  for index, row in ipairs(rows) do
    local last = index == #rows
    local explains = self.problem and self.message_field == row.key
    -- the sentence belongs under its row, so that row drops its divider and the sentence closes
    -- the block instead
    if row.remove then
      c[#c + 1] = self:buildRemoveRow(row, width, viewport, (not last) and not explains)
    else
      c[#c + 1] = self:buildRow(row, width, viewport, (not last) and not explains)
    end
    if explains then
      c[#c + 1] = Theme.span(Theme.px(4))
      c[#c + 1] = Theme.mmdText(self.problem, "text", 18, { width = width })
      c[#c + 1] = Theme.span(Theme.px(8))
      c[#c + 1] = Theme.dottedRule(width)
    end
  end
  c[#c + 1] = Theme.span("l")

  -- what Save will write, one line per change, in black
  self.summary = self:summaryLines()
  self.summary_text = table.concat(self.summary, "\n")
  for _, line in ipairs(self.summary) do
    c[#c + 1] = Theme.mmdText(line, "text", 18, { width = width })
    c[#c + 1] = Theme.span(Theme.px(2))
  end
  c[#c + 1] = Theme.span("m")

  self.save_enabled = self:saveAllowed()
  self.save_button = Button.new {
    label = _("Save"), w = width, primary = true, viewport = viewport,
    enabled = self.save_enabled,
    callback = self.save_enabled and function() self:save() end or nil,
  }
  c[#c + 1] = self.save_button
  c[#c + 1] = Theme.span(Theme.px(12))
  self.cancel_button = Button.new {
    label = _("Cancel"), w = width, viewport = viewport,
    enabled = not self.busy,
    callback = (not self.busy) and function() self:cancel() end or nil,
  }
  c[#c + 1] = self.cancel_button
  c[#c + 1] = Theme.span("l")
  return c
end

function ReadEditDialog:build()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local title_bar = TopBar.new {
    width = screen_w,
    title = self.adding and _("Add a past read") or _("Edit read"),
    on_back = function() self:cancel() end,
  }
  self.title_bar = title_bar
  local room = screen_h - title_bar:getSize().h
  local margin = Theme.margin

  local width = screen_w - 2 * margin
  local content = self:buildContent(width, nil)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    local gutter = ScrollControl.gutter()
    width = screen_w - 2 * margin - gutter
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = self,
    }
    local scroll = self.scroll
    content = self:buildContent(width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(margin), content }
    body = ScrollControl.wrap(scroll, content)
  else
    body = HorizontalGroup:new { Theme.hspan(margin), content }
  end
  self.content_width = width

  self.frame = FrameContainer:new {
    width = screen_w,
    height = screen_h,
    background = Theme.WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new { align = "left", title_bar, body },
  }
  self[1] = self.frame
end

function ReadEditDialog:rebuild()
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  UIManager:setDirty(self, "ui")
end

-- ----------------------------------------------------------------- editing

function ReadEditDialog:change(key, value)
  self.form[key] = value
  self:rebuild()
end

function ReadEditDialog:setDate(key, year, month, day)
  self.form[key] = string.format("%04d-%02d-%02d", year, month, day)
  if key == "finished_at" and not self.form.finished_at_precision then
    self.form.finished_at_precision = 1
  end
  self:rebuild()
end

function ReadEditDialog:editionLabel(edition)
  local format = ReadHistory.formatName({ edition = edition }, self.book and self.book.edition_format)
  local pages = type(edition) == "table" and tonumber(edition.pages) or nil
  if format and pages then return string.format(_("%s · %d pages"), format, pages) end
  if format then return format end
  if pages then return string.format(_("%d pages"), pages) end
  return _("Edition not recorded")
end

function ReadEditDialog:setEdition(edition)
  local edition_id = type(edition) == "table" and tonumber(edition.edition_id or edition.id) or nil
  if not edition_id or edition_id == tonumber(self.form.edition_id) then return end
  if edition_id == tonumber(self.original.edition_id) then
    self.form.edition_id, self.form.edition = self.original.edition_id, self.original.edition
    self.form.progress_pages = self.original.progress_pages
    self.page_conversion = nil
    self:rebuild()
    return
  end
  local from, old_pages = tonumber(self.form.progress_pages), self:editionPages()
  local new_pages = tonumber(edition.pages)
  self.form.edition_id, self.form.edition = edition_id, edition
  if from ~= nil then
    self.form.progress_pages = ReadHistory.convertPage(from, old_pages, new_pages)
    self.page_conversion = {
      from = from, to = self.form.progress_pages, old_pages = old_pages, new_pages = new_pages,
      unknown = not old_pages or old_pages <= 0 or not new_pages or new_pages <= 0,
    }
  end
  self:rebuild()
end

function ReadEditDialog:pickEdition()
  if self.busy then return end
  if self.choose_edition then
    self.choose_edition(tonumber(self.form.edition_id), function(edition)
      if edition then self:setEdition(edition) end
    end)
    return
  end
  local picker
  local rows = {}
  for _i, edition in ipairs(self.editions or {}) do
    rows[#rows + 1] = {
      text = self:editionLabel(edition),
      current = tonumber(edition.edition_id or edition.id) == tonumber(self.form.edition_id),
      callback = function()
        UIManager:close(picker)
        self:setEdition(edition)
      end,
    }
  end
  picker = Picker.new { title = _("Select edition"), rows = rows }
  UIManager:show(picker)
  return picker
end

function ReadEditDialog:pickPage()
  if self.busy then return end
  local max = self:editionPages() or 100000
  StepperDialog.show {
    title = _("Page reached"),
    text = _("The page in the edition you chose."),
    value = tonumber(self.form.progress_pages) or 0,
    min = 0, max = max, step = 1, big_step = 10,
    save_label = _("Save"),
    on_save = function(value) self:change("progress_pages", value) end,
  }
end

function ReadEditDialog:pickDate(key, title)
  local year, month, day = dateParts(self.form[key])
  if not (year and month and day) then
    year, month, day = dateParts(self.today)
  end
  DatePicker.show {
    title = title, year = year, month = month, day = day,
    save_label = _("Set date"),
    on_save = function(y, m, d) self:setDate(key, y, m, d) end,
  }
end

function ReadEditDialog:pickPrecision()
  local picker
  local rows = {}
  for _, choice in ipairs(PRECISION) do
    rows[#rows + 1] = {
      text = choice.label,
      current = (tonumber(self.form.finished_at_precision) or 1) == choice.value,
      callback = function()
        UIManager:close(picker)
        self:change("finished_at_precision", choice.value)
      end,
    }
  end
  picker = Picker.new { title = _("Finish precision"), rows = rows }
  UIManager:show(picker)
  return picker
end

-- ----------------------------------------------------------------- actions

-- What would be sent; a test calls this to see the sparse change without opening a picker.
function ReadEditDialog:preview()
  return ReadHistory.diff(self.original, self.form)
end

function ReadEditDialog:confirmRemove()
  local read = self.read or {}
  local pending = read.pending_add == true
  local detail = string.format(_("%s · %s"), ReadHistory.rangeText(read), self:editionText())
  StatusDialogs.confirm {
    title = pending and _("Discard this read?") or _("Remove this read?"),
    text = pending
      and _("This read has not been sent to Hardcover yet. It will be removed from this device.")
      or string.format(_("%s\n\nThe book stays on your Read shelf."), detail),
    ok_text = pending and _("Discard") or _("Remove"),
    cancel_text = _("Keep it"),
    ok_callback = function()
      self:close()
      if self.on_remove then self.on_remove(read) end
    end,
  }
end

function ReadEditDialog:confirmAbandon()
  local read = self.read or {}
  StatusDialogs.confirm {
    title = _("Abandon this reread?"),
    text = _("The reread and its progress will be removed. Your previous read, its dates, rating and review stay, and the book stays on its shelf. Journal entries from the reread may remain."),
    ok_text = _("Abandon reread"),
    cancel_text = _("Keep reading"),
    ok_callback = function()
      self:close()
      if self.on_abandon then self.on_abandon(read) end
    end,
  }
end

function ReadEditDialog:save()
  if self.busy then return end
  if ReadHistory.validate(self.form, self.today) then return end
  local change, clear = self:preview()
  if next(change) == nil and next(clear) == nil then return end
  if self.on_save then self.on_save(change, clear, self.form.edition) end
end

function ReadEditDialog:cancel()
  if self.busy then return true end
  local change, clear = self:preview()
  if next(change) == nil and next(clear) == nil then return self:close() end
  local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
  StatusDialogs.confirm {
    title = _("Discard your changes?"),
    ok_text = _("Discard"),
    cancel_text = _("Keep editing"),
    ok_callback = function() self:close() end,
  }
  return true
end

function ReadEditDialog:setBusy(busy)
  self.busy = busy and true or false
  self:rebuild()
end

function ReadEditDialog:close()
  UIManager:close(self)
  if self.on_close then self.on_close() end
  return true
end

function ReadEditDialog:onCloseReadEdit()
  return self:cancel()
end

function ReadEditDialog:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

return ReadEditDialog
