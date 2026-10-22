-- A journal entry (a note or a quote on the book): a form of rows, as the goal form is. The text
-- is the first row, as many lines of it as fit; each of the others shows what it holds (the type,
-- who can see it, the tags, the edition, the page) and opens the widget that changes it. Save sends
-- the entry. The text is written in the plugin's input dialog (several lines, a keyboard under it).
--
-- `save_dialog_callback(entry)` returns ok, message: the form stays open when it did not work, with
-- the message at the top, so what was typed is kept.

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

local Button = require("hardcover/lib/ui/components/button")
local Draw = require("hardcover/lib/ui/components/draw")
local InputDialog = require("hardcover/lib/ui/components/input_dialog")
local ListItem = require("hardcover/lib/ui/components/list_item")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local StepperDialog = require("hardcover/lib/ui/components/stepper_dialog")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

local JOURNAL_NOTE = "note"
local JOURNAL_QUOTE = "quote"

local PREVIEW_LINES = 4

local PRIVACY = { _("Public"), _("Follows"), _("Private") }

local JournalDialog = InputContainer:extend {
  name = "hardcover_journal_dialog",
  input = "",
  event_type = JOURNAL_NOTE,
  book_id = nil,
  edition_id = nil,
  edition_format = nil,
  pages = nil,
  page = nil,
  tags = nil,
  hidden_tags = nil,
  privacy_setting_id = 1,
  save_dialog_callback = nil,
  select_edition_callback = nil,
  close_callback = nil,
}

local function comma_split(text)
  local result = {}
  for str in string.gmatch(text or "", "([^,]+)") do
    local trimmed = str:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(result, trimmed)
    end
  end

  return result
end

function JournalDialog:init()
  self.text = self.input or ""
  self.tags = self.tags or {}
  self.hidden_tags = self.hidden_tags or {}
  self.message = nil
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.CloseForm = { { "Back" } }
  -- what it was when it opened, to know whether anything was changed
  self.original = self:snapshot()
  self:build()
end

function JournalDialog:snapshot()
  return table.concat({ self.text, self.event_type, tostring(self.privacy_setting_id),
    table.concat(self.tags, ","), table.concat(self.hidden_tags, ","),
    tostring(self.edition_id), tostring(self.page) }, "\0")
end

function JournalDialog:dirty()
  return self:snapshot() ~= self.original
end

function JournalDialog:getText() return self.text end

local function pageText(page, pages)
  return string.format(_("Page %s of %s"), tostring(page or 0), tostring(pages or "???"))
end

-- the text: a label over as many lines of it as fit, a fixed height so the rows below stay put
function JournalDialog:buildTextRow(width, viewport, last)
  local pad = ListItem.PAD
  local inner = width - 2 * pad
  local face, bold = Theme.mmdFace("text", 21)
  local empty = self.text == ""
  local shown = empty and _("Tap to write") or self.text
  local measure = TextBoxWidget:new { text = "I", face = face, bold = bold, width = inner, for_measurement_only = true }
  local one = measure:getTextHeight()
  measure:free()
  local preview = TextBoxWidget:new {
    text = shown, face = face, bold = bold, width = inner,
    height = one * PREVIEW_LINES, height_adjust = true, height_overflow_show_ellipsis = true,
    fgcolor = empty and Theme.secondary() or Theme.BLACK,
  }
  local label = self.event_type == JOURNAL_QUOTE and _("Quote") or _("Note")
  local column = VerticalGroup:new { align = "left",
    Theme.span(Theme.mmd.row.pad_y),
    HorizontalGroup:new { Theme.hspan(pad), Theme.mmdText(label, "strong", 21, { width = inner }) },
    Theme.span(Theme.mmd.row.gap),
    HorizontalGroup:new { Theme.hspan(pad), preview },
    Theme.span(Theme.mmd.row.pad_y),
  }
  if not last then column[#column + 1] = Theme.dottedRule(width) end
  local row = TapRow:new { callback = function() self:editText() end, viewport = viewport, column }
  row.text = label
  return row
end

function JournalDialog:rows()
  return {
    { key = "type", label = _("Type"), value = self.event_type == JOURNAL_QUOTE and _("Quote") or _("Note"),
      edit = function() self:pickType() end },
    { key = "privacy", label = _("Visible to"), value = PRIVACY[self.privacy_setting_id] or PRIVACY[1],
      edit = function() self:pickPrivacy() end },
    { key = "tags", label = _("Tags"), value = #self.tags > 0 and table.concat(self.tags, ", ") or _("None"),
      edit = function() self:editTags(false) end },
    { key = "hidden_tags", label = _("Hidden tags"),
      value = #self.hidden_tags > 0 and table.concat(self.hidden_tags, ", ") or _("None"),
      edit = function() self:editTags(true) end },
    { key = "edition", label = _("Edition"), value = self.edition_format or _("Physical Book"),
      edit = function() if self.select_edition_callback then self.select_edition_callback() end end },
    { key = "page", label = _("Page"), value = pageText(self.page, self.pages),
      edit = function() self:editPage() end },
  }
end

function JournalDialog:buildContent(width, viewport)
  self.row_taps = {}
  local c = VerticalGroup:new { align = "left" }
  table.insert(c, Theme.span("s"))

  if self.message then
    local face, bold = Theme.mmdFace("text", 18)
    table.insert(c, Theme.mmdText(_("Not saved"), "strong", 21, { width = width }))
    table.insert(c, Theme.span(Theme.px(4)))
    table.insert(c, TextBoxWidget:new { text = self.message, face = face, bold = bold, width = width,
      fgcolor = Theme.secondary() })
    table.insert(c, Theme.span("s"))
    table.insert(c, Theme.dottedRule(width))
  end

  table.insert(c, self:buildTextRow(width, viewport, false))
  self.row_taps.text = c[#c]
  local rows = self:rows()
  for i, row in ipairs(rows) do
    local item = ListItem.new {
      width = width, label = row.label, support = row.value, trailing = Draw.chevron("right"),
      divider = (i < #rows) and "dotted" or nil, viewport = viewport,
      callback = row.edit,
    }
    item.text = row.label
    self.row_taps[row.key] = item
    table.insert(c, item)
  end
  table.insert(c, Theme.span("l"))

  self.save_button = Button.new { label = _("Save"), w = width, primary = true, viewport = viewport,
    callback = function() self:save() end }
  table.insert(c, self.save_button)
  table.insert(c, Theme.span("l"))
  return c
end

function JournalDialog:build()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local title = self.event_type == JOURNAL_QUOTE and _("Add a quote") or _("Add a note")
  local title_bar = TopBar.new { width = screen_w, title = title, on_back = function() self:cancel() end }
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
    width = screen_w, height = screen_h, background = Theme.WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", title_bar, body },
  }
  self[1] = self.frame
end

function JournalDialog:rebuild()
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  UIManager:setDirty(self, "ui")
end

-- ----------------------------------------------------------------- editing

function JournalDialog:change(key, value)
  self[key] = value
  self.message = nil
  self:rebuild()
end

-- the text, in the input dialog: Done keeps it, Cancel leaves it as it was
function JournalDialog:editText()
  local input
  input = InputDialog:new {
    title = self.event_type == JOURNAL_QUOTE and _("Quote") or _("Note"),
    input = self.text,
    allow_newline = true,
    lines = 6,
    buttons = {
      { label = _("Cancel"), callback = function() UIManager:close(input) end },
      { label = _("Done"), primary = true, callback = function()
          local value = input:getInputText()
          UIManager:close(input)
          self:change("text", value)
        end },
    },
  }
  UIManager:show(input)
  if input.onShowKeyboard then input:onShowKeyboard() end
end

function JournalDialog:editTags(hidden)
  local key = hidden and "hidden_tags" or "tags"
  local input
  input = InputDialog:new {
    title = hidden and _("Hidden tags") or _("Tags"),
    text = _("Separate tags with commas."),
    input = table.concat(self[key], ", "),
    buttons = {
      { label = _("Cancel"), callback = function() UIManager:close(input) end },
      { label = _("Set"), primary = true, callback = function()
          local value = input:getInputText()
          UIManager:close(input)
          self:change(key, comma_split(value))
        end },
    },
  }
  UIManager:show(input)
  if input.onShowKeyboard then input:onShowKeyboard() end
end

-- a choose-one list; `choices` is { { text, value, current } }
function JournalDialog:choose(title, choices, on_choose)
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
  picker = require("hardcover/lib/ui/picker").new { title = title, rows = rows }
  UIManager:show(picker)
  return picker
end

function JournalDialog:pickType()
  self:choose(_("Type"), {
    { text = _("Note"), value = JOURNAL_NOTE, current = self.event_type == JOURNAL_NOTE },
    { text = _("Quote"), value = JOURNAL_QUOTE, current = self.event_type == JOURNAL_QUOTE },
  }, function(value) self:change("event_type", value) end)
end

function JournalDialog:pickPrivacy()
  local choices = {}
  for id, text in ipairs(PRIVACY) do
    choices[#choices + 1] = { text = text, value = id, current = self.privacy_setting_id == id }
  end
  self:choose(_("Visible to"), choices, function(value) self:change("privacy_setting_id", value) end)
end

function JournalDialog:editPage()
  StepperDialog.show {
    title = _("Set current page"),
    value = self.page or 0, min = 0, max = tonumber(self.pages) or 9999, step = 1, big_step = 20,
    save_label = _("Set page"),
    on_save = function(value) self:change("page", value) end,
  }
end

function JournalDialog:setEdition(edition_id, edition_format, edition_pages)
  self.edition_id = edition_id
  self.edition_format = edition_format
  self.pages = edition_pages or self.pages
  self:rebuild()
end

-- ----------------------------------------------------------------- actions

function JournalDialog:save()
  if self.text:match("^%s*$") then
    self.message = self.event_type == JOURNAL_QUOTE and _("Write or paste the quote first.")
      or _("Write the note first.")
    self:rebuild()
    return
  end
  if not self.save_dialog_callback then return end
  local ok, message = self.save_dialog_callback({
    book_id = self.book_id,
    edition_id = self.edition_id,
    text = self.text,
    page = self.page,
    pages = self.pages,
    event_type = self.event_type,
    privacy_setting_id = self.privacy_setting_id,
    tags = self.tags,
    hidden_tags = self.hidden_tags,
  })
  if ok then
    if message then StatusDialogs.info(message) end
  else
    self.message = message or _("The entry could not be saved.")
    self:rebuild()
  end
end

function JournalDialog:cancel()
  if not self:dirty() then return self:onClose() end
  StatusDialogs.confirm {
    title = _("Discard your changes?"),
    ok_text = _("Discard"),
    cancel_text = _("Keep editing"),
    ok_callback = function() self:onClose() end,
  }
  return true
end

function JournalDialog:onCloseWidget()
  UIManager:setDirty(nil, "ui")
  if self.close_callback and not self.closed_once then
    self.closed_once = true
    self.close_callback()
  end
end

function JournalDialog:onCloseForm()
  return self:cancel()
end

function JournalDialog:onClose()
  UIManager:close(self)
  return true
end

return JournalDialog
