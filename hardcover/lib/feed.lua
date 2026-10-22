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
-- before (an entry's `at`), limit, mine (only your own) }. Returns the query text, or nil when
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
  local parts = {}

  if kinds.status then
    parts[#parts + 1] = string.format([[
      activities(
        where: { user_id: { _in: %s }, event: { _eq: "UserBookActivity" }%s }
        order_by: [{ created_at: desc }, { id: desc }]
        limit: %d
      ) { id event user_id created_at data %s }]], list, when("created_at", before), limit, person)
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
        where: { event: { _in: [%s] }, %s%s }
        order_by: [{ created_at: desc }, { id: desc }]
        limit: %d
      ) { id event entry user_id created_at metadata %s }]],
      table.concat(events, ", "), who, when("created_at", before), limit, person)
  end

  if kinds.review then
    parts[#parts + 1] = string.format([[
      reviews: user_books(
        where: { user_id: { _in: %s }, has_review: { _eq: true }, reviewed_at: { _is_null: false%s } }
        order_by: [{ reviewed_at: desc }, { id: desc }]
        limit: %d
      ) { id user_id rating review_raw review_has_spoilers reviewed_at %s }]],
      list, when("reviewed_at", before and before:sub(1, 10), true), limit, person)
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
