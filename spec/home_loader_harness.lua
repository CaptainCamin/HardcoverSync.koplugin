-- The home screen's refresh: the order of its requests, what it saves, and that it
-- only tells the screen about what changed. Fakes only, no KOReader.
--
-- Run with:  lua spec/home_loader_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()

local check = r.test

local HomeLoader = require("hardcover/lib/home_loader")
local Home = require("hardcover/lib/home")
local IDS = Home.statusIds()

local function card(id, page) return { book_id = id, title = "Book " .. id, progress_pages = page, pages = 300 } end

-- Fakes that log what was asked and saved. `answers` overrides any reply; the
-- value false means "that part failed" (nil), and `summary = false` that the whole
-- combined request failed. `retry` is what the goals-only retry answers.
local function setup(answers, alive_script)
  answers = answers or {}
  local log = { asked = {}, saved = {}, told = {}, slept = {} }
  local function reply(name, default)
    local v = answers[name]
    if v == nil then v = default end
    return v or nil
  end
  local api = {}
  function api:getShelfCounts() log.asked[#log.asked + 1] = "counts"; return reply("counts", { [2] = 3 }) end
  function api:getHomeSummary()
    log.asked[#log.asked + 1] = "summary"
    if answers.summary == false then return nil, { completed = false } end
    return { reading = reply("reading", { card(1, 10) }), list_count = reply("lists", 4),
             list_marks = {}, goals = reply("goals", { { id = 1 } }) }
  end
  function api:getGoals() log.asked[#log.asked + 1] = "goals"; return reply("retry", { { id = 1 } }) end
  local cache = {}
  function cache:putCounts() log.saved[#log.saved + 1] = "counts" end
  function cache:putReading() log.saved[#log.saved + 1] = "reading" end
  function cache:putGoals() log.saved[#log.saved + 1] = "goals" end

  local checks = 0
  local opts = {
    api = api, cache = cache, user_id = 1, status_ids = IDS,
    alive = function()
      checks = checks + 1
      if alive_script then return alive_script(checks) end
      return true
    end,
    saved_counts = { [2] = 3 },
    saved_reading = { card(1, 10) },
    sleep = function(seconds) log.slept[#log.slept + 1] = seconds end,
    shown_reading = function(entries) return entries end,
    on_counts = function(c) log.told[#log.told + 1] = "counts" end,
    on_reading = function(s) log.told[#log.told + 1] = "reading" end,
    on_list_count = function(n) log.told[#log.told + 1] = "lists:" .. n end,
    on_goals = function(g) log.told[#log.told + 1] = "goals" end,
  }
  return opts, log
end

local function joined(t) return table.concat(t, ",") end

print("\n== the sequence ==")

check("it asks for the counts, then reading, lists and goals in one request", function()
  local opts, log = setup()
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts,summary", joined(log.asked))
end)

check("what comes back is saved, even when it changed nothing on screen", function()
  local opts, log = setup()
  HomeLoader.refresh(opts)
  assert(joined(log.saved) == "counts,reading,goals", joined(log.saved))
end)

check("the screen is told only about what changed", function()
  local opts, log = setup()  -- same counts, same card as saved
  HomeLoader.refresh(opts)
  assert(joined(log.told) == "lists:4,goals", joined(log.told))
end)

check("new counts and a moved page are told to the screen", function()
  local opts, log = setup({ counts = { [2] = 9 }, reading = { card(1, 55) } })
  HomeLoader.refresh(opts)
  assert(joined(log.told) == "counts,reading,lists:4,goals", joined(log.told))
end)

check("the offline-adjusted cards are what is compared and shown", function()
  local opts, log = setup({ reading = { card(1, 10) } })
  -- the queue lays a newer page over both the saved and the fetched copy
  opts.shown_reading = function(entries)
    local out = {}
    for i, e in ipairs(entries) do out[i] = card(e.book_id, 99) end
    return out
  end
  HomeLoader.refresh(opts)
  assert(joined(log.told) == "lists:4,goals", "repainted though nothing differs: " .. joined(log.told))
end)

print("\n== when requests fail ==")

check("a failed request leaves its part alone and the rest carries on", function()
  local opts, log = setup({ counts = false, reading = false })
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts,summary", joined(log.asked))
  assert(joined(log.saved) == "goals", "saved: " .. joined(log.saved))
  assert(joined(log.told) == "lists:4,goals", joined(log.told))
end)

check("a failed combined request leaves reading and lists alone, and the goals are asked for again", function()
  local opts, log = setup({ summary = false })
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts,summary,goals", joined(log.asked))
  assert(joined(log.saved) == "counts,goals", "saved: " .. joined(log.saved))
  assert(joined(log.told) == "goals", joined(log.told))
end)

check("no cache is fine: nothing is saved, the screen still hears", function()
  local opts, log = setup({ counts = { [2] = 9 } })
  opts.cache = nil
  HomeLoader.refresh(opts)
  assert(#log.saved == 0 and log.told[1] == "counts")
end)

print("\n== the goals are asked for twice when the first answer fails ==")

check("goals missing from the combined answer are asked for once more after a pause", function()
  local opts, log = setup({ goals = false })
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts,summary,goals", joined(log.asked))
  assert(joined(log.slept) == tostring(HomeLoader.GOALS_RETRY_AFTER), "slept: " .. joined(log.slept))
  assert(log.told[#log.told] == "goals" and log.saved[#log.saved] == "goals")
end)

check("goals that fail twice leave the card alone", function()
  local opts, log = setup({ goals = false, retry = false })
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts,summary,goals", joined(log.asked))
  assert(log.told[#log.told] ~= "goals" and log.saved[#log.saved] ~= "goals")
end)

check("goals that arrive first time are not asked for again, and no pause", function()
  local opts, log = setup()
  HomeLoader.refresh(opts)
  assert(#log.slept == 0)
  assert(joined(log.asked) == "counts,summary", joined(log.asked))
end)

check("a screen closed during the pause does not ask again", function()
  local opts, log = setup({ goals = false })
  local dead = false
  opts.sleep = function() dead = true end
  opts.alive = function() return not dead end
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts,summary", joined(log.asked))
  assert(#log.told == 0 or log.told[#log.told] ~= "goals", joined(log.told))
end)

print("\n== when the screen goes away ==")

check("closed before anything: the first request is made, nothing is told or saved", function()
  local opts, log = setup(nil, function() return false end)
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts", joined(log.asked))
  assert(#log.saved == 0 and #log.told == 0)
end)

check("closed after the counts: no further request is made", function()
  -- alive is asked after counts (1), then before reading (2)
  local opts, log = setup(nil, function(n) return n < 2 end)
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts", joined(log.asked))
end)

check("closed during the combined request: nothing in it is saved or told", function()
  local opts, log = setup({ reading = { card(1, 55) } })
  local dead = false
  local summary = opts.api.getHomeSummary
  function opts.api:getHomeSummary(...) dead = true; return summary(self, ...) end
  opts.alive = function() return not dead end
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts,summary", joined(log.asked))
  assert(joined(log.saved) == "counts" and #log.told == 0, joined(log.saved) .. " / " .. joined(log.told))
end)

check("closed during the goals retry: the goals are not applied", function()
  local opts, log = setup({ goals = false })
  local dead = false
  function opts.api:getGoals() log.asked[#log.asked + 1] = "goals"; dead = true; return { { id = 1 } } end
  opts.alive = function() return not dead end
  HomeLoader.refresh(opts)
  assert(joined(log.asked) == "counts,summary,goals", joined(log.asked))
  assert(log.saved[#log.saved] ~= "goals" and log.told[#log.told] ~= "goals", joined(log.saved))
end)

r.finish()
