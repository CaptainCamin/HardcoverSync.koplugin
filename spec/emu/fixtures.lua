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
    cached_image = opts.no_image and nil or {
      url = opts.image_url or "https://covers.hardcover.app/fixture/" .. id .. ".jpg",
      width = 300,
      height = 450,
    },
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
  book_row(108, "The Obelisk Gate", 2016, 448, { author = "N. K. Jemisin" }),
}

M.books_by_id = {}
for _, b in ipairs(M.books) do M.books_by_id[b.book_id] = b end

--[[--
Replace the API layer with fixtures.

Patches the methods the plugin calls, on the module table it actually calls
them on. Anything not listed here still runs for real and will attempt a
request -- which fails cleanly offline -- so a scenario that quietly depends on
an unstubbed call shows up as an empty screen rather than as a false pass.
]]
function M.install(overrides)
  local Api = require("hardcover/lib/hardcover_api")
  local User = require("hardcover/lib/user")

  User.settings = User.settings or {
    -- dialogs ask the settings object for these; keep them cheap and total
    compatibilityMode = function() return false end,
    pages = function() return 341 end,
  }
  User.getId = User.getId or function() return M.USER_ID end

  -- Never let a scenario touch the network, whatever it forgets to stub.
  Api.enabled = true
  Api._emu_offline = true

  local calls = {}
  M.calls = calls

  local function record(name)
    calls[#calls + 1] = { name = name, at = os.clock() }
  end

  Api.getShelf = function(_, user_id, status_id, offset, limit)
    record("getShelf")
    offset, limit = offset or 0, limit or 20
    local page = {}
    for i = offset + 1, math.min(offset + limit, #M.books) do
      local b = M.books[i]
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
    local has_more = (#M.books > offset + limit)
    return entries, nil, has_more
  end

  Api.getBookDetail = function(_, book_id, user_id, edition_id)
    record("getBookDetail")
    local b = M.books_by_id[book_id] or M.books[1]
    local detail = require("hardcover/lib/table_util").tableDeepCopy(b)
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
        out[#out + 1] = require("hardcover/lib/table_util").tableDeepCopy(b)
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
        book = require("hardcover/lib/table_util").tableDeepCopy(b),
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

  for k, v in pairs(overrides or {}) do
    Api[k] = v
  end

  return Api
end

return M
