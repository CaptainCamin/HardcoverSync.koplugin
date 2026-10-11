-- Hardcover's shelf sources for Bookshelf (lib/bookshelf_sources.lua).
--
-- Drives register/fetch/refresh the way Bookshelf's source API does, against a
-- fake `ui.bookshelf` that keeps the specs and counts sourceChanged calls.
--
-- Run with:  lua spec/bookshelf_sources_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()

local ticks = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function() end, close = function() end, unschedule = function() end,
    scheduleIn = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) fn() end }
end
package.preload["hardcover/lib/ui/image_loader"] = function()
  return {
    covers = {},
    cachedPath = function(self, url) return self.covers[url] end,
    loadImages = function() return {}, function() end end,
  }
end
package.preload["hardcover/lib/hardcover_api"] = function()
  local Api = { shelf_calls = 0, list_calls = {} }
  function Api:getShelf(_user, status, offset, limit)
    self.shelf_calls = self.shelf_calls + 1
    if offset > 0 then return {} end
    return { { book_id = 1, title = "Zed", authors = "A", date_added = "2026-01-02" },
             { book_id = 2, title = "Alpha", authors = "B", date_added = "2026-03-04",
               cached_image = { url = "http://img/2.jpg" } } }
  end
  function Api:getListBooks(id, source, ranked, offset, limit)
    self.list_calls[#self.list_calls + 1] = source
    if offset > 0 then return { books = {}, has_more = false } end
    return { { book_id = 9, title = "Listed" } }
  end
  return Api
end
package.preload["hardcover/lib/network"] = function()
  return { connected = function() return true end }
end
package.preload["hardcover/lib/user"] = function()
  return { getId = function() return 7 end }
end

local Sources = require("hardcover/lib/bookshelf_sources")
local Api = require("hardcover/lib/hardcover_api")
local ImageLoader = require("hardcover/lib/ui/image_loader")

local function runTicks()
  while #ticks > 0 do table.remove(ticks, 1)() end
end

local function fakeApp(opts)
  opts = opts or {}
  local specs, changes = {}, {}
  local app
  app = {
    enabled = true,
    auth = { usingOAuth = function() return false end, usingPat = function() return true end,
             config = { token = "t" } },
    settings = { readSetting = function(_, k) return opts.user_id end },
    shelf_store = opts.entries and {
      entries = function() return opts.entries, { complete = true } end,
    } or nil,
    dialog_manager = { showBookDetail = function(_, id) app.opened = id end },
    ui = { bookshelf = {
      SOURCE_API = 1,
      registerSource = function(_, id, spec) specs[id] = spec; return true end,
      sourceChanged = function(_, id) changes[#changes + 1] = id end,
    } },
  }
  return app, specs, changes
end

-- ------------------------------------------------------------ registration
do
  local app = fakeApp()
  app.ui.bookshelf = nil
  r.check("register without Bookshelf is false", Sources.register(app) == false)
  app.ui.bookshelf = { SOURCE_API = 0, registerSource = function() return true end }
  r.check("register with an old Bookshelf is false", Sources.register(app) == false)
end

local app, specs, changes = fakeApp { user_id = 7, entries = {
  { book_id = 1, title = "Zed", authors = "A", date_added = "2026-01-02" },
  { book_id = 2, title = "Alpha", authors = "B", date_added = "2026-03-04",
    description = "A whole synopsis.", cached_image = { url = "http://img/2.jpg" } },
  { book_id = 3, title = "Mid", authors = "C", date_added = "2026-02-01" },
  { book_id = 4, title = "Cut", authors = "D", date_added = "2026-02-02",
    description = "Begins here\226\128\166" },
} }
r.check("register succeeds", Sources.register(app) == true)
for _, id in ipairs { "hardcover_wtr", "hardcover_reading", "hardcover_read",
                      "hardcover_dnf", "hardcover_shelf", "hardcover_lists" } do
  local s = specs[id]
  r.check(id .. " has the required hooks", s and s.api == 1
    and type(s.label()) == "string" and type(s.available) == "function"
    and type(s.fetch) == "function" and s.list == nil)
end
r.check("legacy ids stay out of the picker",
  specs.hardcover_wtr.picker == false and specs.hardcover_shelf.picker == true
  and specs.hardcover_lists.picker == true)
r.check("available with a token", specs.hardcover_shelf.available() == true)
do
  local signed_out, s2 = fakeApp()
  signed_out.auth.config.token = ""
  Sources.register(signed_out)
  r.check("unavailable without a token", s2.hardcover_shelf.available() == false)
  Sources.register(app)
end
r.check("owns hardcover:// books", specs.hardcover_shelf.owns { filepath = "hardcover://book/5" }
  and not specs.hardcover_shelf.owns { filepath = "/books/a.epub" })

-- ------------------------------------------------------------ shelf fetch
ImageLoader.covers["http://img/2.jpg"] = "/cache/2.jpg"
local shelf = specs.hardcover_shelf
local source = { kind = "hardcover_shelf", status_id = 1, sort_key = "title" }
local books, total = shelf.fetch(source, nil, 0, 10)
r.check("a saved complete shelf pages at once", #books == 4 and total == 4)
r.check("sorted by title", books[1].title == "Alpha" and books[4].title == "Zed")
r.check("records are remote and unread for Want to Read",
  books[1].filepath == "hardcover://book/2" and books[1].status == "unread")
r.check("cover path comes from the cache", books[1].cover_image_path == "/cache/2.jpg"
  and books[2].cover_image_path == nil)
r.check("a saved synopsis comes first, then the note",
  books[1].description:find("^A whole synopsis%.") ~= nil
  and books[1].description:find("Open this book", 1, true) ~= nil)
r.check("a book without one says to open it",
  books[3].description:find("Open this book", 1, true) ~= nil)
r.check("a cut synopsis keeps its text and has the note",
  books[2].title == "Cut" and books[2].description:find("^Begins here")
  and books[2].description:find("Open this book", 1, true) ~= nil)
local page = shelf.fetch(source, nil, 1, 1)
r.check("offset and limit slice the sorted shelf", #page == 1 and page[1].title == "Cut")
r.check("a complete saved shelf starts no request", #ticks == 0 and Api.shelf_calls == 0)
r.check("an unknown shelf is empty", select(1, shelf.fetch({ status_id = 99 }, nil, 0, 5))[1] == nil)

-- ------------------------------------------------------------ every sort order
do
  local a, s = fakeApp { user_id = 8, entries = {
    { book_id = 1, title = "The Beta", authors = "Zoe Adams", release_year = 2001, pages = 300,
      users_count = 10, community_rating = 3.5, user_rating = 2 },
    { book_id = 2, title = "Alpha", authors = "Bob Young", release_year = 1999, pages = 100,
      users_count = 500, community_rating = 4.5, user_rating = 5 },
    { book_id = 3, title = "Gamma", authors = "Amy Brown", release_year = 2010, pages = 200,
      users_count = 50, community_rating = 4.0, user_rating = 3 },
  } }
  Sources.register(a)
  local function ids(key)
    local out = {}
    for _, b in ipairs(s.hardcover_shelf.fetch({ status_id = 1, sort_key = key }, nil, 0, 10)) do
      out[#out + 1] = b.hardcover_book_id
    end
    return table.concat(out, ",")
  end
  local expected = {
    added_desc = "1,2,3", added_asc = "3,2,1", title = "2,1,3", author = "1,3,2",
    year_desc = "3,1,2", year_asc = "2,1,3", pages_asc = "2,3,1", pages_desc = "1,3,2",
    popular = "2,3,1", rating = "2,3,1", my_rating = "2,3,1",
  }
  -- author: surname Adams (1), Brown (3), Young (2)
  for key, want in pairs(expected) do
    r.check("sort " .. key, ids(key) == want, ids(key))
  end
  r.check("an unknown key keeps the saved order", ids("nonsense") == "1,2,3")
end

-- ------------------------------------------------------------ the editor's sort row
do
  local a, s = fakeApp { user_id = 7 }
  local shown
  package.preload["hardcover/lib/ui/picker"] = function()
    return { new = function(opts) shown = opts; return opts end }
  end
  Sources.register(a)
  local button = s.hardcover_shelf.editor_rows({ source = {} })[1][1]
  local draft = { source = { sort_key = "title" } }
  r.check("the sort button names the current order",
    button.text(draft):find("Title", 1, true) ~= nil)
  local done_called = false
  button.callback(draft, function() done_called = true end)
  r.check("the sort button opens a picker with every order", shown and #shown.rows == 11)
  shown.rows[2].callback()
  r.check("choosing an order sets the key and finishes",
    draft.source.sort_key == "added_asc")
  r.check("done is called", done_called)
end

-- ------------------------------------------------------------ a book with no title
do
  local a, s = fakeApp { user_id = 10, entries = { { book_id = 5, authors = "Someone" } } }
  Sources.register(a)
  local got = s.hardcover_shelf.fetch({ status_id = 1 }, nil, 0, 5)
  r.check("an untitled book is shown as Untitled", got[1] and got[1].title == "Untitled")
end

-- ------------------------------------------------------------ open
specs.hardcover_shelf.open(books[1])
r.check("open shows Hardcover details", app.opened == 2)

-- ------------------------------------------------------------ load from the network
do
  local a, s, c = fakeApp { user_id = 7 }
  Sources.register(a)
  local first, t = s.hardcover_shelf.fetch({ status_id = 3 }, nil, 0, 10)
  r.check("no saved shelf shows nothing yet", #first == 0)
  r.check("and queues a load for the next tick", #ticks == 1)
  runTicks()
  r.check("the load fetched the shelf", Api.shelf_calls >= 1)
  r.check("Bookshelf was told", #c > 0)
  local after = s.hardcover_shelf.fetch({ status_id = 3, sort_key = "title" }, nil, 0, 10)
  r.check("the loaded books show", #after == 2 and after[1].title == "Alpha")
  r.check("Finished books are marked read", after[1].status == "finished")

  Sources.invalidate(a)
  local gone = s.hardcover_shelf.fetch({ status_id = 3 }, nil, 0, 10)
  r.check("invalidate drops the in-memory shelf", #gone == 0)
  runTicks()
end

-- ------------------------------------------------------------ lists
do
  local a, s = fakeApp { user_id = 7 }
  Sources.register(a)
  local source = { kind = "hardcover_lists", list_id = 5 } -- list_source missing
  s.hardcover_lists.fetch(source, nil, 0, 10)
  runTicks()
  r.check("a list without list_source loads as mine", Api.list_calls[1] == "mine")
  local got = s.hardcover_lists.fetch(source, nil, 0, 10)
  r.check("and is then found under the same key", #got == 1 and got[1].title == "Listed")
end

-- ------------------------------------------------------------ sorting is not repeated
do
  local entries = {}
  for i = 1, 30 do
    entries[i] = { book_id = i, title = "Book " .. (i * 7 % 30), authors = "Au Thor" .. i,
      pages = i * 13 % 30 }
  end
  local a, s = fakeApp { user_id = 21, entries = entries }
  Sources.register(a)
  local ShelfSort = require("hardcover/lib/shelf_sort")
  local real, sorts = ShelfSort.sort, 0
  ShelfSort.sort = function(...) sorts = sorts + 1; return real(...) end
  local fetch = s.hardcover_shelf.fetch
  local by_title = { status_id = 2, sort_key = "title" }
  local by_pages = { status_id = 2, sort_key = "pages_desc" }
  fetch(by_title, nil, 0, 5); fetch(by_title, nil, 5, 5)
  r.check("turning pages sorts the shelf once", sorts == 1, sorts)
  fetch(by_pages, nil, 0, 5)
  for _ = 1, 3 do fetch(by_title, nil, 0, 5); fetch(by_pages, nil, 0, 5) end
  r.check("two sorts of one shelf are each kept, not rebuilt in turn", sorts == 2, sorts)
  local page = fetch(by_pages, nil, 0, 5)
  r.check("and each still gives its own order", page[1].pages >= page[2].pages)
  r.check("only the page asked for becomes book records", #fetch(by_title, nil, 25, 10) == 5)
  -- a download page arrives: the entries grew, so the list is sorted again
  entries[#entries + 1] = { book_id = 31, title = "Aaa", authors = "Z", pages = 1 }
  r.check("new entries are sorted in", fetch(by_title, nil, 0, 1)[1].title == "Aaa"
    and sorts == 3, sorts)
  ShelfSort.sort = real
end

r.finish()
