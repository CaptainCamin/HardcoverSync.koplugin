-- Reading goals: reading the API's rows, the pace arithmetic (all of it offline),
-- which goal Home shows, and books finished offline counting toward a goal.
--
-- Run with:  lua spec/goals_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local Goals = dofile(PLUGIN .. "/hardcover/lib/goals.lua")

local D = Goals.days
local TODAY = D(2026, 10, 2)

local function row(over)
  local g = { id = 1, goal = 70, metric = "book", description = "2026 Reading Goal", start_date = "2026-01-01",
    end_date = "2027-01-01", progress = 46.0, archived = false }
  for k, v in pairs(over or {}) do g[k] = v end
  return g
end

print("\n== dates ==")

check("days are exact across leap years and month ends", function()
  assert(D(1970, 1, 1) == 0 and D(1970, 1, 2) == 1)
  assert(D(2024, 3, 1) - D(2024, 2, 28) == 2, "2024 is a leap year")
  assert(D(2025, 3, 1) - D(2025, 2, 28) == 1)
  assert(D(2027, 1, 1) - D(2026, 1, 1) == 365)
  assert(Goals.parseDate("2026-10-02") == TODAY)
  assert(Goals.parseDate("2026-13-01") == nil and Goals.parseDate("x") == nil and Goals.parseDate(nil) == nil)
end)

check("today comes from the clock, not a time zone sum", function()
  assert(Goals.today(os.time { year = 2026, month = 10, day = 2, hour = 12 }) == TODAY)
end)

check("the last day of a period is the day before its end date", function()
  local g = Goals.normalize({ row() })[1]
  assert(Goals.datesText(g) == "Jan 1 \226\128\147 Dec 31, 2026", Goals.datesText(g))
  local m = Goals.normalize({ row({ start_date = "2025-12-01", end_date = "2026-02-01" }) })[1]
  assert(Goals.datesText(m) == "Dec 1, 2025 \226\128\147 Jan 31, 2026", Goals.datesText(m))
end)

print("\n== reading the rows ==")

check("archived and malformed goals are dropped, the rest keep their order", function()
  local out = Goals.normalize({
    row({ id = 1 }), row({ id = 2, archived = true }), row({ id = 3, goal = 0 }), row({ id = 4, end_date = "2025-01-01" }),
    row({ id = 5, start_date = "nope" }), row({ id = false }), "x", row({ id = 6, metric = "page", goal = 3000 }),
  })
  assert(#out == 2 and out[1].id == 1 and out[2].id == 6 and out[2].metric == "page")
  assert(#Goals.normalize(nil) == 0 and #Goals.normalize("x") == 0)
end)

check("a goal with no description gets a name", function()
  assert(Goals.normalize({ row({ description = "" }) })[1].name == "Reading goal")
end)

print("\n== pace ==")

check("behind, ahead and on pace read as whole books", function()
  local g = Goals.normalize({ row() })[1]
  local p = Goals.pace(g, TODAY)
  assert(p.status == "6 behind pace", p.status)
  assert(math.abs(p.expected - 70 * 274 / 365) < 1e-9)
  assert(Goals.pace(Goals.normalize({ row({ progress = 60 }) })[1], TODAY).status == "7 ahead of pace")
  assert(Goals.pace(Goals.normalize({ row({ progress = 52 }) })[1], TODAY).status == "On pace")
end)

check("what finishing takes, in books or pages a week", function()
  local p = Goals.pace(Goals.normalize({ row() })[1], TODAY)
  assert(p.per_week_text == "1.8 books a week to finish", p.per_week_text)
  local pages = Goals.pace(Goals.normalize({ row({ metric = "page", goal = 3000, progress = 150, start_date = "2026-10-01", end_date = "2026-11-01" }) })[1], TODAY)
  assert(pages.per_week_text == "665 pages a week to finish", pages.per_week_text)
end)

check("done, ended and not-yet-started goals say so", function()
  assert(Goals.pace(Goals.normalize({ row({ progress = 70 }) })[1], TODAY).status == "Done")
  local ended = Goals.pace(Goals.normalize({ row({ start_date = "2025-01-01", end_date = "2026-01-01", progress = 77, goal = 100 }) })[1], TODAY)
  assert(ended.status == "Ended 23 short" and ended.over and ended.per_week == nil)
  local up = Goals.pace(Goals.normalize({ row({ start_date = "2026-10-05", end_date = "2026-11-05" }) })[1], TODAY)
  assert(up.status == "Starts in 3 days" and up.upcoming)
  assert(Goals.leftText(ended) == "Ended" and Goals.leftText(Goals.pace(Goals.normalize({ row() })[1], D(2026, 12, 31))) == "1 day left")
end)

check("the last day and the day after behave", function()
  local g = Goals.normalize({ row() })[1]
  assert(not Goals.pace(g, D(2026, 12, 31)).over and Goals.pace(g, D(2027, 1, 1)).over)
  assert(Goals.pace(g, D(2026, 1, 1)).delta == 46 - 0, "on day one nothing is expected yet")
end)

print("\n== which goal ==")

check("current goals come before past, nearest end first, then not-done, then the bigger target", function()
  local gs = Goals.normalize({
    row({ id = 1, goal = 30 }), row({ id = 2, goal = 70 }), row({ id = 3, goal = 12 }),
    row({ id = 4, start_date = "2026-10-01", end_date = "2026-11-01", goal = 3000, metric = "page", progress = 150 }),
    row({ id = 5, start_date = "2025-01-01", end_date = "2026-01-01", goal = 100, progress = 77 }),
  })
  local s = Goals.split(gs, TODAY)
  local ids = {}
  for _, g in ipairs(s.current) do ids[#ids + 1] = g.id end
  assert(table.concat(ids, ",") == "4,2,1,3", table.concat(ids, ",")) -- of the three 2026 goals: the unfinished one first, then the done ones, bigger target first
  assert(#s.past == 1 and s.past[1].id == 5)
end)

check("Home shows the nearest-ending goal that is not finished", function()
  local gs = Goals.normalize({ row({ id = 1, goal = 30 }), row({ id = 2, goal = 70 }) })
  assert(Goals.pick(gs, TODAY).id == 2, "the unfinished one, not the one already done")
  assert(Goals.pick(Goals.normalize({ row({ id = 1, goal = 30 }) }), TODAY).id == 1, "all done: still shows one")
  -- a page goal that ends sooner does not take the place of the book goal
  local mixed = Goals.normalize({ row({ id = 1 }), row({ id = 9, metric = "page", goal = 3000, progress = 150, start_date = "2026-10-01", end_date = "2026-11-01" }) })
  assert(Goals.pick(mixed, TODAY).id == 1)
  assert(Goals.pick({ mixed[2] }, TODAY).id == 9, "with only a page goal, that is the one")
  assert(Goals.pick({}, TODAY) == nil)
  assert(Goals.pick(Goals.normalize({ row({ start_date = "2025-01-01", end_date = "2026-01-01" }) }), TODAY) == nil, "nothing current")
end)

print("\n== finished offline ==")

check("a book finished offline counts toward a running book goal, not a page or past one", function()
  local book = Goals.normalize({ row() })[1]
  local page = Goals.normalize({ row({ metric = "page", goal = 3000 }) })[1]
  local old = Goals.normalize({ row({ start_date = "2025-01-01", end_date = "2026-01-01" }) })[1]
  assert(Goals.extra(book, TODAY, 2) == 2)
  assert(Goals.extra(page, TODAY, 2) == 0 and Goals.extra(old, TODAY, 2) == 0 and Goals.extra(book, TODAY, 0) == 0)
  assert(Goals.extra(book, TODAY, nil) == 0 and Goals.extra(book, TODAY, "x") == 0)
  local p = Goals.pace(book, TODAY, 2)
  assert(p.progress == 48 and p.extra == 2 and p.status == "4 behind pace", p.status)
end)

print("\n== making and changing goals ==")

check("a date survives the trip to a string and back, across every month length and leap day", function()
  for _, ymd in ipairs({ { 1970, 1, 1 }, { 2000, 2, 29 }, { 2024, 2, 29 }, { 2026, 12, 31 }, { 2027, 1, 1 }, { 1999, 12, 31 }, { 2100, 3, 1 } }) do
    local d = D(ymd[1], ymd[2], ymd[3])
    local str = Goals.dateString(d)
    assert(str == string.format("%04d-%02d-%02d", ymd[1], ymd[2], ymd[3]), str)
    assert(Goals.parseDate(str) == d)
  end
  for d = D(2024, 1, 1), D(2025, 12, 31) do assert(Goals.parseDate(Goals.dateString(d)) == d) end
end)

check("the presets are this year, next year and this month, ending on the day after", function()
  local p = Goals.presets(TODAY)
  assert(#p == 3 and p[1].key == "this_year" and p[2].key == "next_year" and p[3].key == "this_month")
  assert(p[1].start_date == "2026-01-01" and p[1].end_date == "2027-01-01" and p[1].name == "2026 Reading Goal")
  assert(p[2].start_date == "2027-01-01" and p[2].end_date == "2028-01-01")
  assert(p[3].start_date == "2026-10-01" and p[3].end_date == "2026-11-01" and p[3].name == "October Reading Goal")
  assert(p[3].label == "This month (October)" and p[1].label == "This year (2026)")
  -- December rolls into January of the next year
  local dec = Goals.presets(D(2026, 12, 15))[3]
  assert(dec.start_date == "2026-12-01" and dec.end_date == "2027-01-01", dec.end_date)
  assert(Goals.presets(D(2026, 1, 1))[3].end_date == "2026-02-01")
end)

check("a new goal starts as a book a month for this year, and is fit to save", function()
  local f = Goals.newForm(TODAY)
  assert(f.target == 12 and f.metric == "book" and f.name == "2026 Reading Goal" and f.privacy_setting_id == nil)
  assert(Goals.validate(f) == nil)
end)

check("validation names the first thing to fix", function()
  local function with(over)
    local f = Goals.newForm(TODAY)
    for k, v in pairs(over) do f[k] = v end
    return f
  end
  assert(Goals.validate(with({ name = "   " })) == "Give the goal a name.")
  assert(Goals.validate(with({ name = string.rep("x", 121) })) == "The name is too long.")
  assert(Goals.validate(with({ metric = "audio" })) == "Choose books or pages.")
  for _, bad in ipairs({ 0, -3, 2.5, "abc", false }) do
    assert(Goals.validate(with({ target = bad })) == "The target must be a whole number, at least 1.", tostring(bad))
  end
  assert(Goals.validate(with({ target = 10001 })) == "The target can be at most 10000.")
  assert(Goals.validate(with({ metric = "page", target = 10001 })) == nil, "pages allow far bigger targets")
  assert(Goals.validate(with({ metric = "page", target = 1000001 })) == "The target can be at most 1000000.")
  assert(Goals.validate(with({ start_date = "2026-13-01" })) == "Choose when the goal starts and ends.")
  assert(Goals.validate(with({ end_date = "2026-01-01" })) == "The goal must end after it starts.")
  assert(Goals.validate(with({ end_date = "2026-01-01", start_date = "2026-01-01" })) == "The goal must end after it starts.")
  assert(Goals.validate(with({ end_date = "2040-01-01" })) == "The goal can run for 10 years at most.")
  assert(Goals.validate(with({ privacy_setting_id = 9 })) == "Choose who can see the goal.")
  assert(Goals.validate(with({ privacy_setting_id = 3 })) == nil)
  assert(Goals.validate(nil) == "Nothing to save.")
end)

check("the request carries what the API's GoalInput takes, trimmed and whole", function()
  local f = Goals.newForm(TODAY)
  f.name = "  My goal  "
  f.target = "30"
  local input = Goals.input(f)
  assert(input.description == "My goal" and input.goal == 30 and input.metric == "book")
  assert(input.start_date == "2026-01-01" and input.end_date == "2027-01-01")
  assert(input.privacy_setting_id == nil, "a form with no visibility leaves it out")
  f.privacy_setting_id = 2
  assert(Goals.input(f).privacy_setting_id == 2)
  -- only fields GoalInput has
  local allowed = { description = true, metric = true, goal = true, start_date = true, end_date = true, privacy_setting_id = true }
  for k in pairs(Goals.input(f)) do assert(allowed[k], "GoalInput has no field " .. k) end
end)

check("an existing goal fills the form, and keeps its visibility", function()
  local g = Goals.normalize({ row({ id = 7, privacy_setting_id = 3 }) })[1]
  assert(g.privacy_setting_id == 3)
  local f = Goals.formFrom(g)
  assert(f.id == 7 and f.target == 70 and f.metric == "book" and f.privacy_setting_id == 3 and f.start_date == "2026-01-01")
  assert(Goals.validate(f) == nil)
  assert(Goals.normalize({ row({ privacy_setting_id = nil }) })[1].privacy_setting_id == nil)
end)

check("a saved goal replaces the one with its id, or joins the list; an archived one leaves it", function()
  local gs = Goals.normalize({ row({ id = 1 }), row({ id = 2, goal = 30 }) })
  local changed = Goals.normalize({ row({ id = 2, goal = 99 }) })[1]
  local out = Goals.upsert(gs, changed)
  assert(#out == 2 and out[2].target == 99 and out[1].id == 1 and gs[2].target == 30, "the original list must not change")
  local added = Goals.upsert(gs, Goals.normalize({ row({ id = 3 }) })[1])
  assert(#added == 3 and added[3].id == 3)
  local gone = Goals.remove(gs, 1)
  assert(#gone == 1 and gone[1].id == 2 and #gs == 2)
  assert(#Goals.upsert(nil, changed) == 1 and #Goals.remove(nil, 1) == 0)
end)

check("labels for the form's rows", function()
  assert(Goals.metricLabel("book") == "Books" and Goals.metricLabel("page") == "Pages" and Goals.metricLabel("x") == "")
  assert(Goals.privacyLabel(1) == "Public" and Goals.privacyLabel(2) == "Follows" and Goals.privacyLabel(3) == "Private" and Goals.privacyLabel(nil) == nil)
  assert(Goals.periodText("2026-01-01", "2027-01-01") == "Jan 1 \226\128\147 Dec 31, 2026")
  assert(Goals.periodText("x", "2027-01-01") == "")
  assert(Goals.WRITE_SCOPE == "write:goals")
end)

r.finish()
