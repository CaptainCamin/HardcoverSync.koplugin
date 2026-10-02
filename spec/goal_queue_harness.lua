-- Goal changes made offline: queued in order, shown at once, sent when online.
--
-- Run with:  lua spec/goal_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local Goals = require("hardcover/lib/goals")
local GoalQueue = require("hardcover/lib/goal_queue")

local results = { passed = 0, failed = 0 }
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then results.passed = results.passed + 1 print("  [ok  ] " .. name)
  else results.failed = results.failed + 1 print("  [FAIL] " .. name .. "\n         " .. tostring(err)) end
end
local function eq(a, b, label)
  if a ~= b then error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function newQueue()
  local store = {}
  local settings = {
    store = store,
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v return true end,
    flush = function() return true end,
  }
  return GoalQueue:new { settings = settings }, settings
end

local function saved(id, name, target, progress)
  return Goals.normalize({ { id = id, description = name, goal = target, metric = "book",
    start_date = "2026-01-01", end_date = "2027-01-01", progress = progress or 0 } })[1]
end

local function form(over)
  local f = { name = "Goal", metric = "book", target = 12, start_date = "2026-01-01", end_date = "2027-01-01" }
  for k, v in pairs(over or {}) do f[k] = v end
  return f
end

-- An API double: records every write, answers from `answers`.
local function fakeApi()
  local api = { writes = {}, next_id = 100 }
  function api:saveGoal(id, input)
    self.writes[#self.writes + 1] = { op = "save", id = id, input = input }
    if self.fail then return nil, self.fail end
    local goal_id = id or self.next_id
    if not id then self.next_id = self.next_id + 1 end
    return saved(goal_id, input.description, input.goal, 3)
  end
  function api:archiveGoal(goal)
    local id = goal.id
    self.writes[#self.writes + 1] = { op = "archive", id = id, goal = goal }
    if self.fail then return nil, self.fail end
    return true
  end
  return api
end

print("\n== queueing and showing ==")

check("an edit shows at once, keeps its progress, and is marked as waiting", function()
  local q = GoalQueue:new { settings = select(2, newQueue()) }
  local base = saved(7, "Old", 10, 4)
  local shown = q:queueSave(form({ id = 7, name = "New", target = 20 }), base)
  eq(shown.name, "New"); eq(shown.target, 20); eq(shown.progress, 4, "progress kept"); eq(shown.pending, true)
  local list = q:apply({ base, saved(8, "Other", 5) })
  eq(#list, 2); eq(list[1].name, "New", "edit laid over the saved goal"); eq(list[1].pending, true)
  eq(list[2].pending, nil, "an untouched goal is not marked")
end)

check("a new goal gets a local key, is added, and is made once however often it is edited", function()
  local q = newQueue()
  local g = q:queueSave(form({ name = "A" }))
  eq(GoalQueue.isLocal(g.id), true, "local key")
  q:queueSave(form({ id = g.id, name = "B" }))
  eq(q:count(), 1, "one op")
  local list = q:apply({})
  eq(#list, 1); eq(list[1].name, "B"); eq(list[1].progress, 0)
  local g2 = q:queueSave(form({ name = "C" }))
  eq(g2.id ~= g.id, true, "keys differ")
end)

check("an archive hides the goal, and drops an edit waiting for it", function()
  local q = newQueue()
  q:queueSave(form({ id = 7, name = "Edit" }), saved(7, "Old", 10))
  q:queueArchive(7, saved(7, "Old", 10))
  eq(q:count(), 1, "one op: the archive")
  eq(q:find(7).kind, "archive")
  eq(#q:apply({ saved(7, "Old", 10), saved(8, "Keep", 5) }), 1)
end)

check("archiving a goal made here and never sent leaves nothing", function()
  local q = newQueue()
  local g = q:queueSave(form({ name = "Draft" }))
  q:queueArchive(g.id)
  eq(q:isEmpty(), true)
end)

check("malformed contents do not break it", function()
  local q, settings = newQueue()
  settings.store.goal_ops = { 5, "x", { key = 1, kind = "nonsense" }, { key = 7, kind = "archive" } }
  eq(q:count(), 1)
  eq(#q:apply({ saved(7, "A", 5) }), 0)
  settings.store.goal_ops = "garbage"
  eq(q:count(), 0)
end)

print("\n== sending ==")

check("ops are sent in order, a new goal as a make, and cleared", function()
  local q = newQueue()
  local api = fakeApi()
  q:queueSave(form({ id = 7, name = "Edit", target = 20 }), saved(7, "Old", 10))
  local g = q:queueSave(form({ name = "Fresh" }))
  q:queueArchive(9, saved(9, "To go", 8))
  local sent, archived = {}, {}
  local r = q:flush(api, { on_saved = function(key, goal) sent[#sent + 1] = { key = key, goal = goal } end,
    on_archived = function(key) archived[#archived + 1] = key end })
  eq(r.sent, 3); eq(r.waiting, 0); eq(r.stopped, false)
  eq(api.writes[1].id, 7, "edit goes to its id"); eq(api.writes[1].input.goal, 20)
  eq(api.writes[2].id, nil, "a new goal is a make"); eq(api.writes[2].input.description, "Fresh")
  eq(api.writes[3].op, "archive")
  eq(api.writes[3].goal.name, "To go", "an archive carries the whole goal (Hardcover requires it)")
  eq(api.writes[3].goal.target, 8)
  eq(sent[2].key, g.id, "the caller learns the local key"); eq(sent[2].goal.id, 100, "and the real id")
  eq(archived[1], 9)
  eq(q:isEmpty(), true)
end)

check("no answer stops the flush and keeps everything for next time", function()
  local q = newQueue()
  local api = fakeApi()
  api.fail = { completed = false }
  q:queueSave(form({ id = 7 }), saved(7, "A", 5))
  q:queueSave(form({ id = 8 }), saved(8, "B", 5))
  local r = q:flush(api, {})
  eq(r.stopped, true); eq(r.waiting, 2); eq(#api.writes, 1, "stopped at the first")
  eq(q:heldCount(), 0, "an outage is not a refusal")
  api.fail = { status = 503 }
  eq(q:flush(api, {}).stopped, true, "a 5xx is an outage too")
end)

check("a refusal is counted, the rest go on, and after three it is held", function()
  local q = newQueue()
  local api = fakeApi()
  local real = api.saveGoal
  api.saveGoal = function(self, id, input)
    if id == 7 then self.writes[#self.writes + 1] = { op = "save", id = id } return nil, "Goal is not valid" end
    return real(self, id, input)
  end
  q:queueSave(form({ id = 7 }), saved(7, "Bad", 5))
  q:queueSave(form({ id = 8 }), saved(8, "Good", 5))
  local r = q:flush(api, {})
  eq(r.sent, 1, "the good one went"); eq(r.waiting, 1)
  q:flush(api, {}); q:flush(api, {})
  eq(q:heldCount(), 1, "held after three refusals")
  local before = #api.writes
  q:flush(api, {})
  eq(#api.writes, before, "a held op is not sent again")
  eq(q:apply({ saved(7, "Bad", 5) })[1].held, true, "shown as not sent")
  q:retryHeld()
  eq(q:heldCount(), 0)
end)

check("a refusal for the permission is held at once, to sign in again", function()
  local q = newQueue()
  local api = fakeApi()
  api.fail = { status = 403 }
  q:queueSave(form({ id = 7 }), saved(7, "A", 5))
  eq(q:flush(api, {}).held, 1)
  eq(q:find(7).reason, "scope")
end)

check("a change made while the flush was in flight is not lost", function()
  local q = newQueue()
  local api = fakeApi()
  local real = api.saveGoal
  api.saveGoal = function(self, id, input)
    q:queueSave(form({ id = id, name = "Newer", target = 99 }), saved(id, "x", 5))
    return real(self, id, input)
  end
  q:queueSave(form({ id = 7, name = "Older" }), saved(7, "A", 5))
  q:flush(api, {})
  eq(q:count(), 1, "the newer edit is still waiting")
  eq(q:find(7).form.target, 99)
end)

check("a goal made here, edited while it was being sent, follows its real id", function()
  local q = newQueue()
  local api = fakeApi()
  local real = api.saveGoal
  local g = q:queueSave(form({ name = "Fresh" }))
  api.saveGoal = function(self, id, input)
    if id == nil then q:queueSave(form({ id = g.id, name = "Edited" }), g) end
    return real(self, id, input)
  end
  q:flush(api, {})
  eq(q:count(), 1)
  eq(q:find(100) ~= nil, true, "the waiting edit now targets the real id")
  local r = q:flush(real and fakeApi() or api, {})
  eq(r.waiting, 0)
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
