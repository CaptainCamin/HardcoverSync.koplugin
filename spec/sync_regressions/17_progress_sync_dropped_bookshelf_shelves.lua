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

KB.finish("only a real status change may drop Bookshelf's shelves")
