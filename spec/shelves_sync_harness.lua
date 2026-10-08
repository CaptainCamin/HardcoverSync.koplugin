-- Keeping the saved shelves right: what needs downloading, a first download against a
-- later one, waiting out rate limits, and the shelves an earlier version saved.
--
-- Run with:  lua spec/shelves_sync_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end
local r = support.reporter()

local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
local BookStore = require("hardcover/lib/book_store")
local ShelfStore = require("hardcover/lib/shelf_store")
local ShelfCache = require("hardcover/lib/shelf_cache")
local ShelvesSync = require("hardcover/lib/shelves_sync")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local FP1 = "2|T1|4.0"
local FP2 = "3|T2|4.0"

local function stores()
  local db = MemoryStore.new()
  local books = BookStore:new { db = db }
  return ShelfStore:new { db = db, books = books }, books, db
end

local function entry(id) return { user_book_id = 900 + id, book_id = id, status_id = 3, title = "Book " .. id,
                                   description = "Synopsis " .. id, date_added = "2026-01-01" } end
local function member(id) return { user_book_id = 900 + id, book_id = id, status_id = 3, date_added = "2026-01-01" } end

-- An API double. Pages are { rows, has_more } or { nil, err }.
local function fakeApi(spec)
  local api = { calls = {} }
  local function page(list)
    local p = table.remove(list or {}, 1)
    if not p then return nil, { completed = false } end
    return p[1], p[2], p[3]
  end
  function api:getShelf(_, status, offset, _, background)
    self.calls[#self.calls + 1] = { "shelf", status, offset, background }
    local rows, err, more = page(spec.shelf_pages)
    if rows == nil then return nil, err end
    return rows, nil, more
  end
  function api:getShelfMembers(_, status, offset, limit)
    self.calls[#self.calls + 1] = { "members", status, offset, limit }
    local rows, err, more = page(spec.member_pages)
    if rows == nil then return nil, err end
    return rows, nil, more
  end
  function api:getBooksByIds(ids)
    self.calls[#self.calls + 1] = { "byids", #ids, ids }
    local refuse = spec.byids_refusals or 0
    if refuse > 0 then
      spec.byids_refusals = refuse - 1
      return nil, { status = 429 }
    end
    local out = {}
    for i, id in ipairs(ids) do out[i] = entry(id) end
    return out
  end
  return api
end

local function download(api, shelves, books, extra)
  local slept = 0
  local opts = { api = api, shelves = shelves, books = books, user_id = 1, status_id = 3, fingerprint = FP2,
                 alive = function() return true end, sleep = function(s) slept = slept + s end }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local result = ShelvesSync.download(opts)
  return result, slept
end

print("\n== what needs downloading ==")

check("a shelf never saved, saved in part, changed here, or changed on Hardcover is downloaded", function()
  assert(ShelvesSync.needsDownload(nil, FP1))
  assert(ShelvesSync.needsDownload({ complete = false, fingerprint = FP1 }, FP1))
  assert(ShelvesSync.needsDownload({ complete = true, fingerprint = nil }, FP1), "a change made here was trusted")
  assert(ShelvesSync.needsDownload({ complete = true, fingerprint = FP1 }, FP2))
  assert(ShelvesSync.needsDownload({ complete = true, fingerprint = FP1 }, nil), "an unknown answer was trusted")
  assert(not ShelvesSync.needsDownload({ complete = true, fingerprint = FP1 }, FP1))
end)

check("a shelf checked in the last five minutes is trusted; one changed here never is", function()
  assert(ShelvesSync.fresh({ complete = true, fingerprint = FP1, checked_at = 1000 }, 1100))
  assert(not ShelvesSync.fresh({ complete = true, fingerprint = FP1, checked_at = 1000 }, 1000 + ShelvesSync.FRESH_FOR))
  assert(not ShelvesSync.fresh({ complete = true, fingerprint = nil, checked_at = 1000 }, 1100))
  assert(not ShelvesSync.fresh({ complete = true, fingerprint = FP1, checked_at = 1000 }, 900))
end)

check("For you's signature moves with counts and ratings, not with reading progress", function()
  local ids = { 1, 2, 3 }
  local before = ShelvesSync.ratingSignature({ [1] = "4|A|", [2] = "1|B|", [3] = "9|C|30.0" }, ids)
  local paged = ShelvesSync.ratingSignature({ [1] = "4|A|", [2] = "1|LATER|", [3] = "9|C|30.0" }, ids)
  local rated = ShelvesSync.ratingSignature({ [1] = "4|A|", [2] = "1|B|", [3] = "9|C|34.5" }, ids)
  assert(before and before == paged, "a page synced changed the signature")
  assert(rated ~= before, "a new rating did not")
  assert(ShelvesSync.ratingSignature({ [1] = "4|A|" }, ids) == nil, "a missing shelf gave a signature")
end)

print("\n== downloading a shelf ==")

check("the first download is the books, never cancelled by a tap, saved with the fingerprint", function()
  local shelves, books = stores()
  local api = fakeApi { shelf_pages = { { { entry(1), entry(2) }, nil, false }, { {}, nil, false } } }
  local result = download(api, shelves, books)
  assert(result.complete and #result.entries == 2)
  assert(api.calls[1][1] == "shelf" and api.calls[1][4] == true)
  local meta = shelves:meta(1, 3)
  assert(meta.complete and meta.fingerprint == FP2 and books:rows({ 1 })[1].description == "Synopsis 1")
end)

check("a later download asks which books the shelf holds, 500 at a time, then only the new books", function()
  local shelves, books = stores()
  shelves:putEntries(1, 3, { entry(1), entry(2) }, true, FP1)
  local api = fakeApi { member_pages = { { { member(3), member(1), member(2) }, nil, false }, { {}, nil, false } } }
  local result = download(api, shelves, books)
  assert(result.complete and #result.entries == 3 and result.entries[1].book_id == 3)
  assert(api.calls[1][1] == "members" and api.calls[1][4] == ShelvesSync.MEMBERS_PAGE)
  assert(api.calls[3][1] == "byids" and api.calls[3][2] == 1, "books it had were asked for again")
  assert(shelves:meta(1, 3).fingerprint == FP2)
end)

check("finishing one book costs the Read shelf one small request", function()
  local shelves, books = stores()
  local many = {}
  for i = 1, 611 do many[i] = entry(i) end
  shelves:putEntries(1, 3, many, true, FP1)
  books:saveDetail(700, nil, { book = { book_id = 700, title = "Just finished" } })
  local members = { member(700) }
  for i = 1, 611 do members[#members + 1] = member(i) end
  local api = fakeApi { member_pages = { { members, nil, false }, { {}, nil, false } } }
  local result = download(api, shelves, books)
  assert(result.complete and #result.entries == 612 and result.entries[1].title == "Just finished")
  -- the membership, and the empty page that says it ended: no book asked for
  assert(#api.calls == 2 and api.calls[2][1] == "members", "asked: " .. #api.calls .. " requests")
end)

check("a later download that fails partway leaves the saved shelf as it was", function()
  local shelves, books = stores()
  shelves:putEntries(1, 3, { entry(1), entry(2) }, true, FP1)
  local api = fakeApi { member_pages = {} }
  local result = download(api, shelves, books)
  assert(not result.complete)
  local meta = shelves:meta(1, 3)
  assert(meta.fingerprint == FP1 and #shelves:entries(1, 3) == 2)
end)

check("refused for going too fast while fetching books, it waits and asks again", function()
  local shelves, books = stores()
  shelves:putEntries(1, 3, { entry(1) }, true, FP1)
  local api = fakeApi { member_pages = { { { member(1), member(2) }, nil, false }, { {}, nil, false } }, byids_refusals = 2 }
  local result, slept = download(api, shelves, books)
  assert(result.complete and #result.entries == 2 and slept > 0, "slept " .. slept)
end)

check("Refresh downloads the books in full; a failed one keeps the whole saved shelf", function()
  local shelves, books = stores()
  shelves:putEntries(1, 3, { entry(1), entry(2) }, true, FP1)
  local api = fakeApi { shelf_pages = { { { entry(1) }, nil, true } } } -- page two fails
  download(api, shelves, books, { force = true })
  assert(#shelves:entries(1, 3) == 2 and shelves:meta(1, 3).complete)
  local fresh = entry(1)
  fresh.description = "Corrected"
  api = fakeApi { shelf_pages = { { { fresh }, nil, false }, { {}, nil, false } } }
  local result = download(api, shelves, books, { force = true })
  assert(result.complete and books:rows({ 1 })[1].description == "Corrected")
end)

check("shelves an earlier version saved need only their membership, and books cut short come whole", function()
  local shelves, books = stores()
  local data = {}
  local legacy = ShelfCache:new { path = "/x", open = function()
    return { readSetting = function(_, k) return data[k] end, saveSetting = function(_, k, v) data[k] = v end,
             flush = function() end }
  end }
  local cut = entry(2)
  cut.description = string.rep("x", 600) .. "\226\128\166"
  legacy:put(1, 3, { entry(1), cut }, true)
  shelves:convert(1, legacy, { 3 })
  local api = fakeApi { member_pages = { { { member(1), member(2) }, nil, false }, { {}, nil, false } } }
  local result = download(api, shelves, books)
  assert(api.calls[1][1] == "members", "the converted shelf was downloaded in full")
  assert(api.calls[3][1] == "byids" and api.calls[3][2] == 1 and api.calls[3][3][1] == 2)
  assert(result.complete and books:rows({ 2 })[2].description == "Synopsis 2", "the cut synopsis stayed cut")
end)

check("with no store the shelf is still downloaded, just not kept", function()
  local api = fakeApi { shelf_pages = { { { entry(1) }, nil, false }, { {}, nil, false } } }
  local result = ShelvesSync.download { api = api, user_id = 1, status_id = 3,
    alive = function() return true end, sleep = function() end }
  assert(result.complete and #result.entries == 1)
end)

check("stopped (the plugin is closing): nothing is saved and nil comes back", function()
  local shelves, books = stores()
  local api = fakeApi { shelf_pages = { { { entry(1) }, nil, false } } }
  local result = download(api, shelves, books, { alive = function() return false end })
  assert(result == nil and shelves:meta(1, 3) == nil)
end)

r.finish()
