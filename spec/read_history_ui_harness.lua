-- Reading history and the read form: what each builds and what its controls do, without KOReader.
--
-- Run with:  luajit spec/read_history_ui_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local check = r.test

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local function widget(kind)
  local C = { kind = kind }
  C.__index = C
  function C:new(o)
    o = o or {}
    o.kind = kind
    return setmetatable(o, C)
  end
  function C:getSize() return { w = self.width or 0, h = self.height or 20 } end
  function C:free() end
  function C:paintTo() end
  return C
end

local function class(name)
  local C = { __name = name }
  C.__index = C
  function C:extend(o)
    o = o or {}
    o.__index = o
    return setmetatable(o, { __index = C })
  end
  function C:new(o)
    o = setmetatable(o or {}, self)
    o.key_events = o.key_events or {}
    if o.init then o:init() end
    return o
  end
  function C:paintTo() end
  function C:free() end
  return C
end

local InputContainer = class("InputContainer")
local TapRow = widget("TapRow")
TapRow.callback = nil

local shown, closed, dirty = {}, 0, 0
local UIManager = {
  show = function(_, w) shown[#shown + 1] = w end,
  close = function(_, w) closed = closed + 1 end,
  setDirty = function() dirty = dirty + 1 end,
  nextTick = function(_, fn) fn() end,
  scheduleIn = function() end,
  unschedule = function() end,
}

local stubs = {
  ["ui/widget/container/inputcontainer"] = InputContainer,
  ["ui/widget/textwidget"] = widget("Text"),
  ["ui/widget/textboxwidget"] = widget("TextBox"),
  ["ui/widget/imagewidget"] = widget("Image"),
  ["ui/widget/iconwidget"] = widget("Icon"),
  ["ui/widget/horizontalgroup"] = widget("HGroup"),
  ["ui/widget/horizontalspan"] = widget("HSpan"),
  ["ui/widget/verticalgroup"] = widget("VGroup"),
  ["ui/widget/verticalspan"] = widget("VSpan"),
  ["ui/widget/linewidget"] = widget("Line"),
  ["ui/widget/container/centercontainer"] = widget("Center"),
  ["ui/widget/container/framecontainer"] = widget("Frame"),
  ["ui/widget/container/leftcontainer"] = widget("Left"),
  ["ui/widget/container/scrollablecontainer"] = widget("Scroll"),
  ["ui/widget/overlapgroup"] = widget("Overlap"),
  ["ui/widget/widget"] = widget("Widget"),
  ["hardcover/lib/ui/tap_row"] = TapRow,
  ["ui/uimanager"] = UIManager,
  ["ui/geometry"] = { new = function(_, t) return t end },
  ["ui/font"] = { getFace = function() return {} end },
  ["device"] = { screen = {
    getWidth = function() return 1000 end,
    getHeight = function() return 4000 end,
    scaleBySize = function(_, n) return n end,
    getSize = function() return { w = 1000, h = 4000 } end,
  } },
  ["ffi/blitbuffer"] = { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_GRAY_5 = "grey" },
}

package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end

local real_require = require
_G.require = function(name)
  if stubs[name] then return stubs[name] end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local ReadHistoryDialog = real_require("hardcover/lib/ui/read_history_dialog")
local ReadEditDialog = real_require("hardcover/lib/ui/read_edit_dialog")

local function read(id, extra)
  extra = extra or {}
  local row = { id = id, started_at = "2024-03-12", finished_at = "2024-03-14",
    finished_at_precision = 1, progress_pages = 300, edition_id = 7,
    edition = { id = 7, pages = 304, edition_format = "Paperback", reading_format_id = 1 } }
  if extra.no_finish then row.finished_at = nil end
  for k, v in pairs(extra) do
    if k ~= "no_finish" then row[k] = v end
  end
  return row
end

local today = "2026-11-15"
local reads = {
  read(1, { started_at = "2020-01-01", finished_at = "2020-01-10" }),
  read(2, { started_at = "2024-03-14", finished_at = "2024-03-20" }),
  read(3, { started_at = "2026-11-03", no_finish = true, progress_pages = 120 }),
}
local checked = os.time { year = 2026, month = 11, day = 15, hour = 9, min = 12, sec = 0 }

print("\n== reading history ==")

check("one row per read, newest first, with the count and when Hardcover checked", function()
  local opened
  local dialog = ReadHistoryDialog:new {
    book = { title = "Dune" }, reads = reads, checked_at = checked, today = today,
    on_open_read = function(row) opened = row end, on_add = function() end,
  }
  assert(#dialog.items == 3, "rows: " .. #dialog.items)
  assert(dialog.items[1].read.id == 3 and dialog.items[3].read.id == 1, "not newest first")
  assert(dialog.items[1].label == "Started 3 Nov 2026", dialog.items[1].label)
  assert(dialog.items[2].label == "14 – 20 Mar 2024", dialog.items[2].label)
  assert(dialog.support_text == "3 reads · Hardcover checked today, "
    .. os.date("%H:%M", checked), dialog.support_text)
  assert(dialog.add_row and dialog.add_row.text == "Add a past read")
  assert(dialog.offline_note and dialog.hint_text == "Tap a read to change its dates or edition.")
  dialog.items[1].row.callback()
  assert(opened and opened.id == 3, "tapping a row did not open its read")
end)

check("a state replaces the support line, in black and with an icon", function()
  local dialog = ReadHistoryDialog:new {
    book = { title = "Dune" }, reads = reads, today = today,
    states = { [2] = { text = "Finish date waiting to send", kind = "waiting" } },
    on_open_read = function() end, on_add = function() end,
  }
  local item = dialog.items[2]
  assert(item.support == "Finish date waiting to send", item.support)
  assert(item.state and item.state.kind == "waiting")
  -- the state is the strong (black) support, with an icon in front
  assert(item.row.support_strong == true and item.row.support_icon ~= nil)
end)

check("a book with no reads still offers Add a past read", function()
  local dialog = ReadHistoryDialog:new {
    book = { title = "Dune" }, reads = {}, today = today,
    on_open_read = function() end, on_add = function() end,
  }
  assert(#dialog.items == 0)
  assert(dialog.support_text == "No reads yet", dialog.support_text)
  assert(dialog.add_row and dialog.offline_note)
end)

check("no saved copy asks for one connection, and offers no addition", function()
  local dialog = ReadHistoryDialog:new {
    book = { title = "Dune" }, reads = nil, today = today,
    on_open_read = function() end, on_add = function() end,
  }
  assert(dialog.empty_text == "Connect once to load this book's reading history.", dialog.empty_text)
  assert(#dialog.items == 0 and dialog.add_row == nil and dialog.offline_note == nil)
  assert(dialog.support_text == nil)
end)

check("one read says 1 read", function()
  local dialog = ReadHistoryDialog:new { book = { title = "Dune" }, reads = { reads[3] }, today = today }
  assert(dialog.support_text == "1 read", dialog.support_text)
end)

check("an earlier check says the day, and the year only when it differs", function()
  local same_year = ReadHistoryDialog:new {
    book = { title = "Dune" }, reads = reads, today = today,
    checked_at = os.time { year = 2026, month = 11, day = 12, hour = 9, min = 12, sec = 0 },
  }
  assert(same_year.support_text == "3 reads · Hardcover checked 12 Nov", same_year.support_text)
  local earlier = ReadHistoryDialog:new {
    book = { title = "Dune" }, reads = reads, today = today,
    checked_at = os.time { year = 2025, month = 11, day = 12, hour = 9, min = 12, sec = 0 },
  }
  assert(earlier.support_text == "3 reads · Hardcover checked 12 Nov 2025", earlier.support_text)
end)

print("\n== edit read ==")

check("the form shows both dates, the precision and a tappable edition, and starts with no changes", function()
  local dialog = ReadEditDialog:new { book = { title = "Dune", pages = 304 }, read = read(1), today = today,
    editions = { { edition_id = 8, pages = 608, edition_format = "E-book", reading_format_id = 1 } } }
  local keys = {}
  for _, row in ipairs(dialog:rows()) do keys[#keys + 1] = row.key end
  assert(table.concat(keys, ",") == "started_at,finished_at,finished_at_precision,edition",
    table.concat(keys, ","))
  assert(dialog:rows()[4].value == "Paperback · 304 pages", dialog:rows()[4].value)
  assert(dialog.row_taps.edition ~= nil, "the edition is not tappable")
  assert(dialog.summary[1] == "No changes yet", dialog.summary[1])
  assert(dialog.save_enabled == false and dialog.save_button.callback == nil)
end)

check("choosing an edition converts the page and shows the page reached", function()
  local dialog = ReadEditDialog:new { book = { title = "Dune", pages = 304 }, read = read(1), today = today,
    editions = { { edition_id = 8, pages = 608, edition_format = "E-book", reading_format_id = 1 } } }
  dialog:setEdition({ edition_id = 8, pages = 608, edition_format = "E-book", reading_format_id = 1 })
  assert(dialog.row_taps.progress_pages ~= nil, "no page reached row")
  assert(dialog:pageText() == "300 of 304 → 600 of 608", dialog:pageText())
  assert(dialog:preview().edition_id == 8 and dialog:preview().progress_pages == 600)
  -- a corrected page is what the row and the sparse change show
  dialog:change("progress_pages", 590)
  assert(dialog:pageText() == "300 of 304 → 590 of 608", dialog:pageText())
  assert(dialog:preview().progress_pages == 590)
end)

check("an edition with no page count cannot invent a page", function()
  local dialog = ReadEditDialog:new { book = { title = "Dune", pages = 304 }, read = read(1), today = today,
    editions = { { edition_id = 9, edition_format = "Audiobook", reading_format_id = 2 } } }
  dialog:setEdition({ edition_id = 9, edition_format = "Audiobook", reading_format_id = 2 })
  assert(dialog:pageText() == "The page could not be converted", dialog:pageText())
  assert(dialog.form.progress_pages == 300 and dialog:preview().progress_pages == nil,
    "the page was changed without a page count")
end)

check("the chosen edition is handed to the caller with the change", function()
  local chosen
  local dialog = ReadEditDialog:new { book = { title = "Dune" }, read = read(1), today = today,
    on_save = function(_change, _clear, edition) chosen = edition end }
  dialog:setEdition({ edition_id = 8, pages = 608, edition_format = "E-book", reading_format_id = 1 })
  dialog:save()
  assert(chosen and chosen.edition_id == 8 and chosen.pages == 608)
end)

check("a date change is summarised and sent sparse", function()
  local saved, cleared
  local dialog = ReadEditDialog:new { book = { title = "Dune" }, read = read(1), today = today,
    on_save = function(change, clear) saved, cleared = change, clear end }
  dialog:setDate("started_at", 2024, 3, 14)
  assert(dialog.summary[1] == "Started 12 Mar → 14 Mar 2024", dialog.summary[1])
  assert(dialog.save_enabled == true and dialog.save_button.callback ~= nil)
  dialog:save()
  assert(saved and saved.started_at == "2024-03-14", "the start was not sent")
  assert(saved.finished_at == nil and saved.progress_pages == nil, "a broad payload was sent")
  assert(cleared and next(cleared) == nil)
end)

check("a finish before the start is refused, under the finish row", function()
  local dialog = ReadEditDialog:new { book = { title = "Dune" }, read = read(1), today = today }
  dialog:setDate("finished_at", 2024, 3, 10)
  assert(dialog.problem == "The finish is before the start.", tostring(dialog.problem))
  assert(dialog.message_field == "finished_at")
  assert(dialog.save_enabled == false and dialog.save_button.callback == nil)
end)

check("a date after today is refused", function()
  local dialog = ReadEditDialog:new { book = { title = "Dune" }, read = read(1), today = today }
  dialog:setDate("started_at", 2026, 11, 16)
  assert(dialog.problem == "The start is after today.", tostring(dialog.problem))
  assert(dialog.message_field == "started_at")
  assert(dialog.save_enabled == false)
end)

check("the read in progress has no finish row, and says Still reading", function()
  local dialog = ReadEditDialog:new { book = { title = "Dune" },
    read = read(3, { no_finish = true, started_at = "2026-11-03", progress_pages = 120 }), today = today }
  local keys, status = {}, nil
  for _, row in ipairs(dialog:rows()) do
    keys[#keys + 1] = row.key
    if row.key == "status" then status = row.value end
  end
  assert(table.concat(keys, ",") == "started_at,status,edition", table.concat(keys, ","))
  assert(status == "Still reading", tostring(status))
  assert(dialog.row_taps.finished_at == nil and dialog.row_taps.finished_at_precision == nil)
  dialog:setDate("started_at", 2026, 11, 4)
  assert(dialog.save_enabled == true)
  local change = dialog:preview()
  assert(change.started_at == "2026-11-04" and change.finished_at == nil)
end)

check("changing only the precision says so", function()
  local dialog = ReadEditDialog:new { book = { title = "Dune" }, read = read(1,
    { finished_at = "2019-03-01", finished_at_precision = 2 }), today = today }
  dialog:change("finished_at_precision", 1)
  assert(dialog.summary[1] == "Finish precision Month → Day", dialog.summary[1])
  assert(dialog:preview().finished_at == nil and dialog:preview().finished_at_precision == 1)
end)

check("save does nothing with no changes", function()
  local called = false
  local dialog = ReadEditDialog:new { book = { title = "Dune" }, read = read(1), today = today,
    on_save = function() called = true end }
  dialog:save()
  assert(called == false)
end)

r.finish()
