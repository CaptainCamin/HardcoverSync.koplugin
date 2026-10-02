-- Reading goals, as plain data and arithmetic.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite. The dialogs
-- (ui/goals_dialog.lua, ui/goal_dialog.lua and the card on the home screen) only
-- draw what this returns.
--
-- Everything that is not fetched is worked out here, from a goal as it was last
-- saved and the date, so the screens read the same offline as online: how far
-- through the period you are, where you should be by now, and how many books (or
-- pages) a week it takes to finish. Hardcover supplies the goal and its progress;
-- progress is counted by the server from the books you finished in the period.
-- Offline, a book finished here and still waiting in the sync queue is added on top
-- of the saved progress (see Goals.adjust) so the number moves when you finish one.
--
-- What the real API does (checked against live data): a goal has `goal` (the
-- target), `metric` ("book" or "page"), `start_date` and `end_date` (the end is the
-- day AFTER the last day: a 2026 goal ends 2027-01-01), `progress`, a `description`
-- ("2026 Reading Goal") and `archived`. Several goals can cover the same period.

local Goals = {}

-- days since 1970-01-01 for a calendar date; integer arithmetic, so no time zones
-- or daylight saving to get wrong (after Howard Hinnant's days_from_civil)
function Goals.days(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- "2026-10-02" -> days, or nil
function Goals.parseDate(s)
  if type(s) ~= "string" then return nil end
  local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if not y or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
  return Goals.days(y, m, d)
end

-- today's date as days; `now` (seconds) is for tests
function Goals.today(now)
  local t = os.date("*t", now or os.time())
  return Goals.days(t.year, t.month, t.day)
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- days -> year, month, day
local function civil(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return m <= 2 and y + 1 or y, m, d
end

-- "Jan 1 - Dec 31, 2026" (the last day, not the day after it)
function Goals.datesText(goal)
  local from, to = goal.start_days, goal.end_days
  if not (from and to) then return "" end
  local y1, m1, d1 = civil(from)
  local y2, m2, d2 = civil(to - 1)
  local dash = " \226\128\147 "
  if y1 == y2 then
    return string.format("%s %d%s%s %d, %d", MONTHS[m1], d1, dash, MONTHS[m2], d2, y2)
  end
  return string.format("%s %d, %d%s%s %d, %d", MONTHS[m1], d1, y1, dash, MONTHS[m2], d2, y2)
end

--
-- Goals as the API returns them (`me.goals`, or the one-element array Hasura wraps
-- `me` in) as a list: archived and malformed ones are dropped, order kept.
--
function Goals.normalize(rows)
  local out = {}
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if type(row) == "table" and row.id and not row.archived then
      local from, to = Goals.parseDate(row.start_date), Goals.parseDate(row.end_date)
      local target = tonumber(row.goal)
      if from and to and to > from and target and target > 0 then
        out[#out + 1] = {
          id = row.id,
          name = (type(row.description) == "string" and row.description ~= "") and row.description or "Reading goal",
          metric = row.metric == "page" and "page" or "book",
          target = target,
          progress = tonumber(row.progress) or 0,
          start_date = row.start_date,
          end_date = row.end_date,
          start_days = from,
          end_days = to,
          privacy_setting_id = tonumber(row.privacy_setting_id),
          -- kept so a change sends back what the goal already has (see Goals.input)
          conditions = type(row.conditions) == "table" and row.conditions or nil,
        }
      end
    end
  end
  return out
end

--
-- Where a goal stands on day `today`. `extra` is progress not counted yet (books
-- finished offline). Returns:
--   progress, target, fraction (0..1), expected (where you should be today),
--   pace_fraction, delta (progress - expected), days_left, unit ("books"/"pages"),
--   done, over (the period has ended), upcoming (it has not started),
--   status ("6 behind pace", "On pace", "3 ahead of pace", "Done", "Ended 4 short",
--   "Starts in 5 days"), per_week (what finishing takes, or nil).
--
function Goals.pace(goal, today, extra)
  local total = goal.end_days - goal.start_days
  local elapsed = math.min(math.max(today - goal.start_days, 0), total)
  local progress = goal.progress + (extra or 0)
  local expected = goal.target * elapsed / total
  local left = math.max(goal.end_days - today, 0)

  local out = {
    progress = progress,
    target = goal.target,
    fraction = math.min(1, progress / goal.target),
    expected = expected,
    pace_fraction = math.min(1, expected / goal.target),
    delta = progress - expected,
    days_left = left,
    unit = goal.metric == "page" and "pages" or "books",
    done = progress >= goal.target,
    over = today >= goal.end_days,
    upcoming = today < goal.start_days,
    extra = extra or 0,
    -- changed here and not sent yet (see goal_queue.lua); held: Hardcover refused it
    pending = goal.pending and true or false,
    held = goal.held and true or false,
  }

  local remaining = goal.target - progress
  if out.done then
    out.status = "Done"
  elseif out.over then
    out.status = string.format("Ended %d short", math.ceil(remaining))
  elseif out.upcoming then
    local n = goal.start_days - today
    out.status = n == 1 and "Starts tomorrow" or string.format("Starts in %d days", n)
  elseif out.delta >= 1 then
    out.status = string.format("%d ahead of pace", math.floor(out.delta))
  elseif out.delta <= -1 then
    out.status = string.format("%d behind pace", math.floor(-out.delta))
  else
    out.status = "On pace"
  end

  if not out.done and not out.over and left > 0 then
    local per_week = remaining / (left / 7)
    out.per_week = per_week
    out.per_week_text = out.unit == "pages" and string.format("%d pages a week to finish", math.ceil(per_week))
      or string.format("%.1f books a week to finish", per_week)
  end
  return out
end

-- "91 days left", "1 day left", "Ended", "Done"
function Goals.leftText(p)
  if p.over then return "Ended" end
  if p.upcoming then return "" end
  return p.days_left == 1 and "1 day left" or string.format("%d days left", p.days_left)
end

--
-- { current = {...}, past = {...} }: a goal whose period has ended is past. Current
-- ones are ordered by what is nearest to ending, then not-done before done, then the
-- bigger target first (the real goal before a stray smaller one).
--
function Goals.split(goals, today)
  local current, past = {}, {}
  for _, g in ipairs(goals or {}) do
    if today >= g.end_days then past[#past + 1] = g else current[#current + 1] = g end
  end
  table.sort(current, function(a, b)
    if a.end_days ~= b.end_days then return a.end_days < b.end_days end
    local da, db = a.progress >= a.target, b.progress >= b.target
    if da ~= db then return not da end
    if a.target ~= b.target then return a.target > b.target end
    return a.id < b.id
  end)
  table.sort(past, function(a, b)
    if a.end_days ~= b.end_days then return a.end_days > b.end_days end
    return a.id < b.id
  end)
  return { current = current, past = past }
end

-- The goal Home shows: the first current, running, unfinished BOOK goal (a reading
-- goal is "how many books"; a page goal is a side target), else the first such page
-- goal, else the first current goal. "First" is the order of Goals.split: nearest
-- to ending, then the bigger target.
function Goals.pick(goals, today)
  local current = Goals.split(goals, today).current
  local fallback
  for _, g in ipairs(current) do
    if g.progress < g.target and today >= g.start_days then
      if g.metric == "book" then return g end
      fallback = fallback or g
    end
  end
  return fallback or current[1]
end

--
-- Progress not yet counted by the server: books finished on this device whose
-- change is still waiting to be sent. Only a book goal that is running today can
-- count them; a page goal cannot (queued reading is not tied to a period).
--
function Goals.extra(goal, today, finished_offline)
  finished_offline = tonumber(finished_offline) or 0
  if goal.metric ~= "book" or finished_offline <= 0 then return 0 end
  if today < goal.start_days or today >= goal.end_days then return 0 end
  return finished_offline
end


-- ------------------------------------------------------------------ editing
--
-- Making and changing goals. The form is plain data (`form`), checked and turned
-- into the API's GoalInput here, so the rules can be tested without a screen.

-- the sign-in permission Hardcover wants for writing goals (confirmed against the
-- API: the refusal says "Missing scopes: write:goals")
Goals.WRITE_SCOPE = "write:goals"

Goals.METRICS = {
  { key = "book", label = "Books" },
  { key = "page", label = "Pages" },
}

-- ids as the plugin's status privacy uses them (constants/hardcover.lua)
Goals.PRIVACY = {
  { id = 1, label = "Public" },
  { id = 2, label = "Follows" },
  { id = 3, label = "Private" },
}

-- the largest target taken, by what is counted: a typo like 700 books or 3000000
-- pages is far likelier than a goal that size
Goals.MAX_TARGET = { book = 10000, page = 1000000 }

-- no goal runs longer than this many days
Goals.MAX_DAYS = 3660

local MONTH_NAMES = { "January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December" }

Goals.civil = civil

-- days -> "2026-10-02"
function Goals.dateString(days)
  local y, m, d = civil(days)
  return string.format("%04d-%02d-%02d", y, m, d)
end

-- "Jan 1 - Dec 31, 2026" for a period given as two ISO dates (the second is the day
-- AFTER the last day), or "" when either does not read
function Goals.periodText(start_date, end_date)
  local from, to = Goals.parseDate(start_date), Goals.parseDate(end_date)
  if not (from and to) then return "" end
  return Goals.datesText({ start_days = from, end_days = to })
end

--
-- The periods offered when making a goal, from `today` (days): this year, next
-- year, this month. Each carries the name Hardcover's own screen would give it.
--
function Goals.presets(today)
  local y, m = civil(today)
  local function first(year, month)
    if month > 12 then year, month = year + 1, month - 12 end
    return Goals.dateString(Goals.days(year, month, 1))
  end
  return {
    { key = "this_year", label = string.format("This year (%d)", y),
      start_date = first(y, 1), end_date = first(y + 1, 1), name = string.format("%d Reading Goal", y) },
    { key = "next_year", label = string.format("Next year (%d)", y + 1),
      start_date = first(y + 1, 1), end_date = first(y + 2, 1), name = string.format("%d Reading Goal", y + 1) },
    { key = "this_month", label = string.format("This month (%s)", MONTH_NAMES[m]),
      start_date = first(y, m), end_date = first(y, m + 1), name = string.format("%s Reading Goal", MONTH_NAMES[m]) },
  }
end

-- A new goal's starting point: a book a month, for this year.
function Goals.newForm(today)
  local preset = Goals.presets(today)[1]
  return {
    name = preset.name,
    metric = "book",
    target = 12,
    start_date = preset.start_date,
    end_date = preset.end_date,
    privacy_setting_id = nil, -- nil: the account's own setting, looked up when it is saved
  }
end

-- What there is to change on an existing goal.
function Goals.formFrom(goal)
  return {
    id = goal.id,
    name = goal.name,
    metric = goal.metric,
    target = goal.target,
    start_date = goal.start_date,
    end_date = goal.end_date,
    privacy_setting_id = goal.privacy_setting_id,
    conditions = goal.conditions,
  }
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--
-- Is the form fit to send? Returns nil when it is, else one sentence saying what to
-- fix (the first problem; the form shows it).
--
function Goals.validate(form)
  if type(form) ~= "table" then return "Nothing to save." end

  local name = trim(form.name)
  if name == "" then return "Give the goal a name." end
  if #name > 120 then return "The name is too long." end

  if form.metric ~= "book" and form.metric ~= "page" then return "Choose books or pages." end

  local target = tonumber(form.target)
  if not target or target ~= math.floor(target) or target < 1 then
    return "The target must be a whole number, at least 1."
  end
  if target > Goals.MAX_TARGET[form.metric] then
    return string.format("The target can be at most %d.", Goals.MAX_TARGET[form.metric])
  end

  local from, to = Goals.parseDate(form.start_date), Goals.parseDate(form.end_date)
  if not (from and to) then return "Choose when the goal starts and ends." end
  if to <= from then return "The goal must end after it starts." end
  if to - from > Goals.MAX_DAYS then return "The goal can run for 10 years at most." end

  if form.privacy_setting_id ~= nil then
    local ok
    for _, p in ipairs(Goals.PRIVACY) do
      if p.id == form.privacy_setting_id then ok = true end
    end
    if not ok then return "Choose who can see the goal." end
  end
  return nil
end

--
-- The API's GoalInput for a form that passed validate. `privacy_setting_id` is left
-- out when the form has none (a new goal takes the account's setting: see
-- HardcoverApi:saveGoal), and an edit sends everything it can change, so what is sent
-- does not depend on how the server treats fields that are left out.
--
function Goals.input(form)
  local input = {
    description = trim(form.name),
    metric = form.metric,
    goal = math.floor(tonumber(form.target)),
    start_date = form.start_date,
    end_date = form.end_date,
    conditions = Goals.conditions(form.conditions),
  }
  if form.privacy_setting_id ~= nil then
    input.privacy_setting_id = form.privacy_setting_id
  end
  return input
end

-- The API's GoalInput requires `conditions` (checked against the live schema: both
-- insert_goal and update_goal fail with "missing required field 'conditions'" without
-- it), and accepts only these keys in it. A goal keeps the ones it has (filters set on
-- the website); a new goal has none, which is an empty object.
local CONDITION_KEYS = { "authorBipoc", "authorGenderIds", "authorLgbtqia", "bookCategoryIds", "readingFormatId" }

function Goals.conditions(existing)
  local out = {}
  if type(existing) == "table" then
    for _, key in ipairs(CONDITION_KEYS) do
      if existing[key] ~= nil then out[key] = existing[key] end
    end
  end
  return out
end

-- label of a metric or a privacy id, for the form's rows
function Goals.metricLabel(key)
  for _, m in ipairs(Goals.METRICS) do if m.key == key then return m.label end end
  return ""
end

function Goals.privacyLabel(id)
  for _, p in ipairs(Goals.PRIVACY) do if p.id == id then return p.label end end
  return nil
end

-- The list with `goal` in it: replacing the one with its id, else added. A copy.
function Goals.upsert(goals, goal)
  local out, placed = {}, false
  for _, g in ipairs(goals or {}) do
    if g.id == goal.id then
      out[#out + 1] = goal
      placed = true
    else
      out[#out + 1] = g
    end
  end
  if not placed then out[#out + 1] = goal end
  return out
end

-- The list without the goal with this id. A copy.
function Goals.remove(goals, id)
  local out = {}
  for _, g in ipairs(goals or {}) do
    if g.id ~= id then out[#out + 1] = g end
  end
  return out
end

return Goals
