-- Reading stats: what the books you have finished add up to. Pure logic, no KOReader.
--
-- Rows come from Hardcover's finished books (see HardcoverApi:getStatsRows) and are boiled
-- down to what the numbers need (`normalize`). Whatever the library looks like has to give a
-- sensible answer: books imported with no dates, audiobooks with no pages, a finish that
-- is only known to the month or the year, a library of three books or of three thousand.
--
-- A book belongs to the year (and month) it was last finished. That is the finish of its
-- latest read when Hardcover has one, else the book's last read date. A date known only to
-- the month or year is never placed on a day Hardcover filled in as a stand-in. A book with
-- no date at all still counts in "all time" and is left out of every period.

local Stats = {}

Stats.RATINGS = 10 -- half stars: 0.5 .. 5
Stats.LENGTHS = {
  { label = "Under 200", under = 200 },
  { label = "200\226\128\147299", under = 300 },
  { label = "300\226\128\147399", under = 400 },
  { label = "400\226\128\147599", under = 600 },
  { label = "600+", under = math.huge },
}

local function number(v)
  v = tonumber(v)
  if v and v == v and v ~= math.huge and v ~= -math.huge then return v end
end

local function text(v)
  if type(v) == "string" and v ~= "" then return v end
end

-- "2025-03-14", "2025-03" or "2025" (the precision is the length), from a date column or a
-- timestamp; nil when it is not a date.
local function datePart(value, precision)
  if type(value) ~= "string" then return nil end
  local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  y = tonumber(y)
  if not y or y < 1900 or y > 2200 then return nil end
  precision = tonumber(precision)
  if precision == 3 then return string.format("%04d", y) end
  if precision == 2 then return string.format("%04d-%s", y, m) end
  return string.format("%04d-%s-%s", y, m, d)
end

-- One finished book as a small row: id, title, rating (or nil), date (see above), pages,
-- audio (seconds), author (the first credited). nil for something that is not a book.
function Stats.normalize(raw)
  if type(raw) ~= "table" then return nil end
  local book = type(raw.book) == "table" and raw.book or {}

  local date, started
  local read = type(raw.user_book_reads) == "table" and raw.user_book_reads[1] or nil
  if type(read) == "table" then
    date = datePart(read.finished_at, read.finished_at_precision)
    started = datePart(read.started_at)
  end
  date = date or datePart(raw.last_read_date)

  local author
  local credits = type(book.contributions) == "table" and book.contributions or {}
  local first = credits[1]
  if type(first) == "table" and type(first.author) == "table" then author = text(first.author.name) end

  local rating = number(raw.rating)
  if rating and (rating < 0.5 or rating > 5) then rating = nil end
  local pages, audio = number(book.pages), number(book.audio_seconds)

  return {
    id = number(raw.id),
    title = text(book.title),
    rating = rating,
    date = date,
    started = started,
    pages = pages and pages > 0 and math.floor(pages) or nil,
    audio = audio and audio > 0 and math.floor(audio) or nil,
    author = author,
  }
end

function Stats.normalizeAll(list)
  local rows = {}
  for _, raw in ipairs(type(list) == "table" and list or {}) do
    local row = Stats.normalize(raw)
    if row then rows[#rows + 1] = row end
  end
  return rows
end

-- Full reading history for the Bookshelf cards. Separate from the dashboard's
-- one/latest-finish rows above: a book currently being reread still belongs here.
-- Counting follows hardcoverapp/hardcover-sdk's shared/stats.json. Keep only the
-- completed reads, and never assign an unknown/year-only finish to a month.
function Stats.history(list, roles, specializations)
  local primary, overrides = {}, {}
  for _, role in ipairs(roles or {}) do primary[role.id] = role.primary end
  for _, role in ipairs(specializations or {}) do
    overrides[tostring(role.contributor_role_id) .. ":" .. tostring(role.contributor_specialization_id)] = role.primary
  end
  local function isAuthor(c)
    local role = (c.contributor_role_name or c.contribution or ""):lower():match("^%s*(.-)%s*$")
    if role == "translator" then return false end
    if type(c.primary) == "boolean" then return c.primary end
    if c.contributor_role_id then
      local override = overrides[tostring(c.contributor_role_id) .. ":" .. tostring(c.contributor_specialization_id)]
      if override ~= nil then return override end
      return primary[c.contributor_role_id] == true
    end
    return role == "" or role == "author" or role == "writer"
  end
  local function finish(value, precision)
    if tonumber(precision) == 0 then return nil end
    return datePart(value, precision)
  end
  local history = {}
  for _, raw in ipairs(list or {}) do
    local book = raw.book or {}
    if book.id and (raw.status_id == 3 or (tonumber(raw.read_count) or 0) >= 1) then
      local row = { book_id = book.id, title = text(book.title), rating = number(raw.rating),
        image = book.cached_image, authors = {}, reads = {}, completions = 0 }
      for _, c in ipairs(book.cached_contributors or {}) do
        local author = c.author
        if author and (author.id or text(author.slug)) and isAuthor(c) then
          row.authors[#row.authors + 1] = { id = author.id, slug = author.slug, name = text(author.name) }
        end
      end
      local reads = raw.user_book_reads or {}
      local has_finish, eligible, carrier = false, {}, nil
      for _, read in ipairs(reads) do
        if read.finished_at then has_finish = true end
        if tonumber(read.finished_at_precision) ~= 0 then eligible[#eligible + 1] = read end
      end
      -- The query orders by latest finish for the existing dashboard. Fallback
      -- carriers use id order, as Hardcover does, not whichever row arrived first.
      table.sort(eligible, function(a, b) return (a.id or 0) < (b.id or 0) end)
      local fallback = raw.last_read_date and not has_finish and #eligible > 0
      if fallback then
        for _, read in ipairs(eligible) do if not read.started_at then carrier = read; break end end
        if not carrier then
          for _, read in ipairs(eligible) do
            if read.started_at <= raw.last_read_date then carrier = read; break end
          end
        end
      end
      local function add(date)
        row.completions = row.completions + 1
        if date then row.reads[#row.reads + 1] = date end
      end
      for _, read in ipairs(reads) do
        if read.finished_at or read == carrier
            or (read.finished_at_precision ~= nil and (tonumber(read.progress) or 0) >= 100) then
          add(finish(read.finished_at or (read == carrier and raw.last_read_date), read.finished_at_precision))
        end
      end
      if #reads == 0 or (fallback and not carrier) then add(finish(raw.last_read_date)) end
      if row.completions == 0 then add(nil) end -- imported Read entries still count once
      history[#history + 1] = row
    end
  end
  return history
end

local function yearOf(row) return row.date and tonumber(row.date:sub(1, 4)) or nil end

-- Noon of a "YYYY-MM-DD" day, in seconds. Noon keeps a day change clear of a daylight-saving shift.
local function dayTime(date)
  local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  return os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
end

-- The years with finished books, newest first.
function Stats.years(rows)
  local seen, years = {}, {}
  for _, row in ipairs(rows or {}) do
    local y = yearOf(row)
    if y and not seen[y] then seen[y] = true; years[#years + 1] = y end
  end
  table.sort(years, function(a, b) return a > b end)
  return years
end

-- Server genre counts ({ tag, count }, any order) as { label, value }, biggest first.
function Stats.genres(cached)
  local out = {}
  for _, g in ipairs(type(cached) == "table" and cached or {}) do
    local label, count = type(g) == "table" and text(g.tag), type(g) == "table" and number(g.count)
    if label and count and count > 0 then out[#out + 1] = { label = label, value = count } end
  end
  table.sort(out, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.label < b.label
  end)
  return out
end

--
-- The numbers for a period. `opts.year` picks one year (nil: all time), and `opts.month` (1 to 12)
-- narrows that year to one month; `opts.top` is how many authors to list (default 5).
--
-- Returns {
--   year, books, pages, pages_books (books with a page count), audio_seconds, audio_books,
--   undated   (books with no finish date, counted in all time only),
--   by_year   { {year, count, avg_rating (nil when none rated)}... } oldest first, every year between the first and last,
--   months    { 12 counts } (a year only), pages_months { 12 page totals } (a year only),
--   month_unknown (finishes known to the year only),
--   best_month { month, count }, last_month (the latest month with a finish) (a year only),
--   days_list (days from start to finish, smallest first, for books with both days known),
--   average_days (rounded),
--   page_list (the page counts, smallest first),
--   ratings   { counts = {10}, rated, average }, authors { {name, count}... },
--   rated_lengths { {pages, rating}... } (books with both, for the length against rating chart),
--   lengths   { {label, count}... }, average_pages, longest, shortest { title, pages },
-- }
--
function Stats.compute(rows, opts)
  opts = opts or {}
  local year = opts.year
  local month = year and opts.month
  local out = {
    year = year, books = 0, pages = 0, pages_books = 0, audio_seconds = 0, audio_books = 0,
    undated = 0, by_year = {}, months = {}, pages_months = {}, month_unknown = 0, page_list = {}, days_list = {},
    ratings = { counts = {}, rated = 0, average = nil }, authors = {}, lengths = {}, rated_lengths = {},
  }
  for m = 1, 12 do out.months[m] = 0; out.pages_months[m] = 0 end
  for i = 1, Stats.RATINGS do out.ratings.counts[i] = 0 end
  for i, bucket in ipairs(Stats.LENGTHS) do out.lengths[i] = { label = bucket.label, count = 0 } end

  local per_year, first_year, last_year = {}, nil, nil
  local rated_by_year, rating_by_year = {}, {}
  local authors, rating_sum = {}, 0
  for _, row in ipairs(rows or {}) do
    local y = yearOf(row)
    if y then
      per_year[y] = (per_year[y] or 0) + 1
      if row.rating then
        rated_by_year[y] = (rated_by_year[y] or 0) + 1
        rating_by_year[y] = (rating_by_year[y] or 0) + row.rating
      end
      if not first_year or y < first_year then first_year = y end
      if not last_year or y > last_year then last_year = y end
    end

    local m = row.date and #row.date >= 7 and tonumber(row.date:sub(6, 7)) or nil
    if (year == nil or y == year) and (month == nil or m == month) then
      out.books = out.books + 1
      if not y then out.undated = out.undated + 1 end

      if year and row.date and #row.date >= 7 then
        local m = tonumber(row.date:sub(6, 7))
        if m and m >= 1 and m <= 12 then
          out.months[m] = out.months[m] + 1
          out.pages_months[m] = out.pages_months[m] + (row.pages or 0)
        end
      elseif year and row.date then
        out.month_unknown = out.month_unknown + 1
      end

      if row.pages then
        out.pages = out.pages + row.pages
        out.pages_books = out.pages_books + 1
        out.page_list[#out.page_list + 1] = row.pages
        for i, bucket in ipairs(Stats.LENGTHS) do
          if row.pages < bucket.under then out.lengths[i].count = out.lengths[i].count + 1; break end
        end
        if not out.longest or row.pages > out.longest.pages then out.longest = { title = row.title, pages = row.pages } end
        if not out.shortest or row.pages < out.shortest.pages then out.shortest = { title = row.title, pages = row.pages } end
      end
      if row.started and row.date and #row.date == 10 then
        local days = math.floor((dayTime(row.date) - dayTime(row.started)) / 86400 + 0.5)
        if days >= 0 then out.days_list[#out.days_list + 1] = days end
      end
      if row.audio then
        out.audio_seconds = out.audio_seconds + row.audio
        out.audio_books = out.audio_books + 1
      end
      if row.rating then
        local i = math.floor(row.rating * 2 + 0.5)
        out.ratings.counts[i] = out.ratings.counts[i] + 1
        out.ratings.rated = out.ratings.rated + 1
        rating_sum = rating_sum + row.rating
        if row.pages then out.rated_lengths[#out.rated_lengths + 1] = { pages = row.pages, rating = row.rating } end
      end
      if row.author then authors[row.author] = (authors[row.author] or 0) + 1 end
    end
  end

  if first_year then
    -- a long history is shown as its latest 30 years
    for y = math.max(first_year, last_year - 29), last_year do
      local avg = rated_by_year[y] and rating_by_year[y] / rated_by_year[y] or nil
      out.by_year[#out.by_year + 1] = { year = y, count = per_year[y] or 0, avg_rating = avg }
    end
  end
  table.sort(out.page_list)
  table.sort(out.days_list)
  if #out.days_list > 0 then
    local sum = 0
    for _i, days in ipairs(out.days_list) do sum = sum + days end
    out.average_days = math.floor(sum / #out.days_list + 0.5)
  end
  if out.ratings.rated > 0 then out.ratings.average = rating_sum / out.ratings.rated end
  if out.pages_books > 0 then out.average_pages = math.floor(out.pages / out.pages_books + 0.5) end

  if year then
    for m = 1, 12 do
      if out.months[m] > 0 and (not out.best_month or out.months[m] > out.best_month.count) then
        out.best_month = { month = m, count = out.months[m] }
      end
      if out.months[m] > 0 then out.last_month = m end
    end
  end

  for name, count in pairs(authors) do out.authors[#out.authors + 1] = { name = name, count = count } end
  table.sort(out.authors, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  for i = #out.authors, (opts.top or 5) + 1, -1 do out.authors[i] = nil end
  -- an author who wrote a single book of those listed is no "top author": nothing to show
  if #out.authors > 0 and out.authors[1].count < 2 then out.authors = {} end

  return out
end

return Stats
