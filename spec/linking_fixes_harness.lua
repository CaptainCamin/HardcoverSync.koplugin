-- Fixes to linking from the bug review of "Link all books": a failed lookup is an
-- error and not "no match", and a silent save still reaches the open book.
--
-- Run with:  lua spec/linking_fixes_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
support.preload_json(PLUGIN)

package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
local online = true
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return online end, isOnline = function() return online end }
end

package.preload["version"] = function() return { getNormalizedCurrentVersion = function() return 999999999999 end } end
package.preload["luasettings"] = function()
  return { open = function()
    local store = {}
    return {
      readSetting = function(_, key, default)
        if store[key] == nil and default ~= nil then store[key] = default end
        return store[key]
      end,
      saveSetting = function(_, key, value) store[key] = value end,
      flush = function() end,
    }
  end }
end

local r = support.reporter()
local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local Api = require("hardcover/lib/hardcover_api")

local reply
Api.runtime = {
  subprocess = function(fn) return true, fn() end,
  wrap = function(fn) fn() end,
  next_tick = function() end,
}
Api.transport = { post = function() return reply end }
Api.auth = nil
Api.enabled = true

print("\n== a failed lookup is not 'not found' ==")

check("an ISBN lookup that hits a rate limit returns the error", function()
  online, reply = true, "429:<html>slow down</html>"
  local book, err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719" }, 1)
  assert(book == nil and err ~= nil, "no error returned")
end)

check("an ISBN lookup while offline returns an error", function()
  online = false
  local book, err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719" }, 1)
  assert(book == nil and err ~= nil, "no error returned")
  online = true
end)

check("a slug lookup that fails returns the error", function()
  online, reply = true, "500:"
  local book, err = Api:findBookByIdentifiers({ book_slug = "dune" }, 1)
  assert(book == nil and err ~= nil, "no error returned")
end)

check("a lookup Hardcover answers with nothing is just not found", function()
  online, reply = true, '200:{"data":{"editions":[]}}'
  local book, err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719" }, 1)
  assert(book == nil and err == nil, tostring(err))
end)

check("a title search while offline is an error, not an empty list", function()
  online = false
  local results, err = Api:search("Dune", "Frank Herbert", 1)
  assert(results == nil and err ~= nil, "got a list")
  online = true
end)

check("a title search that fails is an error", function()
  online, reply = true, "429:"
  local results, err = Api:search("Dune", "Frank Herbert", 1)
  assert(results == nil and err ~= nil)
end)

print("\n== lookups by edition id ==")

check("the edition id query declares $id with a colon", function()
  local seen
  local saved = Api.query
  Api.query = function(_, text) seen = text; return { editions = {} } end
  Api:hydrateBookFromEdition(30, 1)
  Api.query = saved
  assert(seen and seen:find("$id: Int!", 1, true), tostring(seen))
end)

print("\n== a file with both ISBNs ==")

check("the ISBN-10 is tried when the ISBN-13 finds nothing", function()
  local asked = {}
  local saved = Api.query
  Api.query = function(_, text)
    local key = text:match("where: { (isbn_%d+)")
    asked[#asked + 1] = key
    if key == "isbn_10" then return { editions = { { id = 5, book = { id = 9 } } } } end
    return { editions = {} }
  end
  local book = Api:findBookByIdentifiers({ isbn_13 = "9780441172719", isbn_10 = "0441172717" }, 1)
  Api.query = saved
  assert(#asked == 2 and asked[1] == "isbn_13" and asked[2] == "isbn_10", table.concat(asked, ","))
  assert(book ~= nil)
end)

check("an ISBN-10 answer wins over an ISBN-13 failure", function()
  local saved = Api.query
  Api.query = function(_, text)
    if text:find("isbn_10:", 1, true) then return { editions = { { id = 5, book = { id = 9 } } } } end
    return nil, { completed = false }
  end
  local book, err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719", isbn_10 = "0441172717" }, 1)
  Api.query = saved
  assert(book ~= nil and err == nil)
end)

print("\n== a silent save still reaches the open book ==")

local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local function settings(open_file)
  local s = HardcoverSettings:new("/tmp/linking_fixes_settings.lua",
    open_file and { document = { file = open_file } } or {})
  local seen = {}
  s:subscribe(function(key, value) seen[#seen + 1] = { key = key, filename = value and value.filename } end)
  return s, seen
end

check("a silent save of a book that is not open tells nobody", function()
  local s, seen = settings("/books/open.epub")
  s:updateBookSetting("/books/other.epub", { book_id = 1 }, true)
  assert(#seen == 0)
end)

check("a silent save of the open book is announced", function()
  local s, seen = settings("/books/open.epub")
  s:updateBookSetting("/books/open.epub", { book_id = 1 }, true)
  assert(#seen == 1 and seen[1].filename == "/books/open.epub", #seen)
end)

check("a silent save with no book open tells nobody", function()
  local s, seen = settings(nil)
  s:updateBookSetting("/books/other.epub", { book_id = 1 }, true)
  assert(#seen == 0)
end)

check("a snapshot with no read or edition drops the old ones", function()
  local s = settings(nil)
  local f = "/books/snap.epub"
  s:saveBookSnapshot(f, { id = 5, status_id = 2, edition_id = 7,
    user_book_reads = { { id = 11, progress_pages = 50, started_at = "2026-01-01" } } })
  assert(s:readBookSetting(f, "read_id") == 11 and s:readBookSetting(f, "edition_id") == 7)
  s:saveBookSnapshot(f, { id = 5, status_id = 2, user_book_reads = {} })
  for _, k in ipairs({ "read_id", "started_at", "last_synced_page", "edition_id" }) do
    assert(s:readBookSetting(f, k) == nil, k .. " should be gone")
  end
  assert(s:readBookSetting(f, "user_book_id") == 5)
end)

r.finish()
