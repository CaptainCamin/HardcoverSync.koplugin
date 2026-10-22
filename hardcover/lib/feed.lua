-- The activity feed: what you and the readers you follow have lately done on Hardcover.
--
-- Hardcover has no single feed to ask for. Status changes live in `activities`, notes and quotes
-- in `reading_journals` and reviews in `user_books` (see docs/hardcover-journal-api.md), so one
-- request asks all three for the newest rows, and this module turns the answer into one list.
--
-- Pure: no widgets and no KOReader, so it runs under stock Lua in the harness. The API call
-- (HardcoverApi:getFeed) only sends Feed.query and hands the answer to Feed.parse.
--
-- Paging is by time. A page is the newest PAGE_SIZE entries of the three sources together; the
-- next page asks each source for rows no newer than the oldest entry shown (`before`). Rows
-- that share that exact time come back again and Feed.append drops the ones already held.

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Reviews = require("hardcover/lib/reviews")

local Feed = {}

Feed.PAGE_SIZE = 20

-- most readers asked about in one request; a reader followed beyond this is left out
Feed.MAX_READERS = 200

-- what the feed can show, in the order of the filter chips
Feed.KINDS = { "status", "note", "quote", "review" }

local function isKind(kind)
  for _, k in ipairs(Feed.KINDS) do
    if k == kind then return true end
  end
  return false
end

-- A set of kinds as a table keyed by kind; nothing asked for means all of them.
local function wanted(kinds)
  local out, any = {}, false
  for _, kind in ipairs(type(kinds) == "table" and kinds or {}) do
    if isKind(kind) then out[kind], any = true, true end
  end
  if not any then
    for _, kind in ipairs(Feed.KINDS) do out[kind] = true end
  end
  return out
end

local function int(value)
  value = tonumber(value)
  if value and value == math.floor(value) then return string.format("%d", value) end
  return nil
end

-- Reader ids as a GraphQL list, whole numbers only, no repeats, at most MAX_READERS.
local function idList(ids)
  local seen, out = {}, {}
  for _, id in ipairs(ids or {}) do
    local text = int(id)
    if text and not seen[text] and #out < Feed.MAX_READERS then
      seen[text] = true
      out[#out + 1] = text
    end
  end
  return "[" .. table.concat(out, ", ") .. "]", #out
end

-- An ISO timestamp for a query. Anything else is dropped, so nothing typed or received can
-- reach the query text.
local function stamp(value)
  if type(value) ~= "string" then return nil end
  return value:match("^%d%d%d%d%-%d%d%-%d%d[T ]?[%d:%.]*[%+%-Z%d:]*$") and value or nil
end

--
-- The one request for a page. opts: { me_id, user_ids (the readers followed), kinds (see KINDS),
-- before (an entry's `at`), limit, mine (only your own), book_id (only this book) }. Returns the query text, or nil when
-- there is nobody to ask about. Numbers and the time go into the text itself: the id columns
-- are bigint and the API is stricter about declared variable types than about literals.
--
function Feed.query(opts)
  opts = opts or {}
  local me = int(opts.me_id)
  local readers = {}
  if me then readers[1] = me end
  if not opts.mine then
    for _, id in ipairs(opts.user_ids or {}) do readers[#readers + 1] = id end
  end
  local list, count = idList(readers)
  if count == 0 then return nil end
  local limit = math.floor(tonumber(opts.limit) or Feed.PAGE_SIZE)
  local before = stamp(opts.before)
  local kinds = wanted(opts.kinds)

  -- `inside` puts the bound in the column's own condition (a key may not appear twice in a where)
  local function when(column, value, inside)
    if not value then return "" end
    if inside then return string.format(", _lte: \"%s\"", value) end
    return string.format(", %s: { _lte: \"%s\" }", column, value)
  end

  local person = "user { username name } book { id title }"
  -- one book's entries only: the same condition in each source
  local book = int(opts.book_id)
  local of_book = book and string.format(", book_id: { _eq: %s }", book) or ""
  local parts = {}

  if kinds.status then
    parts[#parts + 1] = string.format([[
      activities(
        where: { user_id: { _in: %s }, event: { _eq: "UserBookActivity" }%s%s }
        order_by: [{ created_at: desc }, { id: desc }]
        limit: %d
      ) { id event user_id created_at data %s }]], list, when("created_at", before), of_book, limit, person)
  end

  if kinds.note or kinds.quote then
    local events = {}
    if kinds.note then events[#events + 1] = "\"note\"" end
    if kinds.quote then events[#events + 1] = "\"quote\"" end
    -- yours whatever the privacy; the others' only where they let followers see them
    local who = string.format(
      "_or: [{ user_id: { _eq: %s } }, { user_id: { _in: %s }, privacy_setting_id: { _in: [%d, %d] } }]",
      me or "0", list, HARDCOVER.PRIVACY.PUBLIC, HARDCOVER.PRIVACY.FOLLOWS)
    parts[#parts + 1] = string.format([[
      journals: reading_journals(
        where: { event: { _in: [%s] }, %s%s%s }
        order_by: [{ created_at: desc }, { id: desc }]
        limit: %d
      ) { id event entry user_id created_at metadata %s }]],
      table.concat(events, ", "), who, when("created_at", before), of_book, limit, person)
  end

  if kinds.review then
    parts[#parts + 1] = string.format([[
      reviews: user_books(
        where: { user_id: { _in: %s }, has_review: { _eq: true }, reviewed_at: { _is_null: false%s }%s }
        order_by: [{ reviewed_at: desc }, { id: desc }]
        limit: %d
      ) { id user_id rating review_raw review_has_spoilers reviewed_at %s }]],
      list, when("reviewed_at", before and before:sub(1, 10), true), of_book, limit, person)
  end

  return "query {\n" .. table.concat(parts, "\n") .. "\n}"
end

local function nameOf(row)
  return Reviews.reviewer({ user = row.user })
end

local function titleOf(row)
  local book = type(row.book) == "table" and row.book or {}
  if type(book.title) == "string" and book.title ~= "" then return book.title end
  return nil
end

-- "Wants to read", "Reading, 40%", "Finished" and so on, from a UserBookActivity's data.
local STATUS_TEXT = {
  [HARDCOVER.STATUS.TO_READ] = "Wants to read",
  [HARDCOVER.STATUS.READING] = "Reading",
  [HARDCOVER.STATUS.FINISHED] = "Finished",
  [HARDCOVER.STATUS.PAUSED] = "Paused",
  [HARDCOVER.STATUS.DNF] = "Did not finish",
}

function Feed.statusText(data)
  local user_book = type(data) == "table" and data.userBook
  if type(user_book) ~= "table" then return nil end
  local text = STATUS_TEXT[tonumber(user_book.statusId)]
  local progress = tonumber(user_book.progress)
  if text and progress and progress > 0 and progress < 100 and tonumber(user_book.statusId) == HARDCOVER.STATUS.READING then
    text = string.format("%s, %d%%", text, math.floor(progress + 0.5))
  end
  local rating = Reviews.ratingText(user_book.rating)
  if rating then
    text = text and (text .. ", rated " .. rating) or ("Rated " .. rating)
  end
  return text
end

-- The title of the book an activity is about: the book row, else the edition in its data.
local function activityTitle(row)
  local title = titleOf(row)
  if title then return title end
  local user_book = type(row.data) == "table" and row.data.userBook
  local edition = type(user_book) == "table" and user_book.edition
  if type(edition) == "table" and type(edition.title) == "string" and edition.title ~= "" then
    return edition.title
  end
  return nil
end

local function entry(kind, row, at, extra)
  local book = type(row.book) == "table" and row.book or {}
  local out = {
    key = kind .. ":" .. tostring(row.id),
    -- the journal entry's id, or the library record's for a review: what an edit is sent for
    id = tonumber(row.id),
    kind = kind,
    at = at,
    date = Reviews.dateText(at),
    user_id = tonumber(row.user_id),
    who = nameOf(row),
    book_id = tonumber(book.id),
    title = (kind == "status" and activityTitle(row) or titleOf(row)) or "A book",
  }
  for key, value in pairs(extra or {}) do out[key] = value end
  return out
end

local function pageOf(metadata)
  local position = type(metadata) == "table" and metadata.position
  if type(position) ~= "table" or position.type ~= "pages" then return nil end
  return tonumber(position.value)
end

-- Entries from the three lists of one answer, newest first and no more than `limit`.
-- Rows that are not what the feed shows (a list or goal activity, a journal row without text,
-- a review without a body) are skipped.
function Feed.parse(data, limit)
  data = type(data) == "table" and data or {}
  local all = {}
  local full = false
  local requested = tonumber(limit) or Feed.PAGE_SIZE

  for _, row in ipairs(data.activities or {}) do
    local text = Feed.statusText(row.data)
    if text and row.created_at then
      all[#all + 1] = entry("status", row, row.created_at, { text = text })
    end
  end

  for _, row in ipairs(data.journals or {}) do
    local kind = row.event
    local body = type(row.entry) == "string" and row.entry:match("%S") and row.entry or nil
    if (kind == "note" or kind == "quote") and body and row.created_at then
      local excerpt, truncated = Reviews.excerpt(body)
      all[#all + 1] = entry(kind, row, row.created_at, {
        text = body, excerpt = excerpt, truncated = truncated, page = pageOf(row.metadata),
      })
    end
  end

  for _, row in ipairs(data.reviews or {}) do
    local review = Reviews.normalize(row)
    if review and review.text ~= "" and row.reviewed_at then
      all[#all + 1] = entry("review", row, row.reviewed_at, {
        text = review.text, excerpt = review.excerpt, truncated = review.truncated,
        rating = review.rating, spoilers = review.has_spoilers,
      })
    end
  end

  -- a source that filled its page may have more behind it
  for _, key in ipairs({ "activities", "journals", "reviews" }) do
    if type(data[key]) == "table" and #data[key] >= requested then full = true end
  end

  table.sort(all, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.key > b.key
  end)
  while #all > requested do
    table.remove(all)
    full = true
  end
  return {
    entries = all,
    cursor = all[#all] and all[#all].at or nil,
    more = full and #all > 0,
  }
end

-- ---------------------------------------------------------------------------
-- What the Activity screen shows for an entry
-- ---------------------------------------------------------------------------

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- "Oct 21" from an entry's "2026-10-21", or nil
function Feed.shortDate(date)
  local month, day = tostring(date or ""):match("^%d%d%d%d%-(%d%d)%-(%d%d)$")
  month = tonumber(month)
  if not (month and MONTHS[month]) then return nil end
  return string.format("%s %d", MONTHS[month], tonumber(day))
end

local KIND_WORD = { note = "Note", quote = "Quote", review = "Review" }

-- U+201C and U+201D as bytes, for the CI Lua
local OPEN_QUOTE, CLOSE_QUOTE = "\226\128\156", "\226\128\157"

Feed.SPOILER_LABEL = "Review that gives away the story"
-- said instead of the date by an entry that is still on the device
Feed.WAITING = "Waiting to send"

--
-- One list row for an entry: { label (the line in bold), support (the small line), icon, action }.
-- `action` is "full" (a note, quote or review opens its whole text), "book" (a status change opens
-- the book) or nil (nothing to open). A kind is always said in words, never by the icon alone.
--
function Feed.row(entry)
  local when = entry.waiting and Feed.WAITING or Feed.shortDate(entry.date)
  local function join(...)
    local parts = {}
    for _, part in ipairs({ ... }) do
      if part and part ~= "" then parts[#parts + 1] = part end
    end
    return table.concat(parts, " \194\183 ")
  end

  if entry.kind == "status" then
    return {
      label = entry.title,
      support = join(when, entry.who, entry.text),
      icon = "book-open",
      action = entry.book_id and "book" or nil,
    }
  end

  local label = entry.excerpt or entry.text or ""
  if entry.kind == "quote" then
    label = OPEN_QUOTE .. label .. CLOSE_QUOTE
  elseif entry.kind == "review" then
    if entry.spoilers then
      label = Feed.SPOILER_LABEL
    elseif entry.rating then
      label = entry.rating .. "  " .. label
    end
  end
  return {
    label = label,
    support = join(when, entry.who, KIND_WORD[entry.kind], entry.title),
    icon = entry.kind == "quote" and "bookmark" or (entry.kind == "review" and "star-filled" or "edit"),
    action = "full",
  }
end

-- The heading over an entry's whole text: "Dana · Quote · Dune".
function Feed.heading(entry)
  local parts = { entry.who, KIND_WORD[entry.kind], entry.title }
  local out = {}
  for _, part in ipairs(parts) do
    if part and part ~= "" then out[#out + 1] = part end
  end
  if entry.page then out[#out + 1] = "p. " .. entry.page end
  return table.concat(out, " \194\183 ")
end

local function nonBlank(text)
  return type(text) == "string" and text:match("%S") and text or nil
end

local function mine(op, user_id)
  return op.user_id == nil or tonumber(op.user_id) == tonumber(user_id)
end

-- The id an entry's edit is sent for (a copy saved before entries carried it has it in its key).
function Feed.idOf(entry)
  if type(entry) ~= "table" then return nil end
  return tonumber(entry.id) or tonumber(tostring(entry.key or ""):match("^%a+:(%d+)$"))
end

--
-- What you wrote that is still on the device and Hardcover does not have yet: new notes and quotes
-- from the journal queue (JournalQueue:list, only `user_id`'s and those with no user) and reviews
-- from the review queue (ReviewQueue:list). Notes and quotes newest first (the queue lists them
-- oldest first), then reviews, which keep no time. Each says it is waiting instead of a date. A
-- review being removed (empty text) is left out: there is nothing to show. `queue_id` (a note's or
-- quote's id in the queue) and `user_book_id` (a review's) are how an edit finds it again.
--
function Feed.waiting(journal_ops, review_ops, user_id)
  local out = {}
  journal_ops = journal_ops or {}
  for i = #journal_ops, 1, -1 do
    local op = journal_ops[i]
    local body = nonBlank(op.text)
    if op.action == nil and mine(op, user_id) and body and (op.event == "note" or op.event == "quote") then
      local excerpt, truncated = Reviews.excerpt(body)
      out[#out + 1] = {
        key = "waiting:" .. tostring(op.id), kind = op.event, waiting = true, queue_id = op.id,
        who = "You", title = op.title or "A book", book_id = tonumber(op.book_id),
        text = body, excerpt = excerpt, truncated = truncated, page = tonumber(op.page),
      }
    end
  end
  for _, op in ipairs(review_ops or {}) do
    local body = nonBlank(op.text)
    if body then
      local excerpt, truncated = Reviews.excerpt(body)
      out[#out + 1] = {
        key = "waiting:review:" .. tostring(op.user_book_id), kind = "review", waiting = true,
        user_book_id = tonumber(op.user_book_id) or op.user_book_id,
        who = "You", title = op.title or "A book",
        text = body, excerpt = excerpt, truncated = truncated, spoilers = op.spoilers == true,
      }
    end
  end
  return out
end

--
-- What the Activity tab shows: Hardcover's entries as changed on this device. A note, quote or
-- review edited and not sent yet shows its new text where it is, saying it is waiting; one being
-- deleted (or a review being removed) is left out. Above them, what Hardcover does not have yet
-- (Feed.waiting). A review waiting for a book whose review is in the list is that review edited,
-- not a new one.
--
function Feed.withPending(entries, journal_ops, review_ops, user_id)
  local changes = {}
  for _, op in ipairs(journal_ops or {}) do
    if op.action and mine(op, user_id) then
      changes[tostring(op.event) .. ":" .. tostring(op.journal_id)] = op.action == "update" and { text = op.text } or false
    end
  end
  for _, op in ipairs(review_ops or {}) do
    local body = nonBlank(op.text)
    changes["review:" .. tostring(op.user_book_id)] = body and { text = body, spoilers = op.spoilers == true } or false
  end

  local held, used = {}, {}
  for _, e in ipairs(entries or {}) do
    local change = changes[e.key]
    if change ~= nil then used[e.key] = true end
    if change and nonBlank(change.text) then
      local copy = {}
      for k, v in pairs(e) do copy[k] = v end
      copy.text = change.text
      copy.excerpt, copy.truncated = Reviews.excerpt(change.text)
      copy.waiting = true
      if e.kind == "review" then copy.spoilers = change.spoilers end
      held[#held + 1] = copy
    elseif change == nil then
      held[#held + 1] = e
    end
  end

  local new_reviews = {}
  for _, op in ipairs(review_ops or {}) do
    if not used["review:" .. tostring(op.user_book_id)] then new_reviews[#new_reviews + 1] = op end
  end
  local out = Feed.waiting(journal_ops, new_reviews, user_id)
  for _, e in ipairs(held) do out[#out + 1] = e end
  return out
end

-- `held` with the entries of a newer page added at the end, keeping each entry once.
function Feed.append(held, page)
  local out, seen = {}, {}
  for _, e in ipairs(held or {}) do
    out[#out + 1] = e
    seen[e.key] = true
  end
  local added = 0
  for _, e in ipairs(page or {}) do
    if not seen[e.key] then
      seen[e.key] = true
      out[#out + 1] = e
      added = added + 1
    end
  end
  return out, added
end

return Feed
