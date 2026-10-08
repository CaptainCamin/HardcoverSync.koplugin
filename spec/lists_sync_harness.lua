-- Keeping the saved lists right: fingerprints, what needs downloading, a first download
-- against a later one, and the queue every list request goes through.
--
-- Run with:  lua spec/lists_sync_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end
local r = support.reporter()

local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
local BookStore = require("hardcover/lib/book_store")
local ListStore = require("hardcover/lib/list_store")
local Lists = require("hardcover/lib/lists")
local ListsSync = require("hardcover/lib/lists_sync")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local T1 = "2026-10-08T15:22:25.183388+00:00"
local T2 = "2026-10-09T09:00:00.000001+00:00"

local function listRow(id, updated_at, count, extra)
  local row = { id = id, source = "mine", name = "List " .. id, count = count or 2, ranked = false,
                updated_at = updated_at or T1, covers = {} }
  for k, v in pairs(extra or {}) do row[k] = v end
  row.fingerprint = Lists.fingerprint(row)
  return row
end

local function book(id) return { book_id = id, title = "Book " .. id, description = "Synopsis " .. id } end

local function stores()
  local db = MemoryStore.new()
  local books = BookStore:new { db = db }
  return books, ListStore:new { db = db, books = books }, db
end

print("\n== fingerprints ==")

check("a fingerprint is the time Hardcover last changed the list and its book count", function()
  assert(Lists.fingerprint({ updated_at = T1, count = 8 }) == T1 .. "|8")
  assert(Lists.fingerprint({ updated_at = T1, count = 8 }) ~= Lists.fingerprint({ updated_at = T1, count = 7 }))
end)

check("with no time there is no fingerprint, so the list is always fetched", function()
  assert(Lists.fingerprint({ count = 3 }) == nil and Lists.fingerprint({ updated_at = "", count = 3 }) == nil)
  assert(ListsSync.needsDownload({ count = 3 }, { complete = true, fingerprint = nil }))
end)

check("the count is the counted one, not the list's stored books_count (26 for 25 books)", function()
  local lists = Lists.normalize({ followed_lists = { { list = {
    id = 106, name = "Top 25", books_count = 26, updated_at = T1,
    list_books_aggregate = { aggregate = { count = 25 } }, user = { username = "hardcover" },
  } } } })
  local row = lists.following[1]
  assert(row.count == 25 and row.fingerprint == T1 .. "|25", tostring(row.fingerprint))
end)

check("an answer with no counted number falls back to books_count", function()
  local lists = Lists.normalize({ lists = { { id = 1, name = "L", books_count = 4, updated_at = T1 } } })
  assert(lists.mine[1].count == 4)
end)

check("Home's marks give the same fingerprint as the index for the same list", function()
  local me = {
    lists = { { id = 1, updated_at = T1, list_books_aggregate = { aggregate = { count = 3 } } } },
    followed_lists = { { list = { id = 2, updated_at = T2, list_books_aggregate = { aggregate = { count = 9 } } } } },
  }
  local marks = Lists.marks({ me })
  local index = Lists.normalize({ lists = { { id = 1, name = "a", updated_at = T1,
    list_books_aggregate = { aggregate = { count = 3 } } } } })
  assert(#marks == 2 and marks[1].source == "mine" and marks[2].source == "followed")
  assert(marks[1].fingerprint == index.mine[1].fingerprint)
end)

check("marks from junk are an empty list, not an error", function()
  assert(#Lists.marks(nil) == 0 and #Lists.marks("x") == 0 and #Lists.marks({ lists = "no" }) == 0)
end)

print("\n== what needs downloading ==")

check("a list never saved, saved in part, or changed since is downloaded; an unchanged one is not", function()
  local row = listRow(1)
  assert(ListsSync.needsDownload(row, nil))
  assert(ListsSync.needsDownload(row, { complete = false, fingerprint = row.fingerprint }))
  assert(ListsSync.needsDownload(row, { complete = true, fingerprint = T2 .. "|2" }))
  assert(not ListsSync.needsDownload(row, { complete = true, fingerprint = row.fingerprint }))
end)

check("the index is out of date when nothing is saved, a list came or went, or one moved", function()
  local index = { mine = { listRow(1) }, following = { listRow(2, T1, 5, { source = "followed" }) } }
  local marks = {
    { id = 1, source = "mine", fingerprint = index.mine[1].fingerprint },
    { id = 2, source = "followed", fingerprint = index.following[1].fingerprint },
  }
  assert(not ListsSync.indexChanged(index, marks), "an unchanged index was called changed")
  assert(ListsSync.indexChanged(nil, marks))
  assert(ListsSync.indexChanged(index, { marks[1] }), "a list that went was not seen")
  local moved = { marks[1], { id = 2, source = "followed", fingerprint = T2 .. "|5" } }
  assert(ListsSync.indexChanged(index, moved), "a list that moved was not seen")
  local added = { marks[1], marks[2], { id = 3, source = "mine", fingerprint = T1 .. "|0" } }
  assert(ListsSync.indexChanged(index, added), "a new list was not seen")
end)

check("the index is trusted for five minutes after a check, and a clock gone back is not trusted", function()
  local index = { checked_at = 1000 }
  assert(ListsSync.indexFresh(index, 1000 + 60))
  assert(not ListsSync.indexFresh(index, 1000 + ListsSync.FRESH_FOR))
  assert(not ListsSync.indexFresh(index, 900))
  assert(not ListsSync.indexFresh({}, 1000))
end)

print("\n== downloading a list ==")

-- An API double that records what was asked. Pages are { entries, has_more }.
local function fakeApi(spec)
  local api = { calls = {} }
  function api:getListBooks(id, _, _, offset, _, background)
    self.calls[#self.calls + 1] = { "books", id, offset, background }
    local p = table.remove(spec.book_pages or {}, 1)
    if not p then return nil, { completed = false } end
    return p[1], nil, p[2]
  end
  function api:getListMembers(id, _, offset)
    self.calls[#self.calls + 1] = { "members", id, offset }
    local p = table.remove(spec.member_pages or {}, 1)
    if not p then return nil, { completed = false } end
    return p[1], nil, p[2]
  end
  function api:getBooksByIds(ids)
    self.calls[#self.calls + 1] = { "byids", #ids }
    if spec.byids_fail then return nil, { status = 500 } end
    local out = {}
    for i, id in ipairs(ids) do out[i] = book(id) end
    return out
  end
  return api
end

local function download(api, lists, books, row, extra)
  local opts = { api = api, lists = lists, books = books, user_id = 1, row = row,
                 alive = function() return true end, sleep = function() end }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return ListsSync.download(opts)
end

local function members(ids)
  local out = {}
  for i, id in ipairs(ids) do out[i] = { list_book_id = 100 + id, position = i - 1, book_id = id } end
  return out
end

check("the first download is the books themselves, never cancelled by a tap, then saved", function()
  local books, lists = stores()
  local api = fakeApi { book_pages = { { { book(1), book(2) }, false } } }
  local result = download(api, lists, books, listRow(7))
  assert(result.complete and #result.entries == 2)
  assert(#api.calls == 1 and api.calls[1][1] == "books" and api.calls[1][4] == true, "asked: " .. #api.calls)
  local saved = lists:contents(1, 7)
  assert(saved.complete and saved.fingerprint == listRow(7).fingerprint)
  assert(books:rows({ 1 })[1].description == "Synopsis 1")
end)

check("a later download asks only which books the list holds, then just the new books", function()
  local books, lists = stores()
  lists:putEntries(1, listRow(7), { book(1), book(2) }, true)
  local api = fakeApi { member_pages = { { members({ 1, 2, 3 }), false } } }
  local result = download(api, lists, books, listRow(7, T2, 3))
  assert(result.complete and #result.entries == 3 and result.entries[3].book_id == 3)
  assert(#api.calls == 2 and api.calls[1][1] == "members" and api.calls[2][1] == "byids" and api.calls[2][2] == 1,
    "the books already saved were asked for again")
  assert(lists:contents(1, 7).fingerprint == T2 .. "|3")
end)

check("a list that only lost books costs one request", function()
  local books, lists = stores()
  lists:putEntries(1, listRow(7), { book(1), book(2) }, true)
  local api = fakeApi { member_pages = { { members({ 2 }), false } } }
  local result = download(api, lists, books, listRow(7, T2, 1))
  assert(#api.calls == 1 and #result.entries == 1 and result.entries[1].book_id == 2)
end)

check("many new books are asked for 100 at a time", function()
  local books, lists = stores()
  lists:putEntries(1, listRow(7), {}, true)
  local ids = {}
  for i = 1, 250 do ids[i] = i end
  local api = fakeApi { member_pages = { { members(ids), false } } }
  download(api, lists, books, listRow(7, T2, 250))
  local sizes = {}
  for _, c in ipairs(api.calls) do if c[1] == "byids" then sizes[#sizes + 1] = c[2] end end
  assert(#sizes == 3 and sizes[1] == 100 and sizes[3] == 50, table.concat(sizes, ","))
end)

check("a later download that fails partway leaves the saved list as it was", function()
  local books, lists = stores()
  lists:putEntries(1, listRow(7), { book(1), book(2) }, true)
  local api = fakeApi { member_pages = {} } -- every page fails
  local result = download(api, lists, books, listRow(7, T2, 3))
  assert(not result.complete)
  local saved = lists:contents(1, 7)
  assert(saved.complete and saved.fingerprint == listRow(7).fingerprint and #saved.members == 2)
end)

check("when the new books cannot be fetched the saved list stays, and says so", function()
  local books, lists = stores()
  lists:putEntries(1, listRow(7), { book(1) }, true)
  local api = fakeApi { member_pages = { { members({ 1, 2 }), false } }, byids_fail = true }
  local result = download(api, lists, books, listRow(7, T2, 2))
  assert(not result.complete and result.failure)
  assert(#lists:contents(1, 7).members == 1, "a half-updated list was saved")
end)

check("an interrupted first download is kept, marked incomplete", function()
  local books, lists = stores()
  local api = fakeApi { book_pages = { { { book(1) }, true } } } -- page two fails
  local result = download(api, lists, books, listRow(7))
  assert(not result.complete)
  local saved = lists:contents(1, 7)
  assert(saved and saved.complete == false and #saved.members == 1)
  assert(ListsSync.needsDownload(listRow(7), saved), "an incomplete list would never be finished")
end)

check("Refresh downloads the books in full even though the list is saved", function()
  local books, lists = stores()
  lists:putEntries(1, listRow(7), { book(1) }, true)
  local fresh = book(1)
  fresh.description = "Corrected synopsis"
  local api = fakeApi { book_pages = { { { fresh }, false } } }
  local result = download(api, lists, books, listRow(7), { force = true })
  assert(result.complete and api.calls[1][1] == "books")
  assert(books:rows({ 1 })[1].description == "Corrected synopsis")
end)

check("a Refresh that fails partway does not replace a whole saved list with part of one", function()
  local books, lists = stores()
  lists:putEntries(1, listRow(7), { book(1), book(2) }, true)
  local api = fakeApi { book_pages = { { { book(1) }, true } } }
  download(api, lists, books, listRow(7), { force = true })
  local saved = lists:contents(1, 7)
  assert(saved.complete and #saved.members == 2)
end)

check("stopped (the plugin is closing): nothing is saved and nil comes back", function()
  local books, lists = stores()
  local api = fakeApi { book_pages = { { { book(1) }, false } } }
  local result = download(api, lists, books, listRow(7), { alive = function() return false end })
  assert(result == nil and lists:contents(1, 7) == nil)
end)

check("with no store at all the list is still downloaded, just not kept", function()
  local api = fakeApi { book_pages = { { { book(1), book(2) }, false } } }
  local result = download(api, nil, nil, listRow(7))
  assert(result.complete and #result.entries == 2 and result.entries[1].title == "Book 1")
end)

print("\n== one queue ==")

-- A queue whose background block is run by hand, one step at a time, like KOReader
-- resuming a coroutine when a request comes back.
local function steppedQueue(alive)
  local blocks = {}
  local queue = ListsSync.newQueue {
    run = function(fn) blocks[#blocks + 1] = coroutine.create(fn) end,
    alive = alive,
  }
  local function step()
    for _, co in ipairs(blocks) do
      if coroutine.status(co) == "suspended" then
        local ok, err = coroutine.resume(co)
        assert(ok, err)
      end
    end
  end
  return queue, step, blocks
end

check("jobs run one after another, never two at once", function()
  local queue, step, blocks = steppedQueue()
  local in_flight, most, order = 0, 0, {}
  local function job(key)
    return { key = key, work = function()
      in_flight = in_flight + 1
      most = math.max(most, in_flight)
      coroutine.yield() -- the request is out
      in_flight = in_flight - 1
      order[#order + 1] = key
      return key
    end }
  end
  queue:add(job("a")); queue:start()
  queue:add(job("b")); queue:start()
  queue:add(job("c")); queue:start()
  assert(#blocks == 1, "a second runner was started")
  for _ = 1, 6 do step() end
  assert(most == 1 and table.concat(order) == "abc", "most at once: " .. most .. ", order " .. table.concat(order))
end)

check("a job already queued or running is not queued twice; whoever waits for it hears once", function()
  local queue, step = steppedQueue()
  local runs, heard = 0, {}
  local job = { key = "list:1", work = function() runs = runs + 1; coroutine.yield(); return "done" end }
  queue:wait("list:1", function(res) heard[#heard + 1] = res end)
  assert(queue:add(job)); queue:start()
  step() -- running now
  queue:wait("list:1", function(res) heard[#heard + 1] = res end)
  assert(not queue:add(job), "a running job was queued again")
  for _ = 1, 3 do step() end
  assert(runs == 1 and #heard == 2 and heard[1] == "done" and heard[2] == "done")
end)

check("a screen waiting on a list moves it to the front", function()
  local queue, step = steppedQueue()
  local order = {}
  local function job(key) return { key = key, work = function() coroutine.yield(); order[#order + 1] = key end } end
  queue:add(job("first")); queue:start()
  step()
  queue:add(job("a")); queue:add(job("b")); queue:add(job("c"))
  queue:add(job("c"), true)
  for _ = 1, 10 do step() end
  assert(table.concat(order, " ") == "first c a b", table.concat(order, " "))
end)

check("a job that raises does not stop the queue", function()
  local queue, step = steppedQueue()
  local heard
  queue:wait("bad", function(res) heard = res == nil and "nothing" or res end)
  queue:add({ key = "bad", work = function() error("boom") end })
  local ran = false
  queue:add({ key = "good", work = function() ran = true end })
  queue:start()
  for _ = 1, 3 do step() end
  assert(ran and heard == "nothing" and not queue.running)
end)

check("closing stops the queue between jobs, and whoever waits is told nothing will come", function()
  local open = true
  local queue, step = steppedQueue(function() return open end)
  local heard = {}
  queue:add({ key = "a", work = function() coroutine.yield(); open = false; return "a" end })
  queue:add({ key = "b", work = function() error("must not run") end })
  queue:wait("b", function(res) heard[#heard + 1] = res == nil end)
  queue:start()
  for _ = 1, 4 do step() end
  assert(heard[1] == true and #queue.jobs == 0 and not queue.running)
end)

r.finish()
