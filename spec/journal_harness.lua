-- Your journal: the request for a page, what each kind of entry says happened, the day it shows,
-- and what is waiting to send laid over Hardcover's entries.
--
-- Run with:  lua spec/journal_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local Journal = require("hardcover/lib/journal")

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

local DOT = " \194\183 "
local LQ, RQ = "\226\128\156", "\226\128\157"

print("\n== the request ==")

check("no user gives no request", function()
  eq(Journal.query({}), nil)
  eq(Journal.query({ me_id = "seven" }), nil)
end)

check("a page of your journal, newest first, from an offset", function()
  local q = Journal.query({ me_id = 7, offset = 40, limit = 20 })
  has(q, "reading_journals(")
  has(q, "where: { user_id: { _eq: 7 } }")
  has(q, "order_by: [{ action_at: desc }, { id: desc }]")
  has(q, "offset: 40")
  has(q, "limit: 20")
  has(q, "id event entry metadata action_at user_id book_id")
  has(q, "cached_image contributions: cached_contributors")
  -- your review of the book as it is now, for a "reviewed" entry
  has(q, "reviews: user_books(where: { user_id: { _eq: 7 }, has_review: { _eq: true } }, limit: 1)")
  has(q, "id review_raw review_has_spoilers")
  lacks(q, "_aggregate")
end)

check("one book asks for that book's entries alone", function()
  local q = Journal.query({ me_id = 7, book_id = 328491 })
  has(q, "where: { user_id: { _eq: 7 }, book_id: { _eq: 328491 } }")
  lacks(Journal.query({ me_id = 7 }), "book_id: {")
  lacks(Journal.query({ me_id = 7, book_id = "1) { x" }), "book_id: {")
end)

check("the first page starts at 0 and the page size is the default", function()
  local q = Journal.query({ me_id = 7 })
  has(q, "offset: 0")
  has(q, "limit: " .. Journal.PAGE_SIZE)
end)

check("only whole numbers reach the query text", function()
  local q = Journal.query({ me_id = "7; drop", offset = "1 } {", limit = -3 })
  eq(q, nil, "a user id that is not a number")
  q = Journal.query({ me_id = 7, offset = "1 } {", limit = -3 })
  has(q, "offset: 0")
  has(q, "limit: 20")
  lacks(q, "} {")
end)

print("\n== the answer ==")

local DUNE = {
  id = 5, title = "Dune",
  cached_image = { url = "https://example.test/dune.jpg", width = 333, height = 500 },
  contributions = {
    { author = { name = "Frank Herbert" }, contribution = "Author", primary = true },
    { author = { name = "A Translator" }, contribution = "Translator" },
    { author = { name = "Frank Herbert" }, contribution = "Author" },
  },
  reviews = {},
}
local KINDRED = {
  id = 6, title = "Kindred",
  contributions = { { author = { name = "Octavia E. Butler" }, contribution = "Author" } },
  reviews = { { id = 900, review_raw = "The ending is wonderful.", review_has_spoilers = true } },
}

local function rows()
  return {
    { id = 11, event = "progress_updated", entry = nil, user_id = 1, book_id = 5, action_at = "2026-10-22T16:58:00.516542+00:00",
      metadata = { progress = 56.4, progress_was = 13, progress_pages = 209, progress_pages_was = 50 }, book = DUNE },
    { id = 10, event = "quote", entry = "Fear is the mind-killer.", user_id = 1, book_id = 5, action_at = "2026-10-22T10:00:00+00:00",
      metadata = { position = { type = "pages", value = 12, possible = 400 } }, book = DUNE },
    { id = 9, event = "note", entry = "Line one\n\nline two", user_id = 1, book_id = 5, action_at = "2026-10-21T10:00:00+00:00",
      metadata = {}, book = DUNE },
    { id = 8, event = "rated", user_id = 1, book_id = 6, action_at = "2026-10-20T10:00:00+00:00", metadata = { rating = "4.0" }, book = KINDRED },
    { id = 7, event = "reviewed", user_id = 1, book_id = 6, action_at = "2026-10-20T09:00:00+00:00",
      metadata = { user_book_id = 899, review_raw = "First words" }, book = KINDRED },
    { id = 6, event = "user_book_read_finished", user_id = 1, book_id = 6, action_at = "2026-10-19T10:00:00+00:00",
      metadata = { finished_at = "2026-10-19" }, book = KINDRED },
    { id = 5, event = "user_book_read_started", user_id = 1, book_id = 6, action_at = "2026-10-18T21:00:00+00:00",
      metadata = { started_at = "2026-10-19" }, book = KINDRED },
    { id = 4, event = "list_book", user_id = 1, book_id = 5, action_at = "2026-10-17T10:00:00+00:00",
      metadata = { list_name = "Favourite classics", list_id = 3 }, book = DUNE },
    { id = 3, event = "status_want_to_read", user_id = 1, book_id = 5, action_at = "2026-10-16T10:00:00+00:00", metadata = {}, book = DUNE },
    { id = 2, event = "referral_to", user_id = 1, book_id = 5, action_at = "2026-10-15T10:00:00+00:00",
      metadata = { referred_username = "someone" }, book = DUNE },
    { id = 1, event = "note", entry = "   ", user_id = 1, book_id = 5, action_at = "2026-10-14T10:00:00+00:00", metadata = {}, book = DUNE },
  }
end

local function byKey(entries)
  local out = {}
  for _, e in ipairs(entries) do out[e.key] = e end
  return out
end

check("one entry per row in Hardcover's order; a referral and an empty note are left out but counted", function()
  local page = Journal.parse({ reading_journals = rows() }, 20)
  eq(#page.entries, 9)
  eq(page.count, 11, "the rows Hardcover sent, for the next offset")
  eq(page.more, false, "fewer rows than asked for")
  eq(page.entries[1].key, "progress_updated:11")
  eq(page.entries[2].key, "quote:10")
  eq(page.entries[9].key, "status_want_to_read:3")
end)

check("a full page says there may be more", function()
  eq(Journal.parse({ reading_journals = rows() }, 11).more, true)
  eq(Journal.parse({ reading_journals = rows() }, 12).more, false)
  local empty = Journal.parse({ reading_journals = {} }, 20)
  eq(#empty.entries, 0); eq(empty.count, 0); eq(empty.more, false)
  eq(#Journal.parse(nil).entries, 0)
  eq(#Journal.parse({ errors = {} }, 20).entries, 0)
end)

check("every entry has its book: id, title, the authors and the cover", function()
  local e = Journal.parse({ reading_journals = rows() }, 20).entries[1]
  eq(e.id, 11); eq(e.book_id, 5); eq(e.title, "Dune"); eq(e.user_id, 1)
  eq(e.authors, "Frank Herbert", "authors credited as author, each once")
  eq(e.cover_url, "https://example.test/dune.jpg")
  eq(e.at, "2026-10-22T16:58:00.516542+00:00")
  local bare = Journal.parse({ reading_journals = { { id = 1, event = "rated", action_at = "2026-10-01T00:00:00Z",
    book_id = 3, metadata = {} } } }, 20).entries[1]
  eq(bare.title, "A book"); eq(bare.authors, nil); eq(bare.cover_url, nil); eq(bare.book_id, 3)
  local translated = Journal.parse({ reading_journals = { { id = 1, event = "rated", action_at = "2026-10-01T00:00:00Z",
    book = { id = 3, contributions = { { author = { name = "Only Editor" }, contribution = "Editor" } } }, metadata = {} } } }, 20).entries[1]
  eq(translated.authors, "Only Editor", "with no one credited as author, whoever is credited")
end)

check("what each kind says happened", function()
  local e = byKey(Journal.parse({ reading_journals = rows() }, 20).entries)
  eq(e["progress_updated:11"].action, "Updated progress from 13% to 56%")
  eq(e["rated:8"].action, "Rated 4 out of 5")
  eq(e["user_book_read_finished:6"].action, "Finished reading")
  eq(e["user_book_read_started:5"].action, "Started reading")
  eq(e["list_book:4"].action, "Added to the list " .. LQ .. "Favourite classics" .. RQ)
  eq(e["status_want_to_read:3"].action, "Marked as want to read")
  for _, key in ipairs({ "progress_updated:11", "rated:8", "list_book:4" }) do eq(e[key].kind, "event", key) end
end)

check("the other kinds Hardcover writes", function()
  local function action(event, metadata)
    local page = Journal.parse({ reading_journals = { { id = 1, event = event, action_at = "2026-10-01T00:00:00Z",
      metadata = metadata or {}, book = { id = 1, title = "X" } } } }, 20)
    return page.entries[1] and page.entries[1].action
  end
  eq(action("status_read"), "Marked as read")
  eq(action("status_stopped"), "Marked as did not finish")
  eq(action("status_currently_reading"), "Marked as currently reading")
  eq(action("status_paused"), "Marked as paused")
  eq(action("status_something_new"), "Changed the status")
  eq(action("rated", { rating = "3.5" }), "Rated 3.5 out of 5")
  eq(action("rated", {}), "Changed your rating")
  eq(action("progress_updated", { progress = 40 }), "Updated progress to 40%")
  eq(action("progress_updated", { progress_pages = 120 }), "Updated progress to page 120")
  eq(action("progress_updated", {}), "Updated progress")
  eq(action("list_book", {}), "Added to a list")
  eq(action("prompt_book", { prompt = "Books like rain" }), "Added to the prompt " .. LQ .. "Books like rain" .. RQ)
  eq(action("referral_to"), nil)
  eq(action("something_else"), nil)
end)

check("progress that displays no change is hidden but still counted for paging", function()
  local function row(id, was, now)
    return { id = id, event = "progress_updated", action_at = "2026-10-01T00:00:00Z",
      metadata = { progress_was = was, progress = now } }
  end
  local page = Journal.parse({ reading_journals = { row(1, 13, 13), row(2, 13.1, 13.4),
    row(3, 13.4, 13.6), row(4, nil, 13) } }, 4)
  eq(page.count, 4); eq(page.more, true); eq(#page.entries, 2)
  eq(page.entries[1].action, "Updated progress from 13% to 14%")
  eq(page.entries[2].action, "Updated progress to 13%")
  local saved = { { key = "progress_updated:9", kind = "event", event = "progress_updated",
    action = "Updated progress from 13% to 13%" }, page.entries[1] }
  local shown = Journal.withPending(saved, {}, {}, 1)
  eq(#shown, 1); eq(shown[1].key, "progress_updated:3")
end)

check("a note or quote keeps its whole text, an excerpt, and the page", function()
  local e = byKey(Journal.parse({ reading_journals = rows() }, 20).entries)
  local quote, note = e["quote:10"], e["note:9"]
  eq(quote.kind, "quote"); eq(quote.text, "Fear is the mind-killer."); eq(quote.page, 12)
  eq(note.kind, "note"); eq(note.text, "Line one\n\nline two")
  lacks(note.excerpt, "\n")
  local long = string.rep("word ", 200)
  local cut = Journal.parse({ reading_journals = { { id = 1, event = "note", entry = long, action_at = "2026-10-01T00:00:00Z" } } }, 20).entries[1]
  eq(cut.truncated, true); eq(cut.text, long)
end)

check("a review shows your review of the book as it is now, and knows its library record", function()
  local review = byKey(Journal.parse({ reading_journals = rows() }, 20).entries)["reviewed:7"]
  eq(review.kind, "review")
  eq(review.text, "The ending is wonderful.", "not the first words the entry recorded")
  eq(review.spoilers, true)
  eq(review.user_book_id, 900)
end)

check("a review since removed says only that you reviewed it", function()
  local row = { id = 7, event = "reviewed", action_at = "2026-10-20T09:00:00+00:00", metadata = { user_book_id = 899, review_raw = "Old" },
    book = { id = 6, title = "Kindred", reviews = {} } }
  local review = Journal.parse({ reading_journals = { row } }, 20).entries[1]
  eq(review.kind, "review"); eq(review.text, nil); eq(review.user_book_id, 899)
  local shown = Journal.row(review)
  eq(shown.what, "Reviewed"); eq(shown.open, "book")
end)

print("\n== when ==")

check("an ISO time is read as the moment it stands for", function()
  eq(Journal.epoch("1970-01-01T00:00:00Z"), 0)
  eq(Journal.epoch("1970-01-02T00:00:00+00:00"), 86400)
  eq(Journal.epoch("2026-10-21T21:00:00+00:00"), Journal.epoch("2026-10-22T00:00:00+03:00"))
  eq(Journal.epoch("2026-10-21T16:00:00-05:00"), Journal.epoch("2026-10-21T21:00:00Z"))
  eq(Journal.epoch("2026-10-22T09:29:24.458052"), Journal.epoch("2026-10-22T09:29:24Z"), "no zone is UTC")
  eq(Journal.epoch("2000-03-01T00:00:00Z"), 951868800)
  eq(Journal.epoch("2026-10-22"), Journal.epoch("2026-10-22T00:00:00Z"))
  eq(Journal.epoch("soon"), nil)
  eq(Journal.epoch(nil), nil)
end)

check("the day on the device's clock: today, yesterday, the date, the year when it is another", function()
  -- times near midday (UTC) fall on the same day in any zone the CI or a reader is in
  local now = Journal.epoch("2026-10-22T12:00:00Z")
  local function at(days_ago) return os.date("!%Y-%m-%dT12:00:00Z", now - days_ago * 86400) end
  eq(Journal.dayText(at(0), now), "Today")
  eq(Journal.dayText(at(1), now), "Yesterday")
  local t = os.date("*t", now - 5 * 86400)
  local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
  eq(Journal.dayText(at(5), now), months[t.month] .. " " .. t.day)
  local old = os.date("*t", Journal.epoch("2025-03-04T12:00:00Z"))
  eq(Journal.dayText("2025-03-04T12:00:00Z", now), months[old.month] .. " " .. old.day .. ", " .. old.year)
  eq(Journal.dayText("later", now), nil)
end)

print("\n== a row ==")

check("a row is the book, what happened, and the authors with the day", function()
  local now = Journal.epoch("2026-10-22T18:00:00Z")
  local entries = Journal.parse({ reading_journals = rows() }, 20).entries
  local row = Journal.row(entries[1], now)
  eq(row.title, "Dune")
  eq(row.what, "Updated progress from 13% to 56%")
  has(row.detail, "Frank Herbert" .. DOT)
  eq(row.cover_url, "https://example.test/dune.jpg")
  eq(row.open, "book", "an event opens the book")
end)

check("a note, quote or review says which it is, and opens its whole text", function()
  local e = byKey(Journal.parse({ reading_journals = rows() }, 20).entries)
  local quote = Journal.row(e["quote:10"])
  eq(quote.what, "Quote: " .. LQ .. "Fear is the mind-killer." .. RQ)
  eq(quote.open, "full")
  eq(Journal.row(e["note:9"]).what, "Note: " .. e["note:9"].excerpt)
  local review = Journal.row(e["reviewed:7"])
  eq(review.what, Journal.SPOILER_LABEL, "a review that gives away the story shows no text in the list")
  eq(review.open, "full")
  local plain = Journal.row({ kind = "review", text = "Good", excerpt = "Good", title = "Kindred" })
  eq(plain.what, "Review: Good")
end)

check("an entry with no book opens nothing; one with no day says only who wrote it", function()
  local row = Journal.row({ kind = "event", action = "Finished reading", title = "A book" })
  eq(row.open, nil)
  eq(row.detail, "")
end)

check("the heading over the whole text", function()
  local e = byKey(Journal.parse({ reading_journals = rows() }, 20).entries)
  eq(Journal.heading(e["quote:10"]), "Quote" .. DOT .. "Dune" .. DOT .. "p. 12")
  eq(Journal.heading(e["reviewed:7"]), "Review" .. DOT .. "Kindred")
end)

print("\n== pages ==")

check("a later page adds what is new, once", function()
  local first = Journal.parse({ reading_journals = { rows()[1], rows()[2] } }, 2).entries
  local all, added = Journal.append(first, Journal.parse({ reading_journals = rows() }, 20).entries)
  eq(#all, 9)
  eq(added, 7)
  local _, again = Journal.append(all, Journal.parse({ reading_journals = rows() }, 20).entries)
  eq(again, 0)
  local none, zero = Journal.append({ { key = "a" } }, nil)
  eq(#none, 1); eq(zero, 0)
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
  local waiting = Journal.waiting(journalOps(), reviewOps(), 1)
  eq(#waiting, 4, "count")
  eq(waiting[1].key, "waiting:100-5")
  eq(waiting[2].key, "waiting:100-3", "an entry with no user is yours")
  eq(waiting[3].key, "waiting:100-1")
  eq(waiting[4].key, "waiting:review:900")
  for _, e in ipairs(waiting) do eq(e.waiting, true, "waiting") end
end)

check("a waiting entry has what a row and the full text need", function()
  local waiting = Journal.waiting(journalOps(), reviewOps(), 1)
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

check("a waiting row says so instead of a day", function()
  local waiting = Journal.waiting(journalOps(), reviewOps(), 1)
  local row = Journal.row(waiting[3])
  eq(row.detail, Journal.WAITING)
  eq(row.what, "Note: First note")
  eq(row.open, "full")
  eq(Journal.row(waiting[4]).what, Journal.SPOILER_LABEL, "a waiting review still hides its spoilers")
  eq(Journal.heading(waiting[2]), "Quote" .. DOT .. "Kindred" .. DOT .. "p. 12")
end)

check("nothing waiting, or no queues, is an empty list", function()
  eq(#Journal.waiting(nil, nil, 1), 0)
  eq(#Journal.waiting({}, {}, 1), 0)
end)

-- Hardcover's entries as the tab holds them
local function held()
  return {
    { key = "note:4001", id = 4001, kind = "note", user_id = 1, book_id = 5, title = "Dune", authors = "Frank Herbert",
      cover_url = "https://example.test/dune.jpg", text = "Old words", excerpt = "Old words", at = "2026-10-20T10:00:00Z" },
    { key = "quote:4002", id = 4002, kind = "quote", user_id = 1, book_id = 5, title = "Dune", text = "A quote", excerpt = "A quote", at = "2026-10-19T10:00:00Z" },
    { key = "reviewed:4003", id = 4003, kind = "review", user_book_id = 900, user_id = 1, book_id = 5, title = "Dune", text = "Fine", excerpt = "Fine", at = "2026-10-18T10:00:00Z" },
    { key = "reviewed:4004", id = 4004, kind = "review", user_book_id = 901, user_id = 1, book_id = 6, title = "Kindred", text = "Great", excerpt = "Great", at = "2026-10-17T10:00:00Z" },
    { key = "user_book_read_finished:4005", id = 4005, kind = "event", action = "Finished reading", user_id = 1, book_id = 5, title = "Dune", at = "2026-10-16T10:00:00Z" },
    { key = "reviewed:4006", id = 4006, kind = "review", user_book_id = 900, user_id = 1, book_id = 5, title = "Dune", text = "Fine", excerpt = "Fine", at = "2026-10-15T10:00:00Z" },
  }
end

check("with nothing waiting, the tab shows what Hardcover has", function()
  local all = Journal.withPending(held(), {}, {}, 1)
  eq(#all, 6)
  eq(all[1].key, "note:4001")
  eq(all[1].waiting, nil)
  eq(#Journal.withPending(nil, nil, nil, 1), 0)
end)

check("new writing goes above what Hardcover has, with the book's cover and authors where the list has them", function()
  local all = Journal.withPending(held(), journalOps(), {}, 1)
  eq(#all, 9)
  eq(all[1].key, "waiting:100-5")
  eq(all[1].queue_id, "100-5")
  eq(all[1].cover_url, nil, "a book the list does not hold")
  eq(all[3].key, "waiting:100-1")
  eq(all[3].authors, "Frank Herbert")
  eq(all[3].cover_url, "https://example.test/dune.jpg")
  eq(all[4].key, "note:4001")
end)

check("an edit waiting to send shows its new text in place; a delete waiting to send hides the entry", function()
  local ops = {
    { id = "1-1", seq = 1, action = "update", user_id = 1, journal_id = 4001, event = "note", text = "New words" },
    { id = "1-2", seq = 2, action = "delete", user_id = 1, journal_id = 4002, event = "quote" },
    { id = "1-3", seq = 3, action = "delete", user_id = 2, journal_id = 4001, event = "note" },
  }
  local h = held()
  local all = Journal.withPending(h, ops, {}, 1)
  eq(#all, 5, "the deleted quote is left out, and another account's delete is not yours")
  eq(all[1].key, "note:4001", "an edit stays where the entry is")
  eq(all[1].text, "New words")
  eq(all[1].excerpt, "New words")
  eq(all[1].waiting, true)
  eq(all[1].id, 4001)
  eq(Journal.row(all[1]).detail, "Frank Herbert" .. DOT .. Journal.WAITING)
  eq(all[2].key, "reviewed:4003")
  eq(h[1].text, "Old words", "the held entry itself (what is saved) is not changed")
  eq(h[1].waiting, nil)
end)

check("a review changed shows on every entry of its book; one being removed leaves them saying you reviewed it", function()
  local reviews = {
    { user_book_id = 900, text = "Better now", spoilers = true, title = "Dune" },
    { user_book_id = 901, text = "", spoilers = false, title = "Kindred" },
    { user_book_id = 902, text = "A new one", spoilers = false, title = "Emma" },
  }
  local all = Journal.withPending(held(), {}, reviews, 1)
  eq(#all, 7)
  eq(all[1].key, "waiting:review:902", "a review Hardcover does not list yet is new writing")
  eq(all[1].user_book_id, 902)
  local e = byKey(all)
  for _, key in ipairs({ "reviewed:4003", "reviewed:4006" }) do
    eq(e[key].text, "Better now", key); eq(e[key].spoilers, true, key); eq(e[key].waiting, true, key)
  end
  local removed = e["reviewed:4004"]
  eq(removed.text, nil); eq(removed.excerpt, nil); eq(removed.waiting, true)
  eq(Journal.row(removed).what, "Reviewed")
  eq(Journal.row(removed).detail, Journal.WAITING)
end)

check("the id an edit is sent for, from the entry or from its key", function()
  eq(Journal.idOf({ id = 7, key = "note:9" }), 7)
  eq(Journal.idOf({ key = "quote:4002" }), 4002)
  eq(Journal.idOf({ key = "user_book_read_started:12" }), 12)
  eq(Journal.idOf({ key = "waiting:1-2" }), nil)
  eq(Journal.idOf(nil), nil)
end)

check("epoch reads every zone form", function()
  local base = Journal.epoch("2026-10-21T19:00:00Z")
  eq(Journal.epoch("2026-10-21T21:00:00+02"), base)
  eq(Journal.epoch("2026-10-21T21:00:00+02:00"), base)
  eq(Journal.epoch("2026-10-21T21:00:00+0200"), base)
  eq(Journal.epoch("2026-10-21T21:00:00.123+02:00"), base)
  eq(Journal.epoch("2026-10-21T14:00:00-05"), base)
  eq(Journal.epoch("2026-10-21T14:30:00-04:30"), base)
  eq(Journal.epoch("2026-10-21T19:00:00"), base)
  eq(Journal.epoch("2026-10-21T19:00:00.5Z"), base)
end)

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
