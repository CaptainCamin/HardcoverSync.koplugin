-- Your journal on Hardcover, as the Library's Journal tab shows it: everything you did with your
-- books, newest first.
--
-- Hardcover writes a journal entry (`reading_journals`) each time you start or finish a book, move
-- your progress on, rate it, change its status, put it on a list, and for each note, quote and
-- review. One request brings a page of yours; this module turns the answer into rows. What each
-- kind carries is in docs/hardcover-journal-api.md.
--
-- Pure: no widgets and no KOReader, so it runs under stock Lua in the harness. The API call
-- (HardcoverApi:getJournal) only sends Journal.query and hands the answer to Journal.parse.
--
-- Paging is by offset: the next page skips the rows already asked for. Hardcover gives no total, so
-- a page that comes back full is taken to have more behind it. An entry written meanwhile moves the
-- rest down by one, so the next page can start with one already held: Journal.append drops it.

local Reviews = require("hardcover/lib/reviews")

local Journal = {}

Journal.PAGE_SIZE = 20

local function int(value)
  value = tonumber(value)
  if value and value == math.floor(value) and value >= 0 then return string.format("%d", value) end
  return nil
end

local function nonBlank(text)
  return type(text) == "string" and text:match("%S") and text or nil
end

--
-- The request for a page. opts: { me_id, offset (rows already asked for), limit, book_id (only
-- this book's entries, for the reader panel's Journal) }. Returns the
-- query text, or nil without a user. Numbers go into the text itself: the API is stricter about
-- declared variable types than about literals. Your review of the book comes with each row
-- (`reviews`), so a "reviewed" entry shows the review as it is now, not as first written.
--
function Journal.query(opts)
  opts = opts or {}
  local me = int(opts.me_id)
  if not me then return nil end
  local limit = int(math.floor(tonumber(opts.limit) or Journal.PAGE_SIZE)) or "20"
  local offset = int(math.floor(tonumber(opts.offset) or 0)) or "0"
  local book = int(opts.book_id)
  local of_book = book and string.format(", book_id: { _eq: %s }", book) or ""
  return string.format([[
query {
  reading_journals(
    where: { user_id: { _eq: %s }%s }
    order_by: [{ action_at: desc }, { id: desc }]
    offset: %s
    limit: %s
  ) {
    id event entry metadata action_at user_id book_id
    book {
      id title cached_image contributions: cached_contributors
      reviews: user_books(where: { user_id: { _eq: %s }, has_review: { _eq: true } }, limit: 1) {
        id review_raw review_has_spoilers
      }
    }
  }
}]], me, of_book, offset, limit, me)
end

-- ---------------------------------------------------------------------------
-- What each kind of entry says happened
-- ---------------------------------------------------------------------------

-- U+201C and U+201D as bytes, for the CI Lua
local OPEN_QUOTE, CLOSE_QUOTE = "\226\128\156", "\226\128\157"
local DOT = " \194\183 "

Journal.SPOILER_LABEL = "Review that gives away the story"
-- said instead of the day by an entry that is still on the device
Journal.WAITING = "Waiting to send"

local function percent(value)
  value = tonumber(value)
  if not value then return nil end
  return string.format("%d%%", math.floor(value + 0.5))
end

local function progressText(meta)
  local now, was = percent(meta.progress), percent(meta.progress_was)
  if now and was then return string.format("Updated progress from %s to %s", was, now) end
  if now then return "Updated progress to " .. now end
  local page = int(meta.progress_pages)
  if page then return "Updated progress to page " .. page end
  return "Updated progress"
end

local function ratingText(meta)
  local rating = tonumber(meta.rating)
  if not rating or rating <= 0 then return "Changed your rating" end
  local value = rating % 1 == 0 and string.format("%d", rating) or string.format("%.1f", rating)
  return "Rated " .. value .. " out of 5"
end

local function named(prefix, name, fallback)
  name = nonBlank(name)
  return name and (prefix .. OPEN_QUOTE .. name .. CLOSE_QUOTE) or fallback
end

local STATUS_TEXT = {
  status_want_to_read = "Marked as want to read",
  status_currently_reading = "Marked as currently reading",
  status_read = "Marked as read",
  status_paused = "Marked as paused",
  status_stopped = "Marked as did not finish",
}

-- The line that says what happened, for an entry with no text of its own; nil for a kind the tab
-- does not show (a referral is about another reader, not a book you read).
local function actionText(event, meta)
  if event == "progress_updated" then return progressText(meta) end
  if event == "user_book_read_started" then return "Started reading" end
  if event == "user_book_read_finished" then return "Finished reading" end
  if event == "rated" then return ratingText(meta) end
  if event == "list_book" then return named("Added to the list ", meta.list_name, "Added to a list") end
  if event == "prompt_book" then return named("Added to the prompt ", meta.prompt, "Added to a prompt") end
  if STATUS_TEXT[event] then return STATUS_TEXT[event] end
  if type(event) == "string" and event:find("^status_") then return "Changed the status" end
  return nil
end

-- ---------------------------------------------------------------------------
-- The answer
-- ---------------------------------------------------------------------------

-- The book's authors, as the shelves list them: those credited as author, else everyone credited.
local function authorsOf(book)
  local all, authors, seen = {}, {}, {}
  for _, c in ipairs(type(book.contributions) == "table" and book.contributions or {}) do
    local name = type(c) == "table" and type(c.author) == "table" and nonBlank(c.author.name)
    if name and not seen[name] then
      seen[name] = true
      all[#all + 1] = name
      if c.contribution == nil or c.contribution == "Author" then authors[#authors + 1] = name end
    end
  end
  local names = #authors > 0 and authors or all
  return #names > 0 and table.concat(names, ", ") or nil
end

local function coverOf(book)
  local image = type(book.cached_image) == "table" and book.cached_image
  return image and nonBlank(image.url) or nil
end

local function pageOf(metadata)
  local position = type(metadata) == "table" and metadata.position
  if type(position) ~= "table" or position.type ~= "pages" then return nil end
  return tonumber(position.value)
end

-- One entry from one row, or nil for a row the tab does not show.
local function entryOf(row)
  if type(row) ~= "table" or row.id == nil or type(row.action_at) ~= "string" then return nil end
  local event = row.event
  local meta = type(row.metadata) == "table" and row.metadata or {}
  local book = type(row.book) == "table" and row.book or {}
  local out = {
    key = tostring(event) .. ":" .. tostring(row.id),
    id = tonumber(row.id),
    event = event,
    at = row.action_at,
    user_id = tonumber(row.user_id),
    book_id = tonumber(book.id) or tonumber(row.book_id),
    title = nonBlank(book.title) or "A book",
    authors = authorsOf(book),
    cover_url = coverOf(book),
  }
  if event == "note" or event == "quote" then
    local body = nonBlank(row.entry)
    if not body then return nil end
    out.kind = event
    out.text = body
    out.excerpt, out.truncated = Reviews.excerpt(body)
    out.page = pageOf(meta)
  elseif event == "reviewed" then
    out.kind = "review"
    local current = type(book.reviews) == "table" and book.reviews[1]
    local review = type(current) == "table" and Reviews.normalize(current)
    out.user_book_id = review and tonumber(review.id) or tonumber(meta.user_book_id)
    if review and review.text ~= "" then
      out.text, out.excerpt, out.truncated = review.text, review.excerpt, review.truncated
      out.spoilers = review.has_spoilers
    end
  else
    out.kind = "event"
    out.action = actionText(event, meta)
    if not out.action then return nil end
  end
  return out
end

--
-- A page of the answer: { entries, count (the rows Hardcover sent, which is how far the next page
-- starts on), more (a full page: there may be more behind it) }. Rows the tab does not show are
-- left out of entries but counted.
--
function Journal.parse(data, limit)
  local rows = type(data) == "table" and type(data.reading_journals) == "table" and data.reading_journals or {}
  local requested = tonumber(limit) or Journal.PAGE_SIZE
  local entries = {}
  for _, row in ipairs(rows) do
    local entry = entryOf(row)
    if entry then entries[#entries + 1] = entry end
  end
  return { entries = entries, count = #rows, more = #rows >= requested and #rows > 0 }
end

-- ---------------------------------------------------------------------------
-- When it happened
-- ---------------------------------------------------------------------------

-- Days since 1970-01-01 of a calendar date (Howard Hinnant's days_from_civil), so a time can be
-- read without the device's time zone getting in the way.
local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- The moment an ISO time ("2026-10-21T21:00:00+00:00", "...Z", or with no zone: UTC) stands
-- for, in seconds since 1970, or nil.
function Journal.epoch(at)
  if type(at) ~= "string" then return nil end
  local y, mo, d, rest = at:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
  if not y then return nil end
  local h, mi, s = rest:match("^[T ](%d%d):(%d%d):?(%d*)")
  local seconds = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + (tonumber(h) or 0) * 3600 + (tonumber(mi) or 0) * 60 + (tonumber(s) or 0)
  local sign, zh, zm = rest:match("([%+%-])(%d%d):?(%d%d)$")
  if sign and h then
    local shift = tonumber(zh) * 3600 + tonumber(zm) * 60
    seconds = sign == "+" and seconds - shift or seconds + shift
  end
  return seconds
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- "Today", "Yesterday", "Oct 21", or "Oct 21, 2025" in another year, on the device's clock; nil
-- for a time that cannot be read. `now` (seconds) is for the harness.
function Journal.dayText(at, now)
  local epoch = Journal.epoch(at)
  if not epoch then return nil end
  local day = os.date("*t", epoch)
  local today = os.date("*t", now or os.time())
  local function serial(t) return daysFromCivil(t.year, t.month, t.day) end
  local diff = serial(today) - serial(day)
  if diff == 0 then return "Today" end
  if diff == 1 then return "Yesterday" end
  local text = string.format("%s %d", MONTHS[day.month], day.day)
  if day.year ~= today.year then text = text .. ", " .. day.year end
  return text
end

-- ---------------------------------------------------------------------------
-- What the tab shows for an entry
-- ---------------------------------------------------------------------------

local KIND_WORD = { note = "Note", quote = "Quote", review = "Review" }

local function join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local part = select(i, ...)
    if part and part ~= "" then parts[#parts + 1] = part end
  end
  return table.concat(parts, DOT)
end

--
-- One row: { title (the book, in bold), what (what happened, or the text written), detail (the
-- authors and the day), cover_url, open }. `open` is "full" (the whole note, quote or review),
-- "book" (the book's details) or nil (nothing to open). A note, quote or review says so in words.
--
function Journal.row(entry, now)
  local what
  if entry.kind == "note" then
    what = "Note: " .. (entry.excerpt or entry.text or "")
  elseif entry.kind == "quote" then
    what = "Quote: " .. OPEN_QUOTE .. (entry.excerpt or entry.text or "") .. CLOSE_QUOTE
  elseif entry.kind == "review" then
    if not entry.text then
      what = "Reviewed"
    elseif entry.spoilers then
      what = Journal.SPOILER_LABEL
    else
      what = "Review: " .. (entry.excerpt or entry.text)
    end
  else
    what = entry.action or ""
  end
  local open
  if entry.text and entry.kind ~= "event" then
    open = "full"
  elseif entry.book_id then
    open = "book"
  end
  return {
    title = entry.title or "A book",
    what = what,
    detail = join(entry.authors, entry.waiting and Journal.WAITING or Journal.dayText(entry.at, now)),
    cover_url = entry.cover_url,
    open = open,
  }
end

-- The heading over an entry's whole text: "Quote · Dune · p. 12".
function Journal.heading(entry)
  return join(KIND_WORD[entry.kind], entry.title, entry.page and ("p. " .. entry.page) or nil)
end

-- ---------------------------------------------------------------------------
-- What this device has not sent yet
-- ---------------------------------------------------------------------------

local function mine(op, user_id)
  return op.user_id == nil or tonumber(op.user_id) == tonumber(user_id)
end

-- The id an entry's edit is sent for (a copy saved before entries carried it has it in its key).
function Journal.idOf(entry)
  if type(entry) ~= "table" then return nil end
  return tonumber(entry.id) or tonumber(tostring(entry.key or ""):match("^[%a_]+:(%d+)$"))
end

-- What a change waiting to send is filed under: a note or quote by its entry, a review by the
-- library record it belongs to (every "reviewed" entry of the book shows the one review).
local function changeKey(entry)
  if entry.kind == "review" then
    return entry.book_id and ("review:book:" .. tostring(entry.book_id)) or ("review:" .. tostring(entry.user_book_id))
  end
  return entry.key
end

--
-- What you wrote that is still on the device and Hardcover does not have yet: new notes and quotes
-- from the journal queue (JournalQueue:list, only `user_id`'s and those with no user) and reviews
-- from the review queue (ReviewQueue:list). Notes and quotes newest first (the queue lists them
-- oldest first), then reviews, which keep no time. Each says it is waiting instead of a day. A
-- review being removed (empty text) is left out: there is nothing to show. `queue_id` (a note's or
-- quote's id in the queue) and `user_book_id` (a review's) are how an edit finds it again.
--
function Journal.waiting(journal_ops, review_ops, user_id)
  local out = {}
  journal_ops = journal_ops or {}
  for i = #journal_ops, 1, -1 do
    local op = journal_ops[i]
    local body = nonBlank(op.text)
    if op.action == nil and mine(op, user_id) and body and (op.event == "note" or op.event == "quote") then
      local excerpt, truncated = Reviews.excerpt(body)
      out[#out + 1] = {
        key = "waiting:" .. tostring(op.id), kind = op.event, waiting = true, queue_id = op.id,
        title = op.title or "A book", book_id = tonumber(op.book_id),
        text = body, excerpt = excerpt, truncated = truncated, page = tonumber(op.page),
      }
    end
  end
  for _, op in ipairs(review_ops or {}) do
    local body = nonBlank(op.text)
    if body then
      local excerpt, truncated = Reviews.excerpt(body)
      out[#out + 1] = {
        key = "waiting:" .. changeKey { kind = "review", book_id = op.book_id, user_book_id = op.user_book_id },
        kind = "review", waiting = true, book_id = tonumber(op.book_id), user_id = op.user_id,
        user_book_id = tonumber(op.user_book_id) or op.user_book_id,
        title = op.title or "A book",
        text = body, excerpt = excerpt, truncated = truncated, spoilers = op.spoilers == true,
      }
    end
  end
  return out
end

local function copyOf(entry)
  local copy = {}
  for k, v in pairs(entry) do copy[k] = v end
  return copy
end

--
-- What the Journal tab shows: Hardcover's entries as changed on this device. A note or quote edited
-- and not sent yet shows its new text where it is, saying it is waiting; one being deleted is left
-- out. A review changed shows its new text on every "reviewed" entry of the book; one being removed
-- leaves them saying only that you reviewed it, as Hardcover will. Above them, what Hardcover does
-- not have yet (Journal.waiting), with the cover and authors of the book where the list has them.
-- A review waiting for a book whose review is listed is that review edited, not a new one.
--
function Journal.withPending(entries, journal_ops, review_ops, user_id)
  local changes = {}
  for _, op in ipairs(journal_ops or {}) do
    if op.action and mine(op, user_id) then
      changes[tostring(op.event) .. ":" .. tostring(op.journal_id)] = op.action == "update" and { text = op.text } or false
    end
  end
  for _, op in ipairs(review_ops or {}) do
    local body = nonBlank(op.text)
    local key = changeKey { kind = "review", book_id = op.book_id, user_book_id = op.user_book_id }
    changes[key] = body and { text = body, spoilers = op.spoilers == true, user_book_id = op.user_book_id } or false
  end

  local held, used, books = {}, {}, {}
  for _, e in ipairs(entries or {}) do
    local key = changeKey(e)
    -- Older queued reviews have only the library-record ID, while fetched entries also have book_id.
    if changes[key] == nil and e.kind == "review" then key = "review:" .. tostring(e.user_book_id) end
    local change = changes[key]
    if change ~= nil then used[key] = true end
    if e.book_id and not books[e.book_id] then books[e.book_id] = e end
    if change and nonBlank(change.text) then
      local copy = copyOf(e)
      copy.text = change.text
      copy.excerpt, copy.truncated = Reviews.excerpt(change.text)
      copy.waiting = true
      if e.kind == "review" then
        copy.spoilers = change.spoilers
        -- A draft belongs to its queued record, not a historical review's possibly deleted one.
        copy.user_book_id = change.user_book_id
      end
      held[#held + 1] = copy
    elseif change == false and e.kind == "review" then
      local copy = copyOf(e)
      copy.text, copy.excerpt, copy.truncated, copy.spoilers = nil, nil, nil, nil
      copy.waiting = true
      held[#held + 1] = copy
    elseif change == nil then
      held[#held + 1] = e
    end
  end

  local new_reviews = {}
  for _, op in ipairs(review_ops or {}) do
    local key = changeKey { kind = "review", book_id = op.book_id, user_book_id = op.user_book_id }
    if not used[key] then new_reviews[#new_reviews + 1] = op end
  end
  local out = Journal.waiting(journal_ops, new_reviews, user_id)
  for _, e in ipairs(out) do
    local known = e.book_id and books[e.book_id]
    if known then
      e.authors, e.cover_url = known.authors, known.cover_url
    end
  end
  for _, e in ipairs(held) do out[#out + 1] = e end
  return out
end

-- `held` with the entries of a later page added at the end, keeping each entry once.
function Journal.append(held, page)
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

return Journal
