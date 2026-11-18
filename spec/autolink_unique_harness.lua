-- Automatic linking only takes a match it can be sure of: exact identifiers
-- must return one row, title/author must return one result, and an ambiguous
-- match must not fall through to a looser search. A link that is made is shown
-- with a way to change or undo it.
--
-- Run with:  luajit spec/autolink_unique_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
support.preload_json(PLUGIN)

package.preload["version"] = function() return { getNormalizedCurrentVersion = function() return 202501010000 end } end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) fn() end,
    dismissableRunInSubprocess = function(_, fn) return true, fn() end,
    runInSubprocess = function(_, fn) return true, fn() end }
end
package.preload["ffi"] = function() return {} end
package.preload["ffi/pointer"] = function() return {} end
package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
package.preload["blitbuffer"] = function() return {} end

local dialog_opts
package.preload["ui/uimanager"] = function()
  return {
    nextTick = function(_, fn) fn() end,
    show = function() end, close = function() end, setDirty = function() end,
    scheduleIn = function() end, unschedule = function() end, forceRePaint = function() end,
  }
end
package.preload["hardcover/lib/ui/auto_link_dialog"] = function()
  return { show = function(opts) dialog_opts = opts end }
end

local Api = require("hardcover/lib/hardcover_api")
local Hardcover = require("hardcover/lib/hardcover")
local User = require("hardcover/lib/user")
local r = support.reporter()
local check = r.test

local function apiWith(query)
  Api.query = function(_, text) return query(text) end
end

local function edition(id, book_id)
  return { id = id, book = { book_id = book_id, title = "Book " .. book_id, editions = {} } }
end

print("\n== exact identifiers ==")

check("one ISBN row links", function()
  apiWith(function() return { editions = { edition(1, 10) } } end)
  local book, err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719" }, 1, true)
  assert(book and book.book_id == 10 and err == nil)
end)

check("several ISBN rows are ambiguous and link nothing", function()
  apiWith(function() return { editions = { edition(1, 10), edition(2, 11) } } end)
  local book, err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719" }, 1, true)
  assert(book == nil and err and err.ambiguous == true)
end)

check("one Hardcover slug row links", function()
  apiWith(function() return { books = { { book_id = 10, title = "Dune" } } } end)
  local book, err = Api:findBookByIdentifiers({ book_slug = "dune" }, 1, true)
  assert(book and book.book_id == 10 and err == nil)
end)

check("several Hardcover slug rows are ambiguous", function()
  apiWith(function() return { books = { { book_id = 10 }, { book_id = 11 } } } end)
  local book, err = Api:findBookByIdentifiers({ book_slug = "dune" }, 1, true)
  assert(book == nil and err and err.ambiguous == true)
end)

check("several edition rows are ambiguous", function()
  apiWith(function() return { editions = { edition(1, 10), edition(2, 11) } } end)
  local book, err = Api:findBookByIdentifiers({ edition_id = 1 }, 1, true)
  assert(book == nil and err and err.ambiguous == true)
end)

check("a manual lookup still takes the first row", function()
  apiWith(function() return { editions = { edition(1, 10), edition(2, 11) } } end)
  local book, err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719" }, 1)
  assert(book and book.book_id == 10 and err == nil)
end)

print("\n== the Hardcover auto-link paths ==")

local function menu(settings)
  return Hardcover:new {
    settings = settings,
    ui = { document = { file = "/book.epub", getProps = function() return { title = "Dune", authors = "Frank Herbert" } end } },
    wifi = { withWifi = function(_, fn) fn() end },
  }
end

local function fakeSettings(values)
  return { readSetting = function(_, key) return values[key] end,
    bookLinked = function() return false end }
end

check("ISBN and Hardcover-id lookups ask for a unique match", function()
  local asked = {}
  Api.findBookByIdentifiers = function(_, identifiers, user_id, unique)
    asked[#asked + 1] = { identifiers = identifiers, unique = unique }
    return nil, { ambiguous = true }
  end
  User.getId = function() return 1 end
  local h = menu(fakeSettings({ link_by_isbn = true, link_by_hardcover = true }))
  h:linkBookByIsbn({ isbn_13 = "9780441172719" })
  h:linkBookByHardcover({ book_slug = "dune" })
  assert(#asked == 2 and asked[1].unique == true and asked[2].unique == true)
end)

check("an ambiguous exact identifier does not fall through to a looser search", function()
  local called = {}
  Api.findBookByIdentifiers = function() return nil, { ambiguous = true } end
  User.getId = function() return 1 end
  local h = menu(fakeSettings({ link_by_isbn = true, link_by_hardcover = true, link_by_title = true }))
  h.linkBookByHardcover = function() called[#called + 1] = "hardcover"; return false end
  h.linkBookByTitle = function() called[#called + 1] = "title"; return false end
  h:_runAutolink({ isbn_13 = "9780441172719" })
  assert(#called == 0, "an ambiguous identifier fell through")
end)

check("one title result links; several are ambiguous and link nothing", function()
  local linked = {}
  User.getId = function() return 1 end
  local h = menu(fakeSettings({}))
  h.autolinkBook = function(_, book) linked[#linked + 1] = book; return true end
  Api.findBooks = function() return { { book_id = 10 } } end
  assert(h:linkBookByTitle() == true and linked[1].book_id == 10)
  linked = {}
  Api.findBooks = function() return { { book_id = 10 }, { book_id = 11 } } end
  local ok, err = h:linkBookByTitle()
  assert(ok == false and err and err.ambiguous == true and #linked == 0)
end)

check("a made link is shown with change and undo actions", function()
  dialog_opts = nil
  local h = menu(fakeSettings({}))
  h.linkBook = function() return true end
  assert(h:autolinkBook({ title = "Dune" }) == true)
  assert(dialog_opts and dialog_opts.book.title == "Dune")
  assert(type(dialog_opts.on_change) == "function" and type(dialog_opts.on_unlink) == "function")
end)

r.finish()