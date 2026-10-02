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

r.finish()
