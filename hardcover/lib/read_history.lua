-- Reading history, as the screens and the sync queue need it: the reads of one book, the words
-- for a date or a range, the summary line book details shows, and the small comparisons a read
-- edit is made of. Pure: no UI, no API, no storage.
--
-- Reads arrive in Hardcover's own order (oldest first, by id), which is the order
-- Book:currentRead expects. `normalize` is for display: dates as YYYY-MM-DD, numbers as numbers,
-- newest first.

local Book = require("hardcover/lib/book")

local ReadHistory = {}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local READ_FIELDS = { "id", "started_at", "finished_at", "finished_at_precision",
  "progress_pages", "edition_id" }
local EDITION_FIELDS = { "id", "pages", "edition_format", "reading_format_id", "audio_seconds" }

local function number(value)
  if value == nil or value == "" then return nil end
  return tonumber(value)
end

local function lastDay(year, month)
  if month == 2 then
    local leap = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
    return leap and 29 or 28
  end
  return (month == 4 or month == 6 or month == 9 or month == 11) and 30 or 31
end

-- The year, month and day of a date or timestamp, or nil when it is not one.
local function parts(value)
  if type(value) ~= "string" then return nil end
  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not year then return nil end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if month < 1 or month > 12 or day < 1 or day > lastDay(year, month) then return nil end
  return year, month, day
end

-- A date or timestamp as YYYY-MM-DD. A value that is not a date is left as it came, so a
-- surprising answer from the API is visible rather than silently changed.
local function dateString(value)
  if type(value) ~= "string" then return value end
  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not year then return value end
  return year .. "-" .. month .. "-" .. day
end

local function copyRead(read)
  local out = {}
  for key, value in pairs(read or {}) do out[key] = value end
  for _, key in ipairs(READ_FIELDS) do
    if out[key] ~= nil and key ~= "started_at" and key ~= "finished_at" then
      out[key] = number(out[key])
    end
  end
  out.started_at = dateString(out.started_at)
  out.finished_at = dateString(out.finished_at)
  if type(out.edition) == "table" then
    local edition = {}
    for key, value in pairs(out.edition) do edition[key] = value end
    for _, key in ipairs(EDITION_FIELDS) do
      if key ~= "edition_format" then edition[key] = number(edition[key]) end
    end
    out.edition = edition
  end
  return out
end

function ReadHistory.normalize(reads)
  local out = {}
  for _, read in ipairs(reads or {}) do out[#out + 1] = copyRead(read) end
  table.sort(out, function(a, b)
    local a_start, b_start = a.started_at or "", b.started_at or ""
    if a_start ~= b_start then return a_start > b_start end
    -- the same day (or no start at all): the later read (the higher id) is newer
    return (a.id or 0) > (b.id or 0)
  end)
  return out
end

-- `3 Nov 2026`, `Mar 2019` or `2019`; empty when there is no date. 1 is a day, 2 a month and
-- 3 a year, as Hardcover's finished_at_precision numbers them.
function ReadHistory.dateText(date, precision)
  local year, month, day = parts(date)
  if not year then return "" end
  precision = number(precision) or 1
  if precision >= 3 then return tostring(year) end
  if precision == 2 then return MONTHS[month] .. " " .. year end
  return day .. " " .. MONTHS[month] .. " " .. year
end

-- A year is left out of a date in the current year ("since 3 Nov").
function ReadHistory.shortDate(date, today)
  local year, month, day = parts(date)
  if not year then return "" end
  local this_year = number((today or os.date("%Y-%m-%d")):match("^(%d%d%d%d)"))
  local text = day .. " " .. MONTHS[month]
  if this_year and year ~= this_year then text = text .. " " .. year end
  return text
end

-- One read's dates: `14 – 20 Mar 2024`, `28 Feb – 3 Mar 2024`, `Started 3 Nov 2026`, or
-- `Finished 2019` when only the finish date is known.
function ReadHistory.rangeText(read)
  read = read or {}
  local start, finish = read.started_at, read.finished_at
  local precision = number(read.finished_at_precision) or 1
  if not finish then
    if not start then return "No dates recorded" end
    return "Started " .. ReadHistory.dateText(start, 1)
  end
  if not start then return "Finished " .. ReadHistory.dateText(finish, precision) end

  local sy, sm, sd = parts(start)
  local fy, fm, fd = parts(finish)
  if not (sy and fy) then
    return ReadHistory.dateText(start, 1) .. " – " .. ReadHistory.dateText(finish, precision)
  end

  if precision >= 3 then
    if sy == fy then return tostring(fy) end
    return ReadHistory.dateText(start, 1) .. " – " .. tostring(fy)
  end
  if precision == 2 then
    if sy == fy and sm == fm then return MONTHS[fm] .. " " .. fy end
    return ReadHistory.dateText(start, 1) .. " – " .. MONTHS[fm] .. " " .. fy
  end
  if sy == fy and sm == fm then
    if sd == fd then return ReadHistory.dateText(finish, 1) end
    return sd .. " – " .. ReadHistory.dateText(finish, 1)
  end
  if sy == fy then
    -- the year belongs to the end of the range, not to both ends
    return ReadHistory.shortDate(start, fy .. "-01-01") .. " – " .. ReadHistory.dateText(finish, 1)
  end
  return ReadHistory.dateText(start, 1) .. " – " .. ReadHistory.dateText(finish, 1)
end

-- Which read progress follows. The one rule, in Book:currentRead.
function ReadHistory.current(reads)
  return Book:currentRead(reads)
end

function ReadHistory.ordinal(n)
  n = number(n) or 0
  local last_two = n % 100
  local suffix = "th"
  if last_two < 11 or last_two > 13 then
    local last = n % 10
    if last == 1 then suffix = "st"
    elseif last == 2 then suffix = "nd"
    elseif last == 3 then suffix = "rd" end
  end
  return tostring(n) .. suffix
end

local function editionPages(read)
  local edition = type(read) == "table" and read.edition
  return type(edition) == "table" and number(edition.pages) or nil
end

local function formatName(read, fallback)
  local edition = type(read) == "table" and read.edition
  local name = type(edition) == "table" and edition.edition_format or nil
  if not name or name == "" then
    name = type(edition) == "table" and Book:readingFormat(number(edition.reading_format_id)) or nil
  end
  if (not name or name == "") and fallback then name = fallback end
  return name
end

ReadHistory.formatName = formatName
ReadHistory.editionPages = editionPages

local FIELD_LABELS = {
  started_at = "start date", finished_at = "finish date",
  finished_at_precision = "finish precision", edition_id = "edition",
  progress_pages = "page",
}
function ReadHistory.fieldLabel(field)
  return FIELD_LABELS[field] or tostring(field)
end

local function join(pieces)
  local kept = {}
  for _, piece in ipairs(pieces) do
    if piece and piece ~= "" then kept[#kept + 1] = piece end
  end
  return table.concat(kept, " · ")
end

-- The reading row on book details: `{ label, pct, support }`.
--   in progress: Page 120 of 304, 39%, 3rd read · since 3 Nov · Paperback
--   finished:    Finished 20 Mar 2026, 100%, 3rd read · Paperback
--   none:        No reads yet, nil, Add a past read
-- `opts.state` puts a state in words at the start of the support line. `opts.pages` is the
-- book's page count for a read whose edition has none. `opts.format` is the book's format for a
-- read whose edition has none. `opts.today` fixes which dates are in the current year.
function ReadHistory.summary(reads, opts)
  opts = opts or {}
  reads = reads or {}
  local current = ReadHistory.current(reads)
  if not current then
    return { label = "No reads yet", pct = nil, support = "Add a past read" }
  end

  local count = #reads
  local position = count
  for i = 1, count do
    if reads[i] == current then position = i; break end
  end
  local many = count > 1
  local format = formatName(current, opts.format)
  local support

  if not current.finished_at then
    local edition = type(current.edition) == "table" and current.edition or nil
    local audiobook = edition and number(edition.reading_format_id) == 2
    local pages = not audiobook and editionPages(current) or number(opts.pages)
    local page = opts.page ~= nil and number(opts.page) or number(current.progress_pages) or 0
    local label, pct
    if audiobook then
      label = formatName(current, opts.format) or "Audiobook"
      format = nil
    elseif pages and pages > 0 then
      label = string.format("Page %d of %d", page, pages)
      pct = math.floor(page * 100 / pages + 0.5)
      pct = math.max(0, math.min(100, pct))
    elseif page > 0 then
      label = string.format("Page %d", page)
    elseif not audiobook then
      label = "Reading"
    end

    local pieces = {}
    if many then pieces[#pieces + 1] = ReadHistory.ordinal(position) .. " read" end
    if current.started_at then
      local since = ReadHistory.shortDate(current.started_at, opts.today)
      if since ~= "" then
        pieces[#pieces + 1] = (many and "since " or "Since ") .. since
      end
    end
    if format then pieces[#pieces + 1] = format end
    support = join(pieces)
    if opts.state then support = join({ opts.state, support }) end
    return { label = label, pct = pct, support = support }
  end

  local pieces = {}
  if many then pieces[#pieces + 1] = ReadHistory.ordinal(position) .. " read" end
  if format then pieces[#pieces + 1] = format end
  support = join(pieces)
  if opts.state then support = join({ opts.state, support }) end
  return {
    label = "Finished " .. ReadHistory.dateText(current.finished_at, current.finished_at_precision),
    pct = 100,
    support = support,
  }
end

local function endOfPeriod(date, precision)
  local year, month = parts(date)
  if not year then return nil end
  precision = number(precision) or 1
  if precision >= 3 then return string.format("%04d-12-31", year) end
  if precision == 2 then return string.format("%04d-%02d-%02d", year, month, lastDay(year, month)) end
  return dateString(date)
end

-- The first thing wrong with a form's dates, as a sentence, and the field it is about. nil when
-- there is nothing wrong. `today` fixes what counts as the future (YYYY-MM-DD).
function ReadHistory.validate(form, today)
  form = form or {}
  today = today or os.date("%Y-%m-%d")
  local start, finish = form.started_at, form.finished_at
  local precision = number(form.finished_at_precision) or 1

  if start ~= nil and not parts(start) then
    return "The start date is not a real date.", "started_at"
  end
  if finish ~= nil and not parts(finish) then
    return "The finish date is not a real date.", "finished_at"
  end
  start, finish = dateString(start), dateString(finish)

  if type(start) == "string" and start > today then
    return "The start is after today.", "started_at"
  end
  if type(finish) == "string" then
    local last = endOfPeriod(finish, precision)
    if last and last > today then
      return "The finish is after today.", "finished_at"
    end
    if type(start) == "string" and last and last < start then
      return "The finish is before the start.", "finished_at"
    end
  end
end

-- Only the fields that changed, and the ones to clear. `nil` in the proposal clears a date that
-- the saved read had; a field that is unchanged is never sent.
local CHANGE_FIELDS = { "started_at", "finished_at", "finished_at_precision", "edition_id",
  "progress_pages" }

function ReadHistory.diff(base, proposed)
  local change, clear = {}, {}
  base, proposed = base or {}, proposed or {}
  for _, key in ipairs(CHANGE_FIELDS) do
    local before, after = base[key], proposed[key]
    if key == "started_at" or key == "finished_at" then
      before, after = dateString(before), dateString(after)
    else
      before, after = number(before), number(after)
    end
    if after == nil then
      if before ~= nil then clear[key] = true end
    elseif after ~= before then
      change[key] = after
    end
  end
  return change, clear
end

-- The saved reads with the queued read actions laid over them, in the saved order (oldest
-- first). Each action carries its own `base` for the sender; the projection only applies its
-- `change` and `clear`. Read kinds are those of reading_actions.lua: read_dates, read_edition,
-- add_read and remove_read.
local function actionMatches(read, action)
  if action.local_id ~= nil then return tostring(read.id) == tostring(action.local_id) end
  return action.read_id ~= nil and tostring(read.id) == tostring(action.read_id)
end

local function applyAction(read, action)
  for key, value in pairs(action.change or {}) do read[key] = value end
  for key in pairs(action.clear or {}) do read[key] = nil end
end

function ReadHistory.project(reads, actions)
  local out = {}
  for i, read in ipairs(reads or {}) do out[i] = copyRead(read) end

  local ordered = {}
  for i, action in ipairs(actions or {}) do ordered[i] = action end
  table.sort(ordered, function(a, b) return (number(a.seq) or 0) < (number(b.seq) or 0) end)

  for _, action in ipairs(ordered) do
    if action.kind == "read_dates" or action.kind == "read_edition" then
      for _, read in ipairs(out) do
        if actionMatches(read, action) then applyAction(read, action); break end
      end
    elseif action.kind == "add_read" then
      local read = copyRead(action.read or action.change or {})
      read.id = action.local_id or action.read_id or ("local:" .. tostring(action.seq or (#out + 1)))
      out[#out + 1] = read
    elseif action.kind == "remove_read" then
      for i = #out, 1, -1 do
        if actionMatches(out[i], action) then table.remove(out, i); break end
      end
    end
  end
  return out
end

-- A page in one edition as the same share of another: page 120 of 300 is page 160 of 400.
-- With either page count unknown the page is returned unchanged: no conversion is invented.
function ReadHistory.convertPage(page, old_pages, new_pages)
  page, old_pages, new_pages = number(page), number(old_pages), number(new_pages)
  if not (page and old_pages and new_pages and old_pages > 0 and new_pages > 0) then
    return page
  end
  return math.min(math.max(1, math.floor(page * new_pages / old_pages + 0.5)), new_pages)
end

return ReadHistory
