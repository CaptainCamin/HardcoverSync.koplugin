-- BUG: relinking a file to a different book keeps the previous book's local
-- snapshot (user_book_id, read_id, status, started_at, last_synced_page) and its
-- queued entry, so the new book's progress is written onto the OLD book's read.
--
-- Hardcover:linkBook (hardcover/lib/hardcover.lua) rewrites book_id/edition_id/
-- title/pages but never calls HardcoverSettings:clearBookSnapshot (that method
-- is defined and never used anywhere). Cache:cacheUserBook then finds no
-- user_book for the new book, falls back to hydrateBookStatus(file), and
-- bookStatusFromSnapshot returns the OLD book's ids stamped with the NEW
-- book_id. The next page update goes to Api:updatePage(<old read id>, ...).
-- A queued entry is likewise kept (status_id / read_id / started_at of the old
-- book are merged into the new book's entry by SyncQueue:_ensure).
--
-- Expected: after relinking, nothing of the old book's identity is used.
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
KB.stub_koreader()

table.unpack = table.unpack or unpack -- KOReader provides this on LuaJIT
KB.support.preload_koreader_stubs()
package.preload["version"] = function() return { getNormalizedCurrentVersion = function() return 999999999999 end } end
package.preload["ui/widget/notification"] = function()
  return { new = function(_, o) return o end }
end
-- LuaSettings stand-in that, like the real one, hands back live tables
-- (support.lua's copies tables, which would hide in-place updates)
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
package.preload["util"] = function() return { tableDeepCopy = function(t) return t end } end

local LuaSettings = require("luasettings")
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local Api = require("hardcover/lib/hardcover_api")
local Cache = require("hardcover/lib/cache")
local Hardcover = require("hardcover/lib/hardcover")
local User = require("hardcover/lib/user")
local SyncQueue = require("hardcover/lib/sync_queue")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local FILE = "/books/a.epub"

print("\n== relinking a file to another book ==")

local function setup()
  local ui = { document = { file = FILE } }
  local settings = HardcoverSettings:new("/nonexistent/settings.lua", ui)
  settings:updateSetting("user_id", 1)
  User.settings = settings
  -- linked to book 7 (A), which has a user_book 500 with read 900 at page 100
  settings:updateBookSetting(FILE, { book_id = 7, edition_id = 3, title = "A", pages = 300, sync = true })
  settings:saveBookSnapshot(FILE, { id = 500, book_id = 7, status_id = HARDCOVER.STATUS.READING, edition_id = 3,
    user_book_reads = { { id = 900, progress_pages = 100, started_at = "2026-01-01", edition_id = 3 } } })
  local queue = SyncQueue:new { settings = LuaSettings:open() }
  local state = { book_status = {} }
  local cache = Cache:new { settings = settings, state = state, sync_queue = queue }
  local hc = Hardcover:new { cache = cache, settings = settings, state = state, ui = ui }
  return settings, queue, state, cache, hc
end

KB.check("after relinking to an unshelved book, page updates do not target the old read", function()
  local settings, queue, state, cache, hc = setup()
  local page_calls = {}
  Api.findUserBook = function() return nil end -- book B is not on the shelf yet
  Api.updatePage = function(_, read_id, _, page) page_calls[#page_calls + 1] = { read_id = read_id, page = page } return nil end
  Api.createRead = function() return nil end
  Api.updateUserBook = function() return nil end

  -- relink to book 8 (B), a book with no edition chosen
  hc:linkBook({ book_id = 8, title = "B", pages = 250 })
  cache:syncPage(FILE, 40) -- the reader turns a page of B online

  for _, c in ipairs(page_calls) do
    if c.read_id == 900 then
      error("updatePage(read " .. c.read_id .. ", page " .. c.page .. ") hit the OLD book's read", 0)
    end
  end
end)

KB.check("relinking drops the old book's snapshot", function()
  local settings, _, _, _, hc = setup()
  Api.findUserBook = function() return nil end
  Api.updateUserBook = function() return nil end
  hc:linkBook({ book_id = 8, title = "B", pages = 250 })
  KB.eq(settings:readBookSetting(FILE, "user_book_id"), nil, "user_book_id of the old book")
  KB.eq(settings:readBookSetting(FILE, "read_id"), nil, "read_id of the old book")
end)

KB.check("a queued entry of the old book is not replayed against the new one", function()
  local _, queue, _, _, hc = setup()
  queue:enqueueStatus(FILE, { status_id = HARDCOVER.STATUS.FINISHED, book_id = 7, read_id = 900, started_at = "2026-01-01" })
  Api.findUserBook = function() return nil end
  Api.updateUserBook = function() return nil end
  hc:linkBook({ book_id = 8, title = "B", pages = 250 })
  -- the next page turn on B merges into the old entry
  queue:enqueuePage(FILE, { mapped_page = 5, book_id = 8 })
  local e = queue:get(FILE)
  KB.eq(e.status_id, nil, "status carried over from the old book (Finished would be applied to B)")
end)

KB.finish("relinking must discard the previous book's snapshot and queued entry")
