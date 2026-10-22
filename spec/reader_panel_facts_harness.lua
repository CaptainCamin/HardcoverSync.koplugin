-- What the reader panel says in each state: the page or length line under the title, the shelf line
-- (not for Currently Reading).
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
  return Facts.describe(o)
end
local DOT = "  \194\183  "

print("\n== Paused ==")
local paused = describe { status_id = S.PAUSED, saved_page = 120, status_label = "Paused" }
r.check("paused: Resume, not Read again", paused.paused == true and not paused.finished)
r.check("paused: shelf line", paused.shelf == "On your 'Paused' shelf", paused.shelf)
r.check("reading is not paused", describe { status_id = S.READING, status_label = "Currently Reading" }.paused == false)

print("\n== Currently Reading ==")
local reading = describe { status_id = S.READING, saved_page = 120, status_label = "Currently Reading" }
r.check("page line: where you are", reading.line == "Page 120 of 387" .. DOT .. "31%", reading.line)
r.check("no shelf line", reading.shelf == nil, reading.shelf)
r.check("not finished: no Read again", not reading.finished)
r.check("just started: page 0, still a page line",
  describe { status_id = S.READING, status_label = "Currently Reading" }.line == "Page 0 of 387" .. DOT .. "0%")
print("\n== Want to Read ==")
local want = describe { status_id = S.TO_READ, status_label = "Want to Read" }
r.check("length, not a page", want.line == "387 pages", want.line)
r.check("shelf line", want.shelf == "On your 'Want to Read' shelf", want.shelf)
print("\n== On no shelf, and shelf not checked ==")
local none = describe { not_on_shelf = true }
r.check("no shelf: line and length", none.shelf == "Not on a shelf" and none.line == "387 pages")
local unknown = describe {}
r.check("not checked yet: says so", unknown.shelf == "Shelf not checked yet")
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
r.check("finished: Read again", done.finished)
r.check("finished: shelf line", done.shelf == "On your 'Read' shelf", done.shelf)
r.check("finished with the last page saved: how far", done.line == "Page 387 of 387" .. DOT .. "100%", done.line)
local dnf = describe { status_id = S.DNF, status_label = "Did Not Finish" }
r.check("did not finish, nothing saved: length, never Page 0", dnf.line == "387 pages" and dnf.finished, dnf.line)
r.check("did not finish, page 120 saved: how far",
  describe { status_id = S.DNF, saved_page = 120, status_label = "Did Not Finish" }.line == "Page 120 of 387" .. DOT .. "31%")

print("\n== Edge cases ==")
r.check("unknown length: no line at all", describe { status_id = S.TO_READ, status_label = "Want to Read", pages = false }.line == nil)
r.check("a one-page book", describe { status_id = S.TO_READ, status_label = "Want to Read", pages = 1 }.line == "1 page")
local unlinked = Facts.describe { linked = false }
r.check("not linked: says so, nothing else", unlinked.line == "Not linked to Hardcover" and unlinked.shelf == nil)
r.finish()
