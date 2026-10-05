-- The shelf loader: paging, retries, rate limits, de-duplication, and what the
-- screen should do with how a load ended. No KOReader, no UI: the API, the network
-- and the "screen is still up" test are fakes.
--
-- Run with:  lua spec/shelf_loader_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local ShelfLoader = require("hardcover/lib/shelf_loader")

local function book(id) return { book_id = id, user_book_id = id } end

-- An API that answers from a script: a list of replies, one per getShelf call.
local function scripted(replies)
  local api = { calls = {} }
  function api:getShelf(user_id, status_id, offset, limit)
    self.calls[#self.calls + 1] = { user_id = user_id, status_id = status_id, offset = offset, limit = limit }
    local reply = replies[#self.calls] or { {} }
    return reply[1], reply[2]
  end
  return api
end

local function run(api, extra)
  local opts = {
    api = api,
    network = { connected = function() return true end },
    alive = function() return true end,
    sleep = function() end,
    user_id = 7,
    status_id = 2,
  }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return ShelfLoader.load(opts), opts
end

print("\n== paging ==")

check("pages are asked for until one comes back empty", function()
  local api = scripted({ { { book(1), book(2) } }, { { book(3) } }, { {} } })
  local result = run(api)
  assert(result.complete and #result.entries == 3, "entries: " .. #result.entries)
  assert(#api.calls == 3, "calls: " .. #api.calls)
  assert(api.calls[1].offset == 0 and api.calls[2].offset == 2 and api.calls[3].offset == 3, "offsets")
  assert(api.calls[1].limit == ShelfLoader.PAGE_SIZE and api.calls[1].user_id == 7 and api.calls[1].status_id == 2)
end)

check("a short page is not the end: only an empty one is", function()
  local api = scripted({ { { book(1) } }, { { book(2) } }, { {} } })
  local result = run(api)
  assert(#result.entries == 2 and result.complete)
end)

check("a book shifted into a later page is not listed twice", function()
  local api = scripted({ { { book(1), book(2) } }, { { book(2), book(3) } }, { {} } })
  local result = run(api)
  assert(#result.entries == 3, "entries: " .. #result.entries)
end)

check("on_page hears of each page that had books, with everything so far", function()
  local api = scripted({ { { book(1), book(2) } }, { { book(3) } }, { {} } })
  local sizes = {}
  run(api, { on_page = function(fresh) sizes[#sizes + 1] = #fresh end })
  assert(table.concat(sizes, ",") == "2,3", table.concat(sizes, ","))
end)

check("a shelf that never ends stops at the page limit, incomplete", function()
  local n = 0
  local api = { getShelf = function() n = n + 1; return { book(n) } end }
  local result = run(api)
  assert(n == ShelfLoader.MAX_PAGES and not result.complete, "pages: " .. n)
  assert(#result.entries == ShelfLoader.MAX_PAGES)
end)

print("\n== retries ==")

check("a cancelled page is asked for again, up to the limit", function()
  local cancelled = { nil, { completed = false } }
  local api = scripted({ cancelled, cancelled, { { book(1) } }, { {} } })
  local result = run(api)
  assert(result.complete and #result.entries == 1)
  assert(#api.calls == 4)
  assert(api.calls[1].offset == 0 and api.calls[2].offset == 0 and api.calls[3].offset == 0, "same page again")
end)

check("a page cancelled too many times fails the load", function()
  local cancelled = { nil, { completed = false } }
  local api = scripted({ cancelled, cancelled, cancelled, cancelled, cancelled })
  local result = run(api)
  assert(not result.complete and result.failure and result.failure.completed == false)
  assert(#api.calls == ShelfLoader.PAGE_RETRIES + 1, "calls: " .. #api.calls)
end)

check("the retry count starts over after a page that worked", function()
  local cancelled = { nil, { completed = false } }
  local api = scripted({ cancelled, cancelled, { { book(1) } },
    cancelled, cancelled, { { book(2) } }, { {} } })
  local result = run(api)
  assert(result.complete and #result.entries == 2)
end)

check("a 429 waits longer each time, then asks again", function()
  local slow = { nil, { status = 429 } }
  local api = scripted({ slow, slow, { { book(1) } }, { {} } })
  local waits = {}
  local result = run(api, { sleep = function(s) waits[#waits + 1] = s end })
  assert(result.complete)
  assert(table.concat(waits, ",") == "2,4", table.concat(waits, ","))
end)

check("a 429 that will not clear fails the load after the allowed waits", function()
  local slow = { nil, { status = 429 } }
  local replies = {}
  for i = 1, 10 do replies[i] = slow end
  local waits = 0
  local result = run(scripted(replies), { sleep = function() waits = waits + 1 end })
  assert(not result.complete and result.failure.status == 429)
  assert(waits == ShelfLoader.RATE_LIMIT_WAITS, "waits: " .. waits)
end)

check("any other failure ends the load at once, keeping what arrived", function()
  local api = scripted({ { { book(1) } }, { nil, "boom" } })
  local result = run(api)
  assert(not result.complete and result.failure == "boom" and #result.entries == 1)
  assert(#api.calls == 2)
end)

print("\n== when the world changes ==")

check("going offline mid-load ends it with the offline message", function()
  local online = true
  local api = { getShelf = function() online = false; return { book(1) } end }
  local result = run(api, { network = { connected = function() return online end } })
  assert(not result.complete and #result.entries == 1)
  assert(result.failure == "no internet connection", tostring(result.failure))
end)

check("a screen closed before the load returns nil and asks for nothing", function()
  local api = scripted({})
  local result = run(api, { alive = function() return false end })
  assert(result == nil and #api.calls == 0)
end)

check("a screen closed while a page was in flight returns nil", function()
  local up = true
  local api = { getShelf = function() up = false; return { book(1) } end }
  local result, opts = run(api, { alive = function() return up end })
  assert(result == nil)
end)

print("\n== what the screen does with the outcome ==")

check("a complete load replaces the shelf, saved copy or not", function()
  assert(ShelfLoader.plan({ complete = true, entries = {} }, true) == "replace")
  assert(ShelfLoader.plan({ complete = true, entries = {} }, false) == "replace")
end)

check("an interrupted load leaves a saved copy alone", function()
  assert(ShelfLoader.plan({ complete = false, entries = { book(1) } }, true) == "keep")
  assert(ShelfLoader.plan({ complete = false, entries = {} }, true) == "keep")
end)

check("an interrupted load with no saved copy keeps what arrived", function()
  assert(ShelfLoader.plan({ complete = false, entries = { book(1) } }, false) == "partial")
end)

check("nothing arrived and nothing saved offers the retry", function()
  assert(ShelfLoader.plan({ complete = false, entries = {} }, false) == "retry")
end)

r.finish()
