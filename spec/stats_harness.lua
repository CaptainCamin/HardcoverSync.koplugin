package.path = "./?.lua;./hardcover/?.lua;" .. package.path
local Stats = require("hardcover/lib/stats")

local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function ub(id, o)
  o = o or {}
  return {
    id = id, rating = o.rating, last_read_date = o.last, user_book_reads = o.read and { o.read } or {},
    book = { title = o.title or ("Book " .. id), pages = o.pages, audio_seconds = o.audio,
      contributions = o.author and { { author = { name = o.author } } } or {} },
  }
end

-- dates: a read's finish wins; month / year precision are never placed on a day
local rows = Stats.normalizeAll({
  ub(1, { read = { finished_at = "2025-03-14", finished_at_precision = 1 }, last = "2024-01-01", pages = 350, rating = 4.5, author = "A" }),
  ub(2, { last = "2025-03-02", pages = 180, rating = 3, author = "A" }),
  ub(3, { read = { finished_at = "2025-07-01", finished_at_precision = 2 }, pages = 620, rating = 5, author = "B" }),
  ub(4, { read = { finished_at = "2025-01-01", finished_at_precision = 3 }, audio = 36000, rating = 4 }),
  ub(5, { pages = 410 }),                                   -- undated import
  ub(6, { read = { finished_at = "2023-12-31T23:59:00Z", finished_at_precision = 1 }, pages = 90, author = "A" }),
})
eq(#rows, 6, "rows")
eq(rows[1].date, "2025-03-14", "read beats last_read_date")
eq(rows[3].date, "2025-07", "month precision")
eq(rows[4].date, "2025", "year precision")
eq(rows[5].date, nil, "undated")
eq(rows[6].date, "2023-12-31", "timestamp trimmed")

local all = Stats.compute(rows)
eq(all.books, 6, "all-time books")
eq(all.undated, 1, "undated")
eq(all.pages, 350 + 180 + 620 + 410 + 90, "pages")
eq(all.pages_books, 5, "pages_books")
eq(all.audio_books, 1, "audio books")
eq(all.audio_seconds, 36000, "audio seconds")
eq(all.ratings.rated, 4, "rated")
eq(all.ratings.counts[9], 1, "4.5 stars")
eq(all.ratings.counts[6], 1, "3 stars")
eq(all.ratings.average, 4.125, "average")
eq(#all.by_year, 3, "years 2023..2025 filled")
eq(all.by_year[2].count, 0, "2024 has none")
eq(all.by_year[3].count, 4, "2025")
eq(all.authors[1].name, "A", "top author")
eq(all.authors[1].count, 3, "top author count")
eq(all.longest.pages, 620, "longest")
eq(all.shortest.pages, 90, "shortest")
eq(#all.page_list, all.pages_books, "a page count for each book that has one")
eq(all.page_list[1], 90, "page counts smallest first")
eq(all.page_list[#all.page_list], 620, "page counts end on the longest")

local y25 = Stats.compute(rows, { year = 2025 })
eq(y25.books, 4, "2025 books")
eq(y25.undated, 0, "no undated in a year")
eq(y25.months[3], 2, "March")
eq(y25.months[7], 1, "July from month precision")
eq(y25.months[1], 0, "year precision not January")
eq(y25.month_unknown, 1, "year-only finish noted")
eq(y25.best_month.month, 3, "best month")
eq(y25.last_month, 7, "the latest month with a finish")
eq(Stats.years(rows)[1], 2025, "years newest first")
eq(#Stats.years(rows), 2, "years")

-- tiny and empty and junk
local none = Stats.compute({})
eq(none.books, 0, "empty") eq(none.ratings.average, nil, "no average") eq(#none.by_year, 0, "no years")
eq(#Stats.normalizeAll({ "x", 5, false }), 0, "junk rows")
eq(#Stats.normalizeAll(nil), 0, "nil list")
local one = Stats.compute(Stats.normalizeAll({ ub(1, { pages = 100, rating = 4, author = "Z" }) }))
eq(#one.authors, 0, "a single book has no top authors")
eq(Stats.normalize({ id = 1, rating = 9, book = { pages = -4 } }).rating, nil, "out of range rating")
eq(Stats.normalize({ id = 1, rating = 9, book = { pages = -4 } }).pages, nil, "negative pages")

-- a very long history is capped
local many = {}
for y = 1980, 2025 do many[#many + 1] = ub(y, { last = y .. "-05-05" }) end
eq(#Stats.compute(Stats.normalizeAll(many)).by_year, 30, "history capped at 30 years")

-- genres
local g = Stats.genres({ { tag = "B", count = 2 }, { tag = "A", count = 2 }, { tag = "C", count = 9 }, { tag = "D", count = 0 }, "x" })
eq(#g, 3, "genres") eq(g[1].label, "C", "genre order") eq(g[2].label, "A", "genre tie by name")

print("stats_harness OK")
