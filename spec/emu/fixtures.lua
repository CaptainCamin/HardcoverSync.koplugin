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
      "A lone envoy arrives on a frozen world to bring its people into a league " ..
      "of planets, and finds that nothing about the place, its politics, its " ..
      "weather or its customs, is what he was told to expect. Long enough to wrap " ..
      "across several lines, so wrapping and page-count behaviour are visible.",
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
      { position = opts.series_position or 2,
        series = { id = opts.series_id or (100 + #opts.series), name = opts.series } },
    } or {},
  }
end

-- Books whose details come back with no library record (see getBookDetail).
-- Scenarios may add to it; install() does not reset it.
M.not_in_library = { [108] = true }

M.books = {
  book_row(101, "The Dispossessed", 1974, 341, {
    author = "Ursula K. Le Guin",
    series = "Hainish Cycle",
    series_id = 12,
    series_position = 5,
  }),
  book_row(102, "A Wizard of Earthsea", 1968, 183, {
    author = "Ursula K. Le Guin",
    series = "Earthsea",
    series_position = 1,
  }),
  book_row(103, "The Left Hand of Darkness", 1969, 304, {
    author = "Ursula K. Le Guin",
    series = "Hainish Cycle",
    series_id = 12,
    series_position = 4,
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
    series_id = 14,
    series_position = 12,
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
  -- who wrote each, and the series two of them belong to (index -> name, position)
  local authors = {
    "Ursula K. Le Guin", "Octavia E. Butler", "Joan D. Vinge", "Ursula K. Le Guin",
    "Ursula K. Le Guin", "Ursula K. Le Guin", "Stanis\197\130aw Lem",
    "Arkady and Boris Strugatsky", "Dan Simmons", "Dan Simmons", "Frank Herbert", "Frank Herbert",
    "Philip K. Dick", "Philip K. Dick", "Brian Selznick", "Yoko Ogawa", "Sayaka Murata",
    "Mikhail Bulgakov", "R. F. Kuang", "Ursula K. Le Guin",
  }
  local series = {
    [4] = { "Earthsea", 1 }, [9] = { "Hyperion Cantos", 1 }, [10] = { "Hyperion Cantos", 2 },
    [11] = { "Dune", 1 }, [12] = { "Dune", 3 },
  }
  for i, title in ipairs(titles) do
    local s = series[i]
    M.shelf_books[#M.shelf_books + 1] = book_row(200 + i, title, 1950 + i * 3, 200 + i * 11, {
      author = authors[i],
      series = s and s[1] or nil,
      series_position = s and s[2] or nil,
      no_image = (i % 7 == 0), -- no-cover rows land throughout the list
    })
  end
end

--[[--
The books of a series, as Api:getSeriesBooks returns them.

Hainish Cycle is real enough to read: some read, one being read, one wanted, the
rest not on a shelf. The long series has 24 books, with the fixture book 109 at
position 12, so the card has to show a window with "earlier" and "more" rows.
]]
function M.cover_url(id) return "https://covers.hardcover.app/fixture/" .. id .. ".jpg" end

M.series_books = {}
do
  local hainish = {
    { 301, "Rocannon's World", 1, 3 }, { 302, "Planet of Exile", 2, 3 },
    { 303, "City of Illusions", 3, 2 }, { 103, "The Left Hand of Darkness", 4, 2 },
    { 101, "The Dispossessed", 5, 1 }, { 304, "The Word for World Is Forest", 6, nil },
    { 305, "The Telling", 7, nil }, { 306, "Four Ways to Forgiveness", 8, nil },
  }
  local books = {}
  for _, b in ipairs(hainish) do
    books[#books + 1] = {
      book_id = b[1], title = b[2], position = b[3], status_id = b[4],
      -- one book has no cover, so the carousel's placeholder is exercised
      cover = (b[1] ~= 306) and { url = M.cover_url(b[1]) } or nil,
    }
  end
  M.series_books[12] = { id = 12, name = "Hainish Cycle", is_completed = true, books = books }

  local long_books = {}
  for i = 1, 24 do
    long_books[i] = {
      book_id = (i == 12) and 109 or (400 + i),
      title = (i == 12) and "A Book With A Very Long Description" or ("Volume " .. i .. " of the Long Series"),
      position = i,
      status_id = (i < 12) and 3 or nil,
      cover = { url = M.cover_url((i == 12) and 109 or (400 + i)) },
    }
  end
  M.series_books[14] = { id = 14, name = "The Long Series", is_completed = false, books = long_books }
end

--[[--
Reviews of a book, as Api:getReviews returns them: raw user_books rows in the
API's own order (most liked first), with the awkward shapes real data has -- no
`user` at all (privacy), no rating, no reviewed_at, a spoiler, and one review of
several hundred words. Book 103 has 23 of them (three pages of ten); 105 has none.
]]
M.reviews = {}
do
  local paragraph = "I did not expect this book to stay with me the way it has. The first hundred pages are slow, "
    .. "and the world is explained only by what people do in it, never by what anyone says about it. "
    .. "By the middle I had stopped reading for the plot and was reading for the people. "
  local long = {}
  for i = 1, 6 do long[#long + 1] = paragraph .. "(" .. i .. ")" end
  M.reviews[1] = {
    id = 7001, rating = 4.5, review_has_spoilers = false, likes_count = 48, reviewed_at = "2025-11-02T09:15:00",
    review_raw = table.concat(long, "\n\n"), review_length = 2200,
    user = { username = "pagesturner", name = "Maya Okafor" },
  }
  M.reviews[2] = {
    id = 7002, rating = 2, review_has_spoilers = true, likes_count = 31, reviewed_at = nil,
    review_raw = "The ending, where the narrator turns out to have been dead the whole time, felt like a cheat to me.",
    review_length = 100, user = { username = "grumpyreader", name = "" },
  }
  M.reviews[3] = {
    id = 7003, rating = nil, review_has_spoilers = false, likes_count = 12, reviewed_at = nil,
    review_raw = "Short and lovely. Read it in one sitting.", review_length = 42, user = nil,
  }
  for i = 4, 23 do
    M.reviews[i] = {
      id = 7000 + i, rating = (i % 2 == 0) and 3.5 or 5, review_has_spoilers = false,
      likes_count = 24 - i, reviewed_at = "2025-0" .. (i % 9 + 1) .. "-15T10:00:00",
      review_raw = "Review number " .. i .. ": a fair read with some good moments.", review_length = 50,
      user = (i % 3 == 0) and nil or { username = "reader" .. i, name = "Reader " .. i },
    }
  end
end
-- books with a review list; any other book has none
M.reviews_by_book = { [103] = M.reviews }

-- how many books are on each shelf, as the home screen's count query returns them
-- Your lists and a followed one, as `me` returns them (see Lists.normalize). The
-- books of a list are the first N of the shelf fixture, in order.
local function list_covers(n)
  local out = {}
  for i = 1, n do
    out[i] = { book = { cached_image = M.shelf_books[i] and M.shelf_books[i].cached_image } }
  end
  return out
end
M.lists_me = { {
  lists = {
    { id = 1, name = "To Read - SciFi", books_count = 7, ranked = true, privacy_setting_id = 1, list_books = list_covers(3) },
    { id = 2, name = "Books that made me grin", books_count = 4, ranked = false, privacy_setting_id = 1, list_books = list_covers(3) },
    { id = 3, name = "Research", books_count = 1, ranked = false, privacy_setting_id = 3, list_books = list_covers(1) },
    { id = 4, name = "Someday", books_count = 0, ranked = false, privacy_setting_id = 1, list_books = {} },
  },
  followed_lists = {
    { list = { id = 106, name = "Top 25 Books to Unleash Your Creative Potential", books_count = 18, ranked = false,
               user = { username = "hardcover" }, list_books = list_covers(2) } },
  },
} }
-- how many books each list holds when opened (the shelf fixture is long)
M.list_sizes = { [1] = 7, [2] = 4, [3] = 1, [4] = 0, [106] = 18 }

M.shelf_counts = { [2] = 3, [1] = 42, [3] = 130, [5] = 2 }

-- what Api:getCurrentlyReading returns: three books in progress, the last with
-- no cover (so the placeholder is drawn)
M.currently_reading = {
  { book_id = 101, title = "The Dispossessed", authors = "Ursula K. Le Guin", pages = 341,
    progress_pages = 120, edition_pages = 341,
    cached_image = { url = "https://covers.hardcover.app/fixture/101.jpg", width = 300, height = 450 } },
  { book_id = 102, title = "A Wizard of Earthsea", authors = "Ursula K. Le Guin", pages = 183,
    progress_pages = 20, edition_pages = 183,
    cached_image = { url = "https://covers.hardcover.app/fixture/102.jpg", width = 300, height = 450 } },
  { book_id = 105, title = "The Hundred Thousand Kingdoms", authors = "N. K. Jemisin", pages = 418,
    progress_pages = 300, edition_pages = 418 },
}

--[[--
Put the synthetic cover (spec/emu/fixtures/cover.png) into the plugin's real
cover cache under `url`.

The detail screen fetches covers through the cover loader, which answers from
this cache before it touches the network. Seeding it means the real loader, the
real cache and the real image renderer all run, with no network and no mocking
of any of them.
]]
local VARIANTS = { "cover.png", "cover_b.png", "cover_c.png" }

function M.seed_cover(url, variant)
  local root = package.searchpath("hardcover/lib/shelf", package.path):match("^(.*)/hardcover/lib/shelf%.lua$")
  local file = assert(io.open(root .. "/spec/emu/fixtures/" .. VARIANTS[variant or 1], "rb"),
    "a cover fixture is missing: run spec/emu/make_cover.py")
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
  local settings = HardcoverSettings:new(
    emu.DataStorage:getSettingsDir() .. "/hardcoversync_settings.lua",
    ui or emu:stub_ui())
  -- The emulated settings file outlives a run, and the live scenario stores the
  -- real account's id in it: every fixture scenario must start as the fixture user.
  settings:updateSetting(require("hardcover/lib/constants/settings").USER_ID, M.USER_ID)
  return settings
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

  local function record(name, args)
    calls[#calls + 1] = { name = name, at = os.clock(), args = args }
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

  -- One page of reviews. `M.reviews_fail` makes the next calls fail (set to a
  -- number of failures to produce, or true for all of them).
  Api.getReviews = function(_, book_id, limit, offset)
    record("getReviews")
    calls[#calls].args = { book_id = book_id, limit = limit, offset = offset }
    if M.reviews_fail then
      if type(M.reviews_fail) == "number" then
        M.reviews_fail = (M.reviews_fail > 1) and (M.reviews_fail - 1) or nil
      end
      return nil, { completed = false }
    end
    local source = (opts.reviews_by_book or M.reviews_by_book)[book_id] or {}
    local page = {}
    for i = (offset or 0) + 1, math.min((offset or 0) + (limit or 10), #source) do
      page[#page + 1] = deepcopy(source[i])
    end
    return page
  end

  Api.getLists = function(_)
    record("getLists")
    if M.lists_fail then return nil, { completed = false } end
    return require("hardcover/lib/lists").normalize(deepcopy(opts.lists_me or M.lists_me))
  end

  Api.getListCount = function(_)
    record("getListCount")
    local me = (opts.lists_me or M.lists_me)[1]
    return #me.lists + #me.followed_lists
  end

  Api.getListBooks = function(_, list_id, source, ranked, offset, limit)
    record("getListBooks")
    calls[#calls].args = { list_id = list_id, source = source, ranked = ranked, offset = offset }
    local Lists = require("hardcover/lib/lists")
    local total = M.list_sizes[list_id] or 0
    offset, limit = offset or 0, limit or 100
    local entries = {}
    for i = offset + 1, math.min(offset + limit, total) do
      local b = M.shelf_books[i]
      entries[#entries + 1] = Lists.entry({ id = 50000 + i, position = i - 1, date_added = "2026-01-01", book = b }, ranked)
    end
    return entries, nil, total > offset + limit
  end

  Api.getSeriesBooks = function(_, series_id, user_id)
    record("getSeriesBooks")
    return M.series_books[series_id]
  end

  Api.getShelfCounts = function(_, user_id, status_ids)
    record("getShelfCounts")
    local counts = {}
    for _, id in ipairs(status_ids or {}) do
      counts[id] = M.shelf_counts[id]
    end
    return counts
  end

  Api.getCurrentlyReading = function(_, user_id, limit)
    record("getCurrentlyReading")
    return deepcopy(M.currently_reading)
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
    if M.not_in_library[b.book_id] then
      -- a book the reader has not shelved: no status, rating or library record
      return { book = detail }
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
    record("updateUserBook", { book_id = book_id, status_id = status_id, edition_id = edition_id })
    return { id = 9000 + book_id, book_id = book_id, status_id = status_id, rating = 0 }
  end

  Api.removeUserBook = function(_, user_book_id)
    record("removeUserBook", { user_book_id = user_book_id })
    return { id = user_book_id }
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
