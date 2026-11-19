-- BUG: every progress sync and every book open emptied Bookshelf's in-memory shelves.
--
-- main.lua asked "was status_id in this change?", and saveBookSnapshot always writes the
-- status the book already has. Each return to the file browser then decoded whole saved
-- shelves again from SQLite to show a dozen books.
--
-- Expected: only a status that really changes is reported as a change.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()

table.unpack = table.unpack or unpack
KB.support.preload_koreader_stubs()
package.preload["version"] = function() return { getNormalizedCurrentVersion = function() return 999999999999 end } end
package.preload["luasettings"] = function()
  local LS = {}
  LS.__index = LS
  function LS:open() return setmetatable({ data = {} }, LS) end
  function LS:readSetting(k, default)
    if self.data[k] == nil and default ~= nil then self.data[k] = default end
    return self.data[k]
  end
  function LS:saveSetting(k, v) self.data[k] = v end
  function LS:flush() end
  return LS
end
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local SETTING = require("hardcover/lib/constants/settings")
local FILE = "/books/a.epub"

local function watch()
  local settings = HardcoverSettings:new("/nonexistent/settings.lua", { document = { file = FILE } })
  local changes = {}
  settings:subscribe(function(field, change, original)
    if field == SETTING.BOOKS then
      changes[#changes + 1] = HardcoverSettings.statusChanged(change.config, original)
    end
  end)
  return settings, changes
end

KB.check("saving the same status again is not a status change", function()
  local settings, changes = watch()
  local book = { id = 5, status_id = 2, user_book_reads = { { id = 9, progress_pages = 10 } } }
  settings:saveBookSnapshot(FILE, book) -- the first time the book is seen
  settings:saveBookSnapshot(FILE, book) -- a progress sync
  book.user_book_reads[1].progress_pages = 20
  settings:saveBookSnapshot(FILE, book)
  KB.eq(changes[1], true, "the first snapshot sets a status")
  KB.eq(changes[2], false, "a repeated snapshot reported as a status change")
  KB.eq(changes[3], false, "a progress sync reported as a status change")
end)

KB.check("a different status is a change", function()
  local settings, changes = watch()
  settings:saveBookSnapshot(FILE, { id = 5, status_id = 2 })
  settings:saveBookSnapshot(FILE, { id = 5, status_id = 3 })
  KB.eq(changes[2], true, "moving to Read was not reported")
end)

KB.check("clearing a saved status is a change, clearing none is not", function()
  local settings, changes = watch()
  settings:saveBookSnapshot(FILE, { id = 5, status_id = 2 })
  settings:clearBookSnapshot(FILE)
  settings:clearBookSnapshot(FILE)
  KB.eq(changes[2], true, "clearing a status was not reported")
  KB.eq(changes[3], false, "clearing nothing was reported")
end)

KB.check("clearing a removed book keeps every other link on its files", function()
  local settings, _ = watch()
  local other = "/books/other.epub"
  settings:updateBookSetting(FILE, { book_id = 7, edition_id = 3, sync = true })
  settings:updateBookSetting(other, { book_id = 8, edition_id = 4, sync = true })
  settings:saveBookSnapshot(FILE, { id = 70, edition_id = 3, status_id = 2,
    user_book_reads = { { id = 9, progress_pages = 12 } } })
  settings:saveBookSnapshot(other, { id = 80, edition_id = 4, status_id = 3, user_book_reads = {} })

  settings:clearBookSnapshotsFor(7)
  KB.eq(settings:bookStatusFromSnapshot(FILE), nil, "the removed book's snapshot survived")
  KB.eq(settings:readRemovedMarker(FILE), true, "an offline reopen could treat the book as unknown")
  KB.eq(settings:readBookSetting(FILE, "book_id"), 7, "the link was cleared with the snapshot")
  KB.eq(settings:readBookSetting(FILE, "edition_id"), 3, "the linked edition was cleared")
  KB.eq(settings:readBookSetting(other, "book_id"), 8, "another book's link changed")
  KB.eq(settings:bookStatusFromSnapshot(other).id, 80, "another book's snapshot was cleared")

  -- The marker belongs to the book that was removed, not to whichever book a
  -- later relink assigns to the file.
  settings:updateBookSetting(FILE, { book_id = 99 })
  KB.eq(settings:readRemovedMarker(FILE), false, "the marker followed a later relink")
  settings:updateBookSetting(FILE, { book_id = 7 })
  settings:clearRemovedMarkersFor(7)
  KB.eq(settings:readRemovedMarker(FILE), false, "a confirmed re-add kept the marker")
  KB.eq(settings:readBookSetting(FILE, "edition_id"), 3, "re-add lifted the linked edition")

  -- The removal marker is set again before checking that a new record clears it.
  settings:clearBookSnapshotsFor(7)
  -- A new library record, online or replayed, lifts the block again.
  settings:saveBookSnapshot(FILE, { id = 71, edition_id = 3, status_id = 2, user_book_reads = {} })
  KB.eq(settings:readRemovedMarker(FILE), false, "a new record kept the removed marker")
  KB.eq(settings:bookStatusFromSnapshot(FILE).id, 71, "the new record was not restored offline")

  -- A re-add from the details screen restores tracking state without switching
  -- the linked file to a different edition.
  settings:clearBookSnapshotsFor(7)
  settings:saveShelfSnapshot(FILE, { id = 72, book_id = 7, status_id = 3,
    user_book_reads = { { id = 12, progress_pages = 4, started_at = "2026-11-19" } } })
  KB.eq(settings:readRemovedMarker(FILE), false, "the re-add kept the removal marker")
  KB.eq(settings:bookStatusFromSnapshot(FILE).id, 72, "offline tracking has no restored status")
  KB.eq(settings:bookStatusFromSnapshot(FILE).status_id, 3, "the re-added shelf was not saved")
  KB.eq(settings:readBookSetting(FILE, "edition_id"), 3, "the re-add switched the linked edition")
end)

KB.finish("only a real status change may drop Bookshelf's shelves")
