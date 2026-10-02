--[[--
Fixture data and a fake API for emulator scenarios.

A scenario needs the plugin to build real widgets, and the plugin builds them
from what the API returns. So the API is replaced here, at the module boundary,
with canned responses in the exact shape Hardcover's GraphQL returns -- verified
against the live schema, not guessed from the query text.

The point is that the code under test is unchanged: ShelfDialog still parses
items, ListMenu still picks its draw path, CoverMenu still resolves covers.
Only the network is gone.
]]

local M = {}

M.USER_ID = 4242

--[[--
Deep copy, local to the harness.

The plugin's table_util has no deep-copy helper, and borrowing KOReader's
util.tableDeepCopy would couple the fixtures to the emulator being present --
they are also useful from the stock-Lua spec suite.
]]
local function deepcopy(value, seen)
  seen = seen or {}
  if type(value) ~= "table" then return value end
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do out[deepcopy(k, seen)] = deepcopy(v, seen) end
  return setmetatable(out, getmetatable(value))
end

M.deepcopy = deepcopy

-- A plain book row, as returned inside a user_books query.
local function book_row(id, title, year, pages, opts)
  opts = opts or {}
  return {
    book_id = id,
    title = title,
    release_year = year,
    pages = pages,
    users_count = opts.users_count or (1000 + id * 37),
    users_read_count = opts.users_read_count or (500 + id * 11),
    rating = opts.rating or 4.2,
    ratings_count = opts.ratings_count or 120,
    description = opts.description or
      "A fixture description, long enough to wrap across several lines in the " ..
      "detail dialog so wrapping and page-count behaviour are actually visible " ..
      "in a screenshot rather than being a single tidy line.",
    contributions = opts.contributions or {
      { author = { name = opts.author or "Ursula K. Le Guin" } },
    },
    -- Not `opts.no_image and nil or {...}`: `a and nil or b` is always b, because
    -- nil is falsy, so every "no cover" book here used to have a cover and the
    -- no-cover layout was never exercised.
    cached_image = (not opts.no_image) and {
      url = opts.image_url or "https://covers.hardcover.app/fixture/" .. id .. ".jpg",
      width = 300,
      height = 450,
    } or nil,
    book_series = opts.series and {
      { position = opts.series_position or 2, series = { name = opts.series } },
    } or {},
  }
end

M.books = {
  book_row(101, "The Dispossessed", 1974, 341, { author = "Ursula K. Le Guin" }),
  book_row(102, "A Wizard of Earthsea", 1968, 183, {
    author = "Ursula K. Le Guin",
    series = "Earthsea",
    series_position = 1,
  }),
  book_row(103, "The Left Hand of Darkness", 1969, 304, {
    author = "Ursula K. Le Guin",
    series = "Hainish Cycle",
    series_position = 2,
  }),
  book_row(104, "The Tombs of Atuan", 1971, 192, {
    author = "Ursula K. Le Guin",
    series = "Earthsea",
    series_position = 2,
  }),
  book_row(105, "The Hundred Thousand Kingdoms", 2010, 418, {
    author = "N. K. Jemisin",
    no_image = true, -- covers the no-cover row layout
  }),
  -- A deliberately hostile title: very long, unbreakable, and with a series
  -- suffix. Long strings are where e-ink truncation bugs live.
  book_row(106, "Some Extremely Long Title That Will Absolutely Not Fit On One Line At All", 1999, 1200, {
    author = "An Author With A Very Long Name Indeed And Then Some More",
    series = "A Very Long Series Name That Also Does Not Fit",
  }),
  book_row(107, "The Fifth Season", 2015, 468, { author = "N. K. Jemisin", users_count = 90000 }),
  -- A description long enough that the detail page has to scroll vertically,
  -- which is when the scroll container's vertical bar narrows the viewport.
  book_row(109, "A Book With A Very Long Description", 2001, 612, {
    author = "Fixture Author",
    series = "The Long Series",
    series_position = 3,
    description = string.rep(
      "This paragraph stands in for a publisher's blurb, which on a real book can run to many lines. " ..
      "It repeats so the page is tall enough to scroll, and so a layout that is a few pixels too wide " ..
      "for its scroll container shows up as a sideways scroll bar. ", 18),
  }),
  book_row(108, "The Obelisk Gate", 2016, 448, { author = "N. K. Jemisin" }),
}

--[[--
A bigger shelf, for scenarios that need more than one page.

The curated list above is deliberately small and hand-checked. But a menu with
fewer rows than fit on the screen has page_num == 1, and NextPage on a
single-page menu cycles straight back to page 1 -- so a paging assertion against
it passes for the wrong reason. This list exists to make paging real.

Generated rather than hand-written because nobody reads row 40 of a fixture;
what matters is only that there are enough distinct rows to overflow a page at
the emulated resolution.
]]
M.shelf_books = {}
do
  local titles = {
    "The Lathe of Heaven", "Kindred", "The Snow Queen", "A Wizard of Earthsea",
    "The Word for World Is Forest", "The Left Hand of Darkness", "Solaris",
    "Roadside Picnic", "Hyperion", "The Fall of Hyperion", "Dune", "Children of Dune",
    "The Three Stigmata of Palmer Eldritch", "Do Androids Dream of Electric Sheep",
    "Valley of Flowers", "The Memory Police", "Convenience Store Woman",
    "The Master and Margarita", "Babel", "The Dispossessed",
  }
  for i, title in ipairs(titles) do
    M.shelf_books[#M.shelf_books + 1] = book_row(200 + i, title, 1950 + i * 3, 200 + i * 11, {
      author = "Fixture Author " .. i,
      series = (i % 3 == 0) and ("Shelf Series " .. math.floor(i / 3)) or nil,
      series_position = (i % 3 == 0) and (i % 5) or nil,
      no_image = (i % 7 == 0), -- no-cover rows land throughout the list
    })
  end
end

-- how many books are on each shelf, as the home screen's count query returns them
M.shelf_counts = { [2] = 3, [1] = 42, [3] = 130, [5] = 2 }

--[[--
Put the synthetic cover (spec/emu/fixtures/cover.png) into the plugin's real
cover cache under `url`.

The detail screen fetches covers through the cover loader, which answers from
this cache before it touches the network. Seeding it means the real loader, the
real cache and the real image renderer all run, with no network and no mocking
of any of them.
]]
function M.seed_cover(url)
  local root = package.searchpath("hardcover/lib/shelf", package.path):match("^(.*)/hardcover/lib/shelf%.lua$")
  local file = assert(io.open(root .. "/spec/emu/fixtures/cover.png", "rb"),
    "spec/emu/fixtures/cover.png is missing: run spec/emu/make_cover.py")
  local bytes = file:read("*a")
  file:close()

  local cache = require("hardcover/lib/ui/image_loader"):getCache()
  assert(cache, "the cover cache could not be opened (no ffi/sha2 or lfs?)")
  assert(cache:put(url, bytes), "could not write the cover into the cache")
end

M.books_by_id = {}
for _, b in ipairs(M.books) do M.books_by_id[b.book_id] = b end
for _, b in ipairs(M.shelf_books) do M.books_by_id[b.book_id] = b end

--[[--
Build the real settings object, backed by the emulated data dir.

Deliberately not a stub: HardcoverSettings is the plugin's own persistence
layer, and the dialogs ask it real questions (compatibility mode, page counts,
whether a book is linked). A hand-written stand-in would drift from it and make
a scenario pass while the device disagrees. Writes land in the scratch KO_HOME,
never in a real installation.
]]
function M.real_settings(emu, ui)
  local HardcoverSettings = require("hardcover/lib/hardcover_settings")
  return HardcoverSettings:new(
    emu.DataStorage:getSettingsDir() .. "/hardcoversync_settings.lua",
    ui or emu:stub_ui())
end

--[[--
Replace the API layer with fixtures.

Patches the methods the plugin calls, on the module table it actually calls
them on. Anything not listed here still runs for real and will attempt a
request -- which fails cleanly offline -- so a scenario that quietly depends on
an unstubbed call shows up as an empty screen rather than as a false pass.
]]
function M.install(opts)
  opts = opts or {}

  local Api = require("hardcover/lib/hardcover_api")
  local User = require("hardcover/lib/user")

  -- User:getId reads through to settings, then falls back to Api:me(). Give it
  -- the real settings object and let the stubbed me() supply the id, so the
  -- lookup path itself is exercised.
  if opts.settings then
    User.settings = opts.settings
  end

  -- Never let a scenario touch the network, whatever it forgets to stub.
  Api.enabled = true

  local calls = {}
  M.calls = calls

  local function record(name)
    calls[#calls + 1] = { name = name, at = os.clock() }
  end

  Api.getShelf = function(_, user_id, status_id, offset, limit)
    record("getShelf")
    offset, limit = offset or 0, limit or 20

    -- opts.books lets a scenario choose between the small curated list and the
    -- big one. The default is the big one: a single-page menu silently passes
    -- every paging assertion, so the fixture should not make that easy.
    local source = opts.books or M.shelf_books

    local page = {}
    for i = offset + 1, math.min(offset + limit, #source) do
      local b = source[i]
      page[#page + 1] = {
        id = 9000 + b.book_id,
        status_id = status_id or 2,
        rating = (b.book_id % 5 == 0) and 4 or nil, -- exercises both rated and unrated rows
        date_added = "2026-01-01",
        book = b,
      }
    end
    -- Normalize through the plugin's own Shelf module rather than shaping rows
    -- here: the dialog is supposed to receive what normalizeEntry returns, so
    -- building the shape independently would let a scenario pass while the real
    -- path produced something else.
    local Shelf = require("hardcover/lib/shelf")
    local entries = {}
    for _, user_book in ipairs(page) do
      entries[#entries + 1] = Shelf.normalizeEntry(user_book)
    end

    -- A short page tells the dialog there is nothing more to fetch.
    local has_more = (#source > offset + limit)
    return entries, nil, has_more
  end

  Api.getShelfCounts = function(_, user_id, status_ids)
    record("getShelfCounts")
    local counts = {}
    for _, id in ipairs(status_ids or {}) do
      counts[id] = M.shelf_counts[id]
    end
    return counts
  end

  Api.getBookDetail = function(_, book_id, user_id, edition_id)
    record("getBookDetail")
    local b = M.books_by_id[book_id] or M.books[1]
    local detail = deepcopy(b)
    if edition_id then
      detail.edition_id = edition_id
      detail.edition_format = "Paperback"
      detail.isbn_13 = "978" .. tostring(10000000000 + book_id)
      detail.publisher = { name = "Fixture Press" }
      detail.language = { code2 = "en", language = "English" }
      detail.release_date = "2016-01-05"
    end
    return {
      book = detail,
      user_book_id = 9000 + b.book_id,
      status_id = 2,
      user_rating = 4,
    }
  end

  Api.findBooks = function(_, title, author, userId)
    record("findBooks")
    if not title or title:match("^%s*$") then return {} end
    local needle = title:lower()
    local out = {}
    for _, b in ipairs(M.books) do
      if b.title:lower():find(needle, 1, true) then
        out[#out + 1] = deepcopy(b)
      end
    end
    return out
  end

  Api.findEditions = function(_, book_id, userId)
    record("findEditions")
    local b = M.books_by_id[book_id] or M.books[1]
    local editions = {}
    for i = 1, 3 do
      editions[i] = {
        id = book_id * 100 + i,
        book = deepcopy(b),
        cached_image = b.cached_image,
        edition_format = "Paperback",
        reading_format_id = 1,
        pages = (b.pages or 300) + (i - 1) * 12,
        publisher = { name = "Fixture Press" },
        release_date = tostring(2010 + i) .. "-03-01",
        users_count = 5000 - i * 900,
        language = { code2 = "en", language = "English" },
        title = b.title,
        user_book = i == 1 and { id = 9000 + book_id } or nil,
      }
    end
    return editions
  end

  Api.search = function(_, title, author, userId, page)
    record("search")
    return Api.findBooks(nil, title, author, userId)
  end

  Api.me = function() return { id = M.USER_ID, account_privacy_setting_id = 1 } end

  -- Mutations: record and echo back something shaped like the real response,
  -- so a scenario can verify a write path without a network.
  Api.updatePage = function(_, read_id, edition_id, page, started_at)
    record("updatePage")
    return { id = 8000, status_id = 2, edition_id = edition_id,
             user_book_reads = { { id = read_id, progress_pages = page, edition_id = edition_id } } }
  end

  Api.createRead = function(_, user_book_id, edition_id, page, started_at)
    record("createRead")
    return { id = 8001, status_id = 2, edition_id = edition_id,
             user_book_reads = { { id = 8001, progress_pages = page, edition_id = edition_id } } }
  end

  Api.updateRating = function(_, user_book_id, rating)
    record("updateRating")
    return { id = user_book_id, status_id = 2, rating = rating }
  end

  Api.updateUserBook = function(_, book_id, status_id, privacy, edition_id)
    record("updateUserBook")
    return { id = 9000 + book_id, book_id = book_id, status_id = status_id, rating = 0 }
  end

  Api.removeRead = function(_, user_book_id)
    record("removeRead")
    return { id = user_book_id }
  end

  Api.createJournalEntry = function(_, object)
    record("createJournalEntry")
    return { id = 70001 }
  end

  -- Last, so a scenario can override any single method without having to
  -- restate the rest of the fixture layer.
  for k, v in pairs(opts.overrides or {}) do
    Api[k] = v
  end

  return Api
end

return M
