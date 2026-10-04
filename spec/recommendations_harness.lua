-- Books like this: the ids Hardcover ranks (trimmed, de-duplicated), the books put
-- back in that order, and the two requests Api:getSimilarBooks sends (against a
-- stubbed Api:query), including the answers that are not what was hoped for.
--
-- Run with:  lua spec/recommendations_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

package.preload["ui/uimanager"] = function()
  return { show = function() end, close = function() end, isWidgetShown = function() return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    forceRePaint = function() end, nextTick = function() end }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) local co = coroutine.create(fn); local ok, err = coroutine.resume(co)
    if not ok then error("wrapped function raised: " .. tostring(err), 0) end end }
end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local Api = real_require("hardcover/lib/hardcover_api")
local real_query = Api.query
local Goals = real_require("hardcover/lib/goals")
local Lists = real_require("hardcover/lib/lists")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- a scripted Api:query: each call takes the next answer, and every request is kept
local sent, script
local function answers(...)
  Api.enabled = true
  sent, script = {}, { ... }
  Api.query = function(_, q, vars)
    sent[#sent + 1] = { q = q, vars = vars }
    local a = table.remove(script, 1) or {}
    return a.result, a.err
  end
end
local vim_null = nil
local function ok(result) return { result = result } end
local function fail(err) return { err = err } end

local Recommendations = real_require("hardcover/lib/recommendations")

local function book(id, over)
  local b = { book_id = id, title = "Book " .. id, contributions = { { author = { name = "A" } } } }
  for k, v in pairs(over or {}) do b[k] = v end
  return b
end

print("\n== the ids ==")

check("the first LIMIT ids, as numbers, with repeats and junk dropped", function()
  local raw = { 5, "7", 5, 2.5, "x", 9 }
  local ids = Recommendations.ids(raw, 10)
  assert(#ids == 3 and ids[1] == 5 and ids[2] == 7 and ids[3] == 9, table.concat(ids, ","))
  local many = {}
  for i = 1, 100 do many[i] = i end
  assert(#Recommendations.ids(many) == Recommendations.LIMIT)
  assert(#Recommendations.ids(many, 3) == 3)
end)

check("no ranking (null, an object, nothing) is an empty list", function()
  assert(#Recommendations.ids(nil) == 0 and #Recommendations.ids({}) == 0 and #Recommendations.ids("x") == 0)
end)

print("\n== the books ==")

check("books come back in the ranking's order, missing ones left out, extras ignored", function()
  local entries = Recommendations.entries({ 3, 1, 2 }, { book(1), book(99), book(3) })
  assert(#entries == 2 and entries[1].book_id == 3 and entries[2].book_id == 1)
  assert(entries[1].user_book_id == nil, "a similar book is not one of your library rows")
  assert(entries[1].title == "Book 3" and entries[1].authors, "the entry is shelf-shaped")
  assert(#Recommendations.entries({ 1 }, nil) == 0 and #Recommendations.entries(nil, {}) == 0)
end)

check("the carousel card: author line, title, cover; nothing to show is nil", function()
  local entries = Recommendations.entries({ 1, 2 }, { book(1, { cached_image = { url = "u.jpg" } }), book(2) })
  local card = Recommendations.card(entries, "Dune")
  assert(card and card.title == "Similar to Dune" and card.subtitle == "2 books" and #card.items == 2)
  assert(card.items[1].book_id == 1 and card.items[1].title == "Book 1" and card.items[1].number == "A")
  assert(card.items[1].cover and card.items[1].cover.url == "u.jpg" and card.items[2].cover == nil)
  assert(card.items[1].current == false)
  assert(card.title_first == true, "the bold line is the title, the author under it")
  assert(Recommendations.card(entries).title == "Similar books", "no title known")
  assert(Recommendations.card({}) == nil and Recommendations.card(nil) == nil)
end)

check("the loading card: the heading, a loading subtitle, flagged so it cannot be tapped", function()
  local c = Recommendations.loadingCard("Dune")
  assert(c.title == "Similar to Dune" and c.loading == true and c.title_first == true and c.subtitle:find("Loading", 1, true))
  assert(Recommendations.loadingCard(nil).title == "Similar books")
end)

print("\n== the requests ==")

check("two requests: the ranking of the book, then those books; the result is in rank order", function()
  answers(ok({ books_by_pk = { cached_similar_book_ids = { 30, 10, 20 } } }),
          ok({ books = { book(10), book(20), book(30) } }))
  local entries, err = Api:getSimilarBooks(5)
  assert(entries and not err, tostring(err))
  assert(#sent == 2, "requests: " .. #sent)
  assert(sent[1].q:find("books_by_pk(id: $bookId)", 1, true) and sent[1].vars.bookId == 5)
  assert(sent[1].q:find("cached_similar_book_ids", 1, true))
  assert(sent[2].q:find("_in: $ids", 1, true) and #sent[2].vars.ids == 3)
  assert(entries[1].book_id == 30 and entries[2].book_id == 10 and entries[3].book_id == 20)
end)

check("a book with no ranking is an empty list and one request", function()
  answers(ok({ books_by_pk = {} }))
  local entries, err = Api:getSimilarBooks(5)
  assert(entries and #entries == 0 and not err and #sent == 1)
  answers(ok({ books_by_pk = nil }))
  entries = Api:getSimilarBooks(5)
  assert(entries and #entries == 0 and #sent == 1)
end)

check("a failed request is nil and the reason, at either step", function()
  answers(fail({ completed = false }))
  local entries, err = Api:getSimilarBooks(5)
  assert(entries == nil and err and err.completed == false)
  answers(ok({ books_by_pk = { cached_similar_book_ids = { 1 } } }), fail({ status = 429 }))
  entries, err = Api:getSimilarBooks(5)
  assert(entries == nil and err and err.status == 429)
end)

print("\n== not cancellable ==")

check("the strips' requests ignore touches (a dummy trap widget); an ordinary request can be cancelled", function()
  local Trapper = real_require("ui/trapper")
  local seen = {}
  Trapper.dismissableRunInSubprocess = function(_, _, trap) seen[#seen + 1] = trap; return true, '200:{"data":{"x":1}}' end
  Api.enabled = true
  local Network = real_require("hardcover/lib/network")
  Network.connected = function() return true end
  Api.query = real_query
  Api.auth = nil
  assert(Api:query("query { x }", {}, true), "no answer")
  assert(Api:query("query { x }", {}), "no answer")
  assert(type(seen[1]) == "table" and seen[1].dismiss_callback == nil, "a background request got a real trap")
  assert(seen[2] == true, "an ordinary request lost its trap")
end)

r.finish()
