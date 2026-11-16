-- The reading history's pure rules: dates in words, one line for the reading row, the checks a
-- read form makes, the sparse change it sends, and the saved reads with queued edits laid over.
--
-- Run with:  luajit spec/read_history_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local ReadHistory = require("hardcover/lib/read_history")
local check = r.test

local function read(extra)
  extra = extra or {}
  local row = { id = 1, started_at = "2026-11-03", edition = { edition_format = "Paperback", pages = 304 } }
  -- `nil` in a constructor only removes a key, so "no start" and "no edition" are asked for by name
  if extra.no_start then row.started_at = nil end
  if extra.no_edition then row.edition = nil end
  for k, v in pairs(extra) do
    if k ~= "no_start" and k ~= "no_edition" then row[k] = v end
  end
  return row
end

print("\n== dates in words ==")

check("a day, a month and a year", function()
  assert(ReadHistory.dateText("2026-11-03", 1) == "3 Nov 2026")
  assert(ReadHistory.dateText("2019-03-01", 2) == "Mar 2019")
  assert(ReadHistory.dateText("2019-01-01", 3) == "2019")
  assert(ReadHistory.dateText(nil, 1) == "")
end)

check("a timestamp is read as its day", function()
  assert(ReadHistory.dateText("2026-11-03T18:04:11Z", 1) == "3 Nov 2026")
end)

check("one day", function()
  local text = ReadHistory.rangeText(read { started_at = "2024-03-14", finished_at = "2024-03-14" })
  assert(text == "14 Mar 2024", text)
end)

check("a range in one month keeps the month once", function()
  local text = ReadHistory.rangeText(read { started_at = "2024-03-14", finished_at = "2024-03-20" })
  assert(text == "14 – 20 Mar 2024", text)
end)

check("a range across months keeps the year once", function()
  local text = ReadHistory.rangeText(read { started_at = "2024-02-28", finished_at = "2024-03-03" })
  assert(text == "28 Feb – 3 Mar 2024", text)
end)

check("a range across years keeps both years", function()
  local text = ReadHistory.rangeText(read { started_at = "2023-12-28", finished_at = "2024-01-03" })
  assert(text == "28 Dec 2023 – 3 Jan 2024", text)
end)

check("a start with no finish", function()
  assert(ReadHistory.rangeText(read { started_at = "2026-11-03" }) == "Started 3 Nov 2026")
end)

check("a finish with no start", function()
  assert(ReadHistory.rangeText(read { no_start = true, finished_at = "2026-03-20" }) == "Finished 20 Mar 2026")
end)

check("month and year precision", function()
  local month = ReadHistory.rangeText(read { started_at = "2019-03-01", finished_at = "2019-03-01",
    finished_at_precision = 2 })
  assert(month == "Mar 2019", month)
  local year = ReadHistory.rangeText(read { started_at = "2019-01-01", finished_at = "2019-01-01",
    finished_at_precision = 3 })
  assert(year == "2019", year)
end)

print("\n== the reading row ==")

local three = {
  read { id = 10, started_at = "2024-03-14", finished_at = "2024-03-20", edition = { edition_format = "Paperback", pages = 300 } },
  read { id = 11, started_at = "2025-01-02", finished_at = "2025-01-10", edition = { edition_format = "Paperback", pages = 304 } },
  read { id = 12, started_at = "2026-11-03", progress_pages = 120, edition = { edition_format = "Paperback", pages = 304 } },
}

check("in progress: page, share and which read", function()
  local s = ReadHistory.summary(three, { today = "2026-11-15" })
  assert(s.label == "Page 120 of 304", s.label)
  assert(s.pct == 39, tostring(s.pct))
  assert(s.support == "3rd read · since 3 Nov · Paperback", s.support)
end)

check("one read says Since, not 1st read", function()
  local s = ReadHistory.summary({ three[3] }, { today = "2026-11-15" })
  assert(s.label == "Page 120 of 304" and s.support == "Since 3 Nov · Paperback", s.support)
end)

check("finished: the finish day, full, and which read", function()
  local s = ReadHistory.summary({ three[1], three[2] }, { today = "2026-11-15" })
  assert(s.label == "Finished 10 Jan 2025", s.label)
  assert(s.pct == 100)
  assert(s.support == "2nd read · Paperback", s.support)
end)

check("one finished read has only its format", function()
  local s = ReadHistory.summary({ three[1] }, { today = "2026-11-15" })
  assert(s.support == "Paperback", s.support)
end)

check("a month-precision finish", function()
  local s = ReadHistory.summary({ read { finished_at = "2019-03-01", finished_at_precision = 2 } })
  assert(s.label == "Finished Mar 2019", s.label)
end)

check("no reads", function()
  local s = ReadHistory.summary({})
  assert(s.label == "No reads yet" and s.pct == nil and s.support == "Add a past read")
  local n = ReadHistory.summary(nil)
  assert(n.label == "No reads yet")
end)

check("a page total that is not known is not invented", function()
  local s = ReadHistory.summary({ read { progress_pages = 120, no_edition = true } })
  assert(s.label == "Page 120" and s.pct == nil, s.label)
end)

check("a state goes in front of the rest of the line", function()
  local s = ReadHistory.summary(three, { today = "2026-11-15", state = "Needs your decision" })
  assert(s.support == "Needs your decision · 3rd read · since 3 Nov · Paperback", s.support)
end)

check("a read that has not started", function()
  local s = ReadHistory.summary({ read { no_start = true, edition = { edition_format = "E-Book" } } })
  assert(s.label == "Reading" and s.support == "E-Book", s.label .. " / " .. tostring(s.support))
end)

check("reads with no start date still choose the newest", function()
  -- Book:currentRead prefers an unfinished read with progress; normalize only sorts for display
  local s = ReadHistory.summary({ read { no_start = true, progress_pages = 12, no_edition = true } })
  assert(s.label == "Page 12")
end)

print("\n== form checks ==")

check("a finish before the start", function()
  local message, field = ReadHistory.validate({ started_at = "2024-03-20", finished_at = "2024-03-14" },
    "2026-11-15")
  assert(message == "The finish is before the start." and field == "finished_at", tostring(message))
end)

check("a month-precision finish covers its whole month", function()
  assert(ReadHistory.validate({ started_at = "2024-03-20", finished_at = "2024-03-01",
    finished_at_precision = 2 }, "2026-11-15") == nil)
end)

check("a date after today", function()
  local message, field = ReadHistory.validate({ started_at = "2026-11-16" }, "2026-11-15")
  assert(message == "The start is after today." and field == "started_at", tostring(message))
  local later = ReadHistory.validate({ started_at = "2026-11-01", finished_at = "2026-12-01",
    finished_at_precision = 2 }, "2026-11-15")
  assert(later == "The finish is after today.", tostring(later))
end)

check("a date that does not exist", function()
  local message, field = ReadHistory.validate({ started_at = "2024-02-31" }, "2026-11-15")
  assert(message == "The start date is not a real date." and field == "started_at", tostring(message))
end)

check("a valid form has nothing to say", function()
  assert(ReadHistory.validate({ started_at = "2024-03-14", finished_at = "2024-03-20" }, "2026-11-15") == nil)
end)

print("\n== the change to send ==")

check("only the changed date", function()
  local base = read { started_at = "2024-03-14", finished_at = "2024-03-20" }
  local change, clear = ReadHistory.diff(base, { started_at = "2024-03-12", finished_at = "2024-03-20" })
  assert(change.started_at == "2024-03-12")
  assert(change.finished_at == nil and change.progress_pages == nil and change.edition_id == nil)
  assert(next(clear) == nil)
end)

check("clearing a date is not sending a new one", function()
  local base = read { started_at = "2024-03-14", finished_at = "2024-03-20" }
  local change, clear = ReadHistory.diff(base, { started_at = "2024-03-14", finished_at = nil })
  assert(next(change) == nil)
  assert(clear.finished_at == true and clear.started_at == nil)
end)

check("nothing changed sends nothing", function()
  local base = read { started_at = "2024-03-14", finished_at = "2024-03-20" }
  local change, clear = ReadHistory.diff(base, { started_at = "2024-03-14", finished_at = "2024-03-20" })
  assert(next(change) == nil and next(clear) == nil)
end)

check("a changed precision alone", function()
  local base = read { finished_at = "2019-03-01", finished_at_precision = 2 }
  local change = ReadHistory.diff(base, { finished_at = "2019-03-01", finished_at_precision = 1 })
  assert(change.finished_at_precision == 1 and change.finished_at == nil)
end)

print("\n== queued edits over saved reads ==")

check("only the older read changes", function()
  local saved = {
    read { id = 20, started_at = "2024-03-14", finished_at = "2024-03-20" },
    read { id = 21, started_at = "2026-11-03", progress_pages = 40 },
  }
  local projected = ReadHistory.project(saved, {
    { kind = "read_dates", seq = 1, read_id = 20, change = { started_at = "2024-03-12" } },
  })
  assert(projected[1].started_at == "2024-03-12" and projected[1].finished_at == "2024-03-20")
  assert(projected[2].started_at == "2026-11-03" and projected[2].progress_pages == 40)
  assert(saved[1].started_at == "2024-03-14", "the saved copy was changed")
end)

check("a clear in the queue hides the date", function()
  local projected = ReadHistory.project({ read { id = 20, finished_at = "2024-03-20" } }, {
    { kind = "read_dates", seq = 1, read_id = 20, clear = { finished_at = true } },
  })
  assert(projected[1].finished_at == nil)
end)

check("an addition and a removal", function()
  local projected = ReadHistory.project({ read { id = 20 } }, {
    { kind = "add_read", seq = 1, local_id = "local:1", read = { started_at = "2020-01-01",
      finished_at = "2020-01-02", edition = { edition_format = "E-Book" } } },
    { kind = "remove_read", seq = 2, read_id = 20 },
  })
  assert(#projected == 2, "a waiting removal must keep its row")
  assert(projected[1].pending_removal == true and projected[2].pending_add == true)
  assert(projected[2].id == "local:1" and projected[2].started_at == "2020-01-01")
end)

check("actions apply in queue order", function()
  local projected = ReadHistory.project({ read { id = 20, started_at = "2024-03-14" } }, {
    { kind = "read_dates", seq = 2, read_id = 20, change = { started_at = "2024-03-16" } },
    { kind = "read_dates", seq = 1, read_id = 20, change = { started_at = "2024-03-15" } },
  })
  assert(projected[1].started_at == "2024-03-16", projected[1].started_at)
end)

check("an edition change carries its format and page count before it is sent", function()
  local projected = ReadHistory.project({ read { id = 20, progress_pages = 300, finished_at = "2026-11-12",
    edition = { id = 7, pages = 304, edition_format = "Paperback" } } }, {
    { kind = "read_edition", seq = 1, read_id = 20,
      change = { edition_id = 8, progress_pages = 600 },
      edition = { edition_id = 8, pages = 608, edition_format = "E-book" } },
  })
  assert(projected[1].edition_id == 8 and projected[1].edition.pages == 608)
  assert(projected[1].edition.edition_format == "E-book")
  local summary = ReadHistory.summary(projected, { pages = 608 })
  assert(summary.support == "E-book", summary.support)
end)

print("\n== order and numbers ==")

check("newest first, with numbers as numbers", function()
  local rows = ReadHistory.normalize({
    { id = "20", started_at = "2024-03-14", progress_pages = "120", finished_at_precision = "2",
      edition = { pages = "300", reading_format_id = "1" } },
    { id = "21", started_at = "2026-11-03" },
  })
  assert(rows[1].id == 21 and rows[2].id == 20)
  assert(rows[2].progress_pages == 120 and rows[2].finished_at_precision == 2)
  assert(rows[2].edition.pages == 300 and rows[2].edition.reading_format_id == 1)
end)

check("the same day: the later id is newer", function()
  local rows = ReadHistory.normalize({
    { id = 20, started_at = "2024-03-14" },
    { id = 21, started_at = "2024-03-14" },
  })
  assert(rows[1].id == 21 and rows[2].id == 20)
end)

check("an unsent addition keeps its local id", function()
  local rows = ReadHistory.normalize({
    { id = "local:2", started_at = "2026-11-04" },
    { id = 21, started_at = "2026-11-04" },
  })
  assert(rows[1].id == "local:2", tostring(rows[1].id))
  assert(rows[2].id == 21, tostring(rows[2].id))
end)

check("ordinals", function()
  local cases = { { 1, "1st" }, { 2, "2nd" }, { 3, "3rd" }, { 4, "4th" }, { 10, "10th" },
    { 11, "11th" }, { 12, "12th" }, { 13, "13th" }, { 21, "21st" }, { 22, "22nd" },
    { 23, "23rd" }, { 101, "101st" }, { 111, "111th" } }
  for _, case in ipairs(cases) do
    assert(ReadHistory.ordinal(case[1]) == case[2], case[1] .. " -> " .. ReadHistory.ordinal(case[1]))
  end
end)

print("\n== page conversion ==")

check("the start of the book stays at the start", function()
  -- moveEdition's rule, unchanged: the first page's share rounds to its place in the new edition
  assert(ReadHistory.convertPage(1, 300, 600) == 2)
  assert(ReadHistory.convertPage(0, 300, 600) == 1)
end)

check("the last page stays the last", function()
  assert(ReadHistory.convertPage(300, 300, 600) == 600)
end)

check("a middle page moves by the same share", function()
  assert(ReadHistory.convertPage(150, 300, 600) == 300)
  assert(ReadHistory.convertPage(299, 300, 600) == 598)
end)

check("no page count means no invented conversion", function()
  assert(ReadHistory.convertPage(150, nil, 600) == 150)
  assert(ReadHistory.convertPage(150, 300, 0) == 150)
end)

r.finish()
