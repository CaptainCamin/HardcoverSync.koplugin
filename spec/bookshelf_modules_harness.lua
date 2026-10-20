-- The goal and stats cards Hardcover Sync gives Bookshelf's micro-modules
-- (lib/bookshelf_modules.lua): what the cards say, and the stub files that load them.
--
-- Run with:  lua spec/bookshelf_modules_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local made = {}
package.preload["libs/libkoreader-lfs"] = function()
  return {
    attributes = function(path) return made[path] and "directory" or nil end,
    mkdir = function(path) made[path] = true; os.execute("mkdir -p '" .. path .. "'") return true end,
  }
end

local Goals = require("hardcover/lib/goals")
local Modules = require("hardcover/lib/bookshelf_modules")
local TODAY = Goals.days(2026, 10, 2)

local function cache(goals, stats)
  return {
    goals = function() return goals end,
    stats = function() return stats end,
  }
end

local year_goal = { id = 1, name = "2026 Reading Goal", metric = "book", target = 70, progress = 46,
  start_date = "2026-01-01", end_date = "2027-01-01",
  start_days = Goals.days(2026, 1, 1), end_days = Goals.days(2027, 1, 1) }

check("goal card shows progress, target and pace", function()
  local c = Modules.goalCard(cache({ year_goal }), nil, 7, 0, TODAY)
  assert(c.heading == "2026 Reading Goal")
  assert(c.value == "46" and c.suffix == " / 70 books", c.suffix)
  assert(c.fraction > 0.65 and c.fraction < 0.66)
  assert(c.sub:find("pace"), c.sub)
end)

check("goal card counts books finished offline", function()
  local c = Modules.goalCard(cache({ year_goal }), nil, 7, 2, TODAY)
  assert(c.value == "48", c.value)
end)

check("goal card says why there is nothing to show", function()
  local _, why = Modules.goalCard(cache(nil), nil, 7, 0, TODAY)
  assert(why == "no_data")
  _, why = Modules.goalCard(cache({}), nil, 7, 0, TODAY)
  assert(why == "no_goal")
  _, why = Modules.goalCard(cache({ year_goal }), nil, nil, 0, TODAY)
  assert(why == "signed_out")
end)

local rows = {
  { date = "2026-03-14", pages = 300, rating = 4 },
  { date = "2026-03-20", pages = 200, rating = 5 },
  { date = "2026-06-01", pages = 100 },
  { date = "2025-12-31", pages = 999 },
}

check("stats card counts the year's finished books", function()
  local c = Modules.statsCard(cache(nil, { rows = rows }), 7, 2026)
  assert(c.heading == "Finished in 2026")
  assert(c.value == "3" and c.suffix == " books")
  assert(c.sub:find("600 pages") and c.sub:find("4.5"), c.sub)
  assert(c.context:find("March") and c.context:find("%(2%)"), c.context)
end)

check("stats card with nothing saved", function()
  local _, why = Modules.statsCard(cache(nil, nil), 7, 2026)
  assert(why == "no_data")
end)

check("install writes stubs that return the specs, only when Bookshelf is there", function()
  local dir = os.tmpname()
  os.remove(dir)
  assert(Modules.install({ ui = {} }, nil) == false, "no Bookshelf, nothing written")
  assert(Modules.install({ ui = {} }, dir .. "/bookshelf/micromodules") == true)
  for key in pairs(Modules.specs) do
    local spec = dofile(dir .. "/bookshelf/micromodules/" .. key .. ".lua")
    assert(spec == Modules.specs[key] and spec.key == key and type(spec.render) == "function", key)
  end
  os.execute("rm -rf '" .. dir .. "'")
end)

check("specs meet Bookshelf's loader contract", function()
  for key, spec in pairs(Modules.specs) do
    assert(spec.key == key and type(spec.title) == "string" and type(spec.summary) == "string"
      and type(spec.render) == "function" and type(spec.on_tap) == "function", key)
  end
end)

r.finish()
