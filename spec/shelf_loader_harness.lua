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

-- A fetch that answers from a script: a list of replies, one per call, each
-- { entries, err, has_more }.
local function scripted(replies)
  local api = { calls = {} }
  api.fetch = function(offset, limit)
    api.calls[#api.calls + 1] = { offset = offset, limit = limit }
    local reply = replies[#api.calls] or { {} }
    return reply[1], reply[2], reply[3]
  end
  return api
end

local function run(api, extra)
  local opts = {
    fetch = api.fetch or api.getShelf,
    network = { connected = function() return true end },
    dedupe = true,
    alive = function() return true end,
    sleep = function() end,
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
  assert(api.calls[1].limit == ShelfLoader.PAGE_SIZE)
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
  local api = { fetch = function() n = n + 1; return { book(n) } end }
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
  local api = { fetch = function() online = false; return { book(1) } end }
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
  local api = { fetch = function() up = false; return { book(1) } end }
  local result, opts = run(api, { alive = function() return up end })
  assert(result == nil)
end)

print("\n== a list: the same loop, told by the server when it ends ==")

check("with use_has_more the load ends on the page that says no more", function()
  local api = scripted({ { { book(1), book(2) }, nil, true }, { { book(3) }, nil, false } })
  local result = run(api, { use_has_more = true })
  assert(result.complete and #result.entries == 3 and #api.calls == 2, "calls: " .. #api.calls)
end)

check("without use_has_more a missing has_more is not an ending", function()
  local api = scripted({ { { book(1) } }, { { book(2) } }, { {} } })
  local result = run(api)
  assert(#api.calls == 3 and #result.entries == 2)
end)

check("a list keeps a book that appears twice when not de-duplicating", function()
  local api = scripted({ { { book(1), book(1) }, nil, false } })
  local result = run(api, { use_has_more = true, dedupe = false })
  assert(#result.entries == 2, "entries: " .. #result.entries)
end)

check("without a network check the load does not look for one", function()
  local api = scripted({ { { book(1) }, nil, false } })
  local result = run(api, { use_has_more = true, network = false })
  assert(result.complete)
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
