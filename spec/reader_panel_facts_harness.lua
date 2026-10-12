-- What the reader panel says in each state: the page or length line under the title, the shelf line
-- (not for Currently Reading), the progress switch and the note under it.
--
-- Run with:  luajit spec/reader_panel_facts_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local Facts = require("hardcover/lib/reader_panel_facts")
local S = require("hardcover/lib/constants/hardcover").STATUS

local function describe(o)
  o.linked = o.linked ~= false
  if o.pages == nil then o.pages = 387 end
  if o.sync_on == nil then o.sync_on = true end
  return Facts.describe(o)
end
local DOT = "  \194\183  "

print("\n== Currently Reading ==")
local reading = describe { status_id = S.READING, saved_page = 120, status_label = "Currently Reading" }
r.check("page line: where you are", reading.line == "Page 120 of 387" .. DOT .. "31%", reading.line)
r.check("no shelf line", reading.shelf == nil, reading.shelf)
r.check("switch offered, no note", reading.track == true and reading.track_note == nil)
r.check("not finished: no Read again", not reading.finished)
r.check("just started: page 0, still a page line",
  describe { status_id = S.READING, status_label = "Currently Reading" }.line == "Page 0 of 387" .. DOT .. "0%")
local reading_off = describe { status_id = S.READING, status_label = "Currently Reading", sync_on = false }
r.check("tracking off while reading: switch still offered, no note", reading_off.track == true and reading_off.track_note == nil)

print("\n== Want to Read (reading it asks to start it, so there is no switch while tracking is on) ==")
local want = describe { status_id = S.TO_READ, status_label = "Want to Read" }
r.check("length, not a page", want.line == "387 pages", want.line)
r.check("shelf line", want.shelf == "On your 'Want to Read' shelf", want.shelf)
r.check("tracking on: no switch, no note", want.track == false and want.track_note == nil)
r.check("tracking on: says reading will ask", want.hint == "After 5 pages you'll be asked to start reading.", want.hint)
r.check("the threshold setting is used",
  describe { status_id = S.TO_READ, status_label = "Want to Read", start_pages = 12 }.hint == "After 12 pages you'll be asked to start reading.")
r.check("a threshold of one page",
  describe { status_id = S.TO_READ, status_label = "Want to Read", start_pages = 1 }.hint == "After 1 page you'll be asked to start reading.")
local want_off = describe { status_id = S.TO_READ, status_label = "Want to Read", sync_on = false }
r.check("tracking off: the switch comes back, with how to update by hand",
  want_off.track == true and want_off.track_note == "Change status to update progress.", want_off.track_note)
r.check("tracking off: no hint (the note is under the switch)", want_off.hint == nil)
r.check("no hint while reading or finished",
  reading.hint == nil and describe { status_id = S.FINISHED, status_label = "Read" }.hint == nil)

print("\n== On no shelf, and shelf not checked ==")
local none = describe { not_on_shelf = true }
r.check("no shelf: line and length", none.shelf == "Not on a shelf" and none.line == "387 pages")
r.check("no shelf, tracking on: no switch, the same hint", none.track == false and none.hint == "After 5 pages you'll be asked to start reading.")
local none_off = describe { not_on_shelf = true, sync_on = false }
r.check("no shelf, tracking off: switch and the same note", none_off.track == true and none_off.track_note == "Change status to update progress.")
local unknown = describe {}
r.check("not checked yet: says so", unknown.shelf == "Shelf not checked yet")
r.check("not checked yet, tracking on: no switch, the same hint", unknown.track == false and unknown.track_note == nil
  and unknown.hint == "After 5 pages you'll be asked to start reading.", unknown.hint)
r.check("not checked yet: the hint follows the threshold setting", describe { start_pages = 8 }.hint == "After 8 pages you'll be asked to start reading.")
local unknown_off = describe { sync_on = false }
r.check("not checked yet, tracking off: switch, no note, no hint (nothing is known to change)",
  unknown_off.track == true and unknown_off.track_note == nil and unknown_off.hint == nil)

print("\n== Asking the saved shelves ==")
local function shelves(members, synced)
  return {
    member = function(_, _, book_id) return members[book_id] end,
    synced = function() return synced end,
  }
end
local ids = { S.TO_READ, S.READING, S.FINISHED, S.DNF }
local sid, nos = Facts.fromShelves(shelves({ [7] = { status_id = S.TO_READ } }, false), 1, 7, ids)
r.check("on a saved shelf: its status, even if the shelves are not all saved", sid == S.TO_READ and nos == nil)
sid, nos = Facts.fromShelves(shelves({}, true), 1, 7, ids)
r.check("on none of the shelves, all saved: not on a shelf", sid == nil and nos == true)
sid, nos = Facts.fromShelves(shelves({}, false), 1, 7, ids)
r.check("on none, shelves not all saved: unknown, so 'not checked'", sid == nil and nos == nil)
r.check("no shelves or no book: unknown", select(2, Facts.fromShelves(nil, 1, 7, ids)) == nil
  and select(2, Facts.fromShelves(shelves({}, true), 1, nil, ids)) == nil)

print("\n== Finished and Did not finish ==")
local done = describe { status_id = S.FINISHED, saved_page = 387, status_label = "Read" }
r.check("finished, tracking on: Read again, no switch, no note", done.finished and not done.track and done.track_note == nil)
r.check("finished: shelf line", done.shelf == "On your 'Read' shelf", done.shelf)
r.check("finished with the last page saved: how far", done.line == "Page 387 of 387" .. DOT .. "100%", done.line)
r.check("finished, tracking off: the switch is offered so it can be turned back on",
  describe { status_id = S.FINISHED, status_label = "Read", sync_on = false }.track == true)
local dnf = describe { status_id = S.DNF, status_label = "Did Not Finish" }
r.check("did not finish, nothing saved: length, never Page 0", dnf.line == "387 pages" and dnf.finished and not dnf.track, dnf.line)
r.check("did not finish, page 120 saved: how far",
  describe { status_id = S.DNF, saved_page = 120, status_label = "Did Not Finish" }.line == "Page 120 of 387" .. DOT .. "31%")

print("\n== Edge cases ==")
r.check("unknown length: no line at all", describe { status_id = S.TO_READ, status_label = "Want to Read", pages = false }.line == nil)
r.check("a one-page book", describe { status_id = S.TO_READ, status_label = "Want to Read", pages = 1 }.line == "1 page")
local unlinked = Facts.describe { linked = false }
r.check("not linked: says so, nothing else", unlinked.line == "Not linked to Hardcover" and unlinked.shelf == nil and not unlinked.track)
r.finish()
