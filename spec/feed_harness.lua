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

print("\n== what is waiting to send ==")

-- as JournalQueue:list and ReviewQueue:list give them
local function journalOps()
  return {
    { id = "100-1", seq = 1, user_id = 1, book_id = 5, event = "note", text = "First note", title = "Dune" },
    { id = "100-2", seq = 2, user_id = 2, book_id = 5, event = "note", text = "Someone else's", title = "Dune" },
    { id = "100-3", seq = 3, book_id = 6, event = "quote", text = "Truth is\nsimple", page = 12, title = "Kindred" },
    { id = "100-4", seq = 4, user_id = 1, book_id = 5, event = "note", text = "   ", title = "Dune" },
    { id = "100-5", seq = 5, user_id = 1, book_id = 7, event = "note", text = "No title" },
  }
end
local function reviewOps()
  return {
    { user_book_id = 900, text = "It gives it all away", spoilers = true, title = "Dune" },
    { user_book_id = 901, text = "", spoilers = false, title = "Kindred" },
  }
end

check("your notes and quotes come newest first, then your reviews; others' and blank ones are left out", function()
  local waiting = Feed.waiting(journalOps(), reviewOps(), 1)
  eq(#waiting, 4, "count")
  eq(waiting[1].key, "waiting:100-5")
  eq(waiting[2].key, "waiting:100-3", "an entry with no user is yours")
  eq(waiting[3].key, "waiting:100-1")
  eq(waiting[4].key, "waiting:review:900")
  for _, e in ipairs(waiting) do
    eq(e.waiting, true, "waiting")
    eq(e.who, "You", "who")
  end
end)

check("a waiting entry has what a row and the full text need", function()
  local waiting = Feed.waiting(journalOps(), reviewOps(), 1)
  eq(waiting[1].title, "A book", "a missing title")
  eq(waiting[2].kind, "quote")
  eq(waiting[2].page, 12)
  eq(waiting[2].book_id, 6)
  eq(waiting[2].text, "Truth is\nsimple", "the whole text is kept")
  has(waiting[2].excerpt, "Truth is")
  lacks(waiting[2].excerpt, "\n")
  eq(waiting[4].kind, "review")
  eq(waiting[4].spoilers, true)
end)

check("a waiting row says so instead of a date", function()
  local waiting = Feed.waiting(journalOps(), reviewOps(), 1)
  local row = Feed.row(waiting[3])
  eq(row.support, "Waiting to send \194\183 You \194\183 Note \194\183 Dune")
  eq(row.action, "full")
  eq(Feed.row(waiting[4]).label, Feed.SPOILER_LABEL, "a waiting review still hides its spoilers")
  eq(Feed.heading(waiting[2]), "You \194\183 Quote \194\183 Kindred \194\183 p. 12")
end)

check("nothing waiting, or no queues, is an empty list", function()
  eq(#Feed.waiting(nil, nil, 1), 0)
  eq(#Feed.waiting({}, {}, 1), 0)
end)

-- Hardcover's entries as the tab holds them
local function held()
  return {
    { key = "note:4001", id = 4001, kind = "note", user_id = 1, who = "Dana", title = "Dune", text = "Old words", excerpt = "Old words", date = "2026-10-20" },
    { key = "quote:4002", id = 4002, kind = "quote", user_id = 1, who = "Dana", title = "Dune", text = "A quote", excerpt = "A quote", date = "2026-10-19" },
    { key = "review:900", id = 900, kind = "review", user_id = 1, who = "Dana", title = "Dune", text = "Fine", excerpt = "Fine", date = "2026-10-18" },
    { key = "review:901", id = 901, kind = "review", user_id = 1, who = "Dana", title = "Kindred", text = "Great", excerpt = "Great", date = "2026-10-17" },
    { key = "status:1", kind = "status", user_id = 1, who = "Dana", title = "Dune", text = "Finished", date = "2026-10-16" },
  }
end

check("with nothing waiting, the tab shows what Hardcover has", function()
  local all = Feed.withPending(held(), {}, {}, 1)
  eq(#all, 5)
  eq(all[1].key, "note:4001")
  eq(all[1].waiting, nil)
  eq(#Feed.withPending(nil, nil, nil, 1), 0)
end)

check("new writing goes above what Hardcover has", function()
  local all = Feed.withPending(held(), journalOps(), {}, 1)
  eq(#all, 8)
  eq(all[1].key, "waiting:100-5")
  eq(all[1].queue_id, "100-5")
  eq(all[4].key, "note:4001")
end)

check("an edit waiting to send shows its new text in place; a delete waiting to send hides the entry", function()
  local ops = {
    { id = "1-1", seq = 1, action = "update", user_id = 1, journal_id = 4001, event = "note", text = "New words" },
    { id = "1-2", seq = 2, action = "delete", user_id = 1, journal_id = 4002, event = "quote" },
    { id = "1-3", seq = 3, action = "delete", user_id = 2, journal_id = 4001, event = "note" },
  }
  local h = held()
  local all = Feed.withPending(h, ops, {}, 1)
  eq(#all, 4, "the deleted quote is left out, and another account's delete is not yours")
  eq(all[1].key, "note:4001", "an edit stays where the entry is")
  eq(all[1].text, "New words")
  eq(all[1].excerpt, "New words")
  eq(all[1].waiting, true)
  eq(all[1].id, 4001)
  eq(Feed.row(all[1]).support, "Waiting to send \194\183 Dana \194\183 Note \194\183 Dune")
  eq(all[2].key, "review:900")
  eq(h[1].text, "Old words", "the held entry itself (what is saved) is not changed")
  eq(h[1].waiting, nil)
end)

check("a review waiting for a book whose review is listed changes it in place; an empty one hides it", function()
  local reviews = {
    { user_book_id = 900, text = "Better now", spoilers = true, title = "Dune" },
    { user_book_id = 901, text = "", spoilers = false, title = "Kindred" },
    { user_book_id = 902, text = "A new one", spoilers = false, title = "Emma" },
  }
  local all = Feed.withPending(held(), {}, reviews, 1)
  eq(#all, 5)
  eq(all[1].key, "waiting:review:902", "a review Hardcover does not list yet is new writing")
  eq(all[1].user_book_id, 902)
  local review = all[4]
  eq(review.key, "review:900")
  eq(review.text, "Better now"); eq(review.spoilers, true); eq(review.waiting, true)
  for _, e in ipairs(all) do
    if e.key == "review:901" then error("a review being removed is still listed") end
  end
end)

check("the id an edit is sent for, from the entry or from its key", function()
  eq(Feed.idOf({ id = 7, key = "note:9" }), 7)
  eq(Feed.idOf({ key = "quote:4002" }), 4002)
  eq(Feed.idOf({ key = "waiting:1-2" }), nil)
  eq(Feed.idOf(nil), nil)
end)

check("parsed entries carry their id", function()
  local entries = Feed.parse(answer(), 20).entries
  for _, e in ipairs(entries) do
    eq(e.id ~= nil, true, "no id on " .. e.key)
    eq(tostring(e.id), e.key:match(":(%d+)$"), "id of " .. e.key)
  end
end)

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
