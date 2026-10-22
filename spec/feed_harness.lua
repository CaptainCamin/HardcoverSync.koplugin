-- The activity feed: the request it builds, and how the three answers become one list.
--
-- Run with:  lua spec/feed_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local Feed = require("hardcover/lib/feed")

local results = { passed = 0, failed = 0 }
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then results.passed = results.passed + 1 print("  [ok  ] " .. name)
  else results.failed = results.failed + 1 print("  [FAIL] " .. name .. "\n         " .. tostring(err)) end
end
local function eq(a, b, label)
  if a ~= b then error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function has(text, part)
  if not text:find(part, 1, true) then error("missing: " .. part .. "\n" .. text, 2) end
end
local function lacks(text, part)
  if text:find(part, 1, true) then error("should not contain: " .. part, 2) end
end

print("\n== the request ==")

check("nobody to ask about gives no request", function()
  eq(Feed.query({}), nil)
  eq(Feed.query({ user_ids = {} }), nil)
end)

check("one request asks all three sources for you and the readers followed", function()
  local q = Feed.query({ me_id = 7, user_ids = { 11, 12 }, limit = 20 })
  has(q, "activities(")
  has(q, "journals: reading_journals(")
  has(q, "reviews: user_books(")
  has(q, "user_id: { _in: [7, 11, 12] }")
  has(q, "limit: 20")
  lacks(q, "_lte")
end)

check("others' notes need to be public or for followers; yours come whatever the privacy", function()
  local q = Feed.query({ me_id = 7, user_ids = { 11 } })
  has(q, "{ user_id: { _eq: 7 } }")
  has(q, "privacy_setting_id: { _in: [1, 2] }")
end)

check("mine asks about you alone", function()
  local q = Feed.query({ me_id = 7, user_ids = { 11 }, mine = true })
  has(q, "[7]")
  lacks(q, "11")
end)

check("only the kinds asked for are asked", function()
  local q = Feed.query({ me_id = 7, kinds = { "quote" } })
  lacks(q, "activities(")
  lacks(q, "user_books(")
  has(q, "event: { _in: [\"quote\"] }")
  q = Feed.query({ me_id = 7, kinds = { "review" } })
  lacks(q, "reading_journals")
  has(q, "user_books(")
  q = Feed.query({ me_id = 7, kinds = { "bogus" } })
  has(q, "activities(")
end)

check("before pages each source; reviews by day", function()
  local q = Feed.query({ me_id = 7, before = "2026-10-21T16:14:50.641+00:00" })
  has(q, "created_at: { _lte: \"2026-10-21T16:14:50.641+00:00\" }")
  has(q, "reviewed_at: { _is_null: false, _lte: \"2026-10-21\" }")
  eq(select(2, q:gsub("reviewed_at: {", "")), 1, "reviewed_at conditions")
end)

check("nothing typed or received reaches the query text", function()
  local q = Feed.query({ me_id = "7; drop", user_ids = { "1 } }", 12.5, 12, 12 }, before = "x\" }) { id" })
  has(q, "[12]")
  lacks(q, "drop")
  lacks(q, "x\"")
  lacks(q, "_lte")
end)

check("no more than MAX_READERS readers", function()
  local ids = {}
  for i = 1, Feed.MAX_READERS + 50 do ids[i] = i + 100 end
  local q = Feed.query({ me_id = 1, user_ids = ids })
  has(q, "[1, 101")
  lacks(q, "," .. " " .. (Feed.MAX_READERS + 150))
end)

print("\n== the answer ==")

local function answer()
  return {
    activities = {
      { id = 1, event = "UserBookActivity", user_id = 11, created_at = "2026-10-20T10:00:00+00:00",
        user = { name = "Dana", username = "dana" }, book = { id = 5, title = "Dune" },
        data = { userBook = { statusId = 2, progress = 40.4 } } },
      { id = 2, event = "UserBookActivity", user_id = 7, created_at = "2026-10-18T10:00:00+00:00",
        user = { username = "me" }, data = { userBook = { statusId = 3, rating = 4.5, edition = { title = "Emma" } } } },
      { id = 3, event = "ListActivity", user_id = 11, created_at = "2026-10-19T10:00:00+00:00", data = { list = {} } },
    },
    journals = {
      { id = 9, event = "quote", entry = "Fear is the mind-killer.", user_id = 11, created_at = "2026-10-21T08:00:00+00:00",
        metadata = { position = { type = "pages", value = 12 } }, user = { name = "Dana" }, book = { id = 5, title = "Dune" } },
      { id = 10, event = "note", entry = "   ", user_id = 11, created_at = "2026-10-21T09:00:00+00:00" },
    },
    reviews = {
      { id = 4, user_id = 12, rating = 5, review_raw = "Loved it.", review_has_spoilers = true,
        reviewed_at = "2026-10-19", user = { username = "ravi" }, book = { id = 6, title = "Kindred" } },
      { id = 5, user_id = 12, rating = 3, review_raw = "", reviewed_at = "2026-10-17" },
    },
  }
end

check("the three sources become one list, newest first", function()
  local page = Feed.parse(answer(), 20)
  local kinds = {}
  for _, e in ipairs(page.entries) do kinds[#kinds + 1] = e.kind end
  eq(table.concat(kinds, ","), "quote,status,review,status")
  eq(page.more, false)
  eq(page.cursor, "2026-10-18T10:00:00+00:00")
end)

check("rows that are not the feed's are left out: lists, empty notes, reviews with no text", function()
  local page = Feed.parse(answer(), 20)
  eq(#page.entries, 4)
end)

check("status text says what changed", function()
  local page = Feed.parse(answer(), 20)
  eq(page.entries[2].text, "Reading, 40%")
  eq(page.entries[4].text, "Finished, rated 4.5*")
end)

check("a title falls back to the edition's, then to a placeholder", function()
  local page = Feed.parse(answer(), 20)
  eq(page.entries[4].title, "Emma")
  local data = answer()
  data.activities[2].data.userBook.edition = nil
  eq(Feed.parse(data, 20).entries[4].title, "A book")
end)

check("names fall back to the username, then to A reader", function()
  local page = Feed.parse(answer(), 20)
  eq(page.entries[1].who, "Dana")
  eq(page.entries[3].who, "ravi")
  local data = answer()
  data.reviews[1].user = nil
  eq(Feed.parse(data, 20).entries[3].who, "A reader")
end)

check("a quote keeps its page, a review its rating and spoiler flag", function()
  local page = Feed.parse(answer(), 20)
  eq(page.entries[1].page, 12)
  eq(page.entries[3].rating, "5*")
  eq(page.entries[3].spoilers, true)
  eq(page.entries[3].date, "2026-10-19")
end)

check("a page keeps the newest and says there is more", function()
  local page = Feed.parse(answer(), 2)
  eq(#page.entries, 2)
  eq(page.entries[2].kind, "status")
  eq(page.cursor, "2026-10-20T10:00:00+00:00")
  eq(page.more, true)
end)

check("a source that filled its page means there may be more", function()
  local data = { journals = {
    { id = 1, event = "note", entry = "a", created_at = "2026-10-01T00:00:00+00:00" },
    { id = 2, event = "note", entry = "b", created_at = "2026-10-02T00:00:00+00:00" },
  } }
  eq(Feed.parse(data, 2).more, true)
  eq(Feed.parse(data, 3).more, false)
end)

check("an empty or odd answer is an empty page", function()
  local page = Feed.parse({}, 20)
  eq(#page.entries, 0)
  eq(page.more, false)
  eq(page.cursor, nil)
  eq(#Feed.parse(nil).entries, 0)
end)

check("equal times keep a stable order", function()
  local data = { journals = {
    { id = 1, event = "note", entry = "a", created_at = "2026-10-01T00:00:00+00:00" },
    { id = 2, event = "note", entry = "b", created_at = "2026-10-01T00:00:00+00:00" },
  } }
  local a = Feed.parse(data, 20).entries
  eq(a[1].key, "note:2")
  eq(a[2].key, "note:1")
end)

check("a long note gets an excerpt and keeps its whole text", function()
  local long = string.rep("word ", 200)
  local page = Feed.parse({ journals = { { id = 1, event = "note", entry = long, created_at = "2026-10-01T00:00:00+00:00" } } }, 20)
  eq(page.entries[1].truncated, true)
  assert(#page.entries[1].excerpt < #long)
  eq(page.entries[1].text, long)
end)

print("\n== the rows ==")

check("a status change shows the book, and opens it", function()
  local row = Feed.row(Feed.parse(answer(), 20).entries[2])
  eq(row.label, "Dune")
  eq(row.support, "Oct 20 \194\183 Dana \194\183 Reading, 40%")
  eq(row.action, "book")
end)

check("a quote is quoted, says it is a quote and opens in full", function()
  local row = Feed.row(Feed.parse(answer(), 20).entries[1])
  eq(row.label, "\226\128\156Fear is the mind-killer.\226\128\157")
  eq(row.support, "Oct 21 \194\183 Dana \194\183 Quote \194\183 Dune")
  eq(row.action, "full")
  eq(row.icon, "bookmark")
end)

check("a review leads with its rating, and a spoiler is not given away", function()
  local entries = Feed.parse(answer(), 20).entries
  local row = Feed.row(entries[3])
  eq(row.label, Feed.SPOILER_LABEL)
  eq(row.support, "Oct 19 \194\183 ravi \194\183 Review \194\183 Kindred")
  local data = answer()
  data.reviews[1].review_has_spoilers = false
  row = Feed.row(Feed.parse(data, 20).entries[3])
  eq(row.label, "5*  Loved it.")
end)

check("a status change with no book opens nothing", function()
  local data = answer()
  data.activities[2].book = nil
  eq(Feed.row(Feed.parse(data, 20).entries[4]).action, nil)
end)

check("the heading over the whole text names who, what and which book", function()
  local entries = Feed.parse(answer(), 20).entries
  eq(Feed.heading(entries[1]), "Dana \194\183 Quote \194\183 Dune \194\183 p. 12")
  eq(Feed.heading(entries[3]), "ravi \194\183 Review \194\183 Kindred")
end)

check("short dates", function()
  eq(Feed.shortDate("2026-01-05"), "Jan 5")
  eq(Feed.shortDate("2026-12-31"), "Dec 31")
  eq(Feed.shortDate(nil), nil)
  eq(Feed.shortDate("soon"), nil)
end)

print("\n== the next page ==")

check("append adds the new entries and drops the ones already held", function()
  local first = Feed.parse(answer(), 2).entries
  local all, added = Feed.append(first, Feed.parse(answer(), 20).entries)
  eq(#all, 4)
  eq(added, 2)
  eq(all[1].key, first[1].key)
  local _, again = Feed.append(all, Feed.parse(answer(), 20).entries)
  eq(again, 0)
end)

check("append of nothing keeps what is held", function()
  local all, added = Feed.append({ { key = "a" } }, nil)
  eq(#all, 1)
  eq(added, 0)
end)

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
