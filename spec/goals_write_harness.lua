-- Making, changing and archiving goals: the requests Api:saveGoal and Api:archiveGoal
-- send (against a stubbed Api:query), how an answer is read -- including the ones that
-- are not what was hoped for -- and the account's visibility being looked up only for
-- a new goal that has none.
--
-- Run with:  lua spec/goals_write_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

package.preload["ui/uimanager"] = function()
  return { show = function() end, close = function() end, isWidgetShown = function() return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    forceRePaint = function() end, nextTick = function() end }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) local co = coroutine.create(fn); local ok, err = coroutine.resume(co)
    if not ok then error("wrapped function raised: " .. tostring(err), 0) end end }
end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local Api = real_require("hardcover/lib/hardcover_api")
local Goals = real_require("hardcover/lib/goals")
local Lists = real_require("hardcover/lib/lists")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- a scripted Api:query: each call takes the next answer, and every request is kept
local sent, script
local function answers(...)
  Api.enabled = true
  sent, script = {}, { ... }
  Api.query = function(_, q, vars)
    sent[#sent + 1] = { q = q, vars = vars }
    local a = table.remove(script, 1) or {}
    return a.result, a.err
  end
end
local vim_null = nil
local function ok(result) return { result = result } end
local function fail(err) return { err = err } end

local function goal_row(over)
  local g = { id = 42, goal = 30, metric = "book", description = "My goal", start_date = "2026-01-01",
    end_date = "2027-01-01", progress = 5.0, archived = false, privacy_setting_id = 1 }
  for k, v in pairs(over or {}) do g[k] = v end
  return g
end

local INPUT = { description = "My goal", metric = "book", goal = 30, start_date = "2026-01-01",
  end_date = "2027-01-01", privacy_setting_id = 3 }

print("\n== making a goal ==")

check("a new goal is one insert_goal with the input, then a recount; the recount's goal is returned", function()
  answers(ok({ insert_goal = { id = 42, goal = goal_row({ progress = 0 }) } }),
          ok({ update_goal_progress = { id = 42, goal = goal_row({ progress = 12.0 }) } }))
  local goal, err = Api:saveGoal(nil, INPUT)
  assert(goal and not err, tostring(err))
  assert(#sent == 2, "requests: " .. #sent)
  assert(sent[1].q:find("insert_goal(object: $object)", 1, true) and sent[1].vars.object.goal == 30
    and sent[1].vars.object.privacy_setting_id == 3 and sent[1].vars.id == nil)
  assert(sent[2].q:find("update_goal_progress(id: $id)", 1, true) and sent[2].vars.id == 42)
  assert(goal.id == 42 and goal.progress == 12 and goal.target == 30 and goal.name == "My goal" and goal.privacy_setting_id == 1)
end)

check("a new goal with no visibility takes the account's, looked up once", function()
  local input = { description = "G", metric = "book", goal = 12, start_date = "2026-01-01", end_date = "2027-01-01" }
  answers(ok({ me = { { id = 7, account_privacy_setting_id = 3 } } }),
          ok({ insert_goal = { id = 5, goal = goal_row({ id = 5, privacy_setting_id = 3 }) } }),
          ok({ update_goal_progress = { id = 5 } }))
  local goal = Api:saveGoal(nil, input)
  assert(goal, "not saved")
  assert(#sent == 3 and sent[1].q:find("account_privacy_setting_id", 1, true), "the account's setting was not asked for first")
  assert(sent[2].vars.object.privacy_setting_id == 3, "the account's private setting was not used")
  assert(input.privacy_setting_id == nil, "the caller's input must not be changed")
  -- the account's setting could not be read: public is the fallback
  answers(ok({}), ok({ insert_goal = { id = 5, goal = goal_row({ id = 5 }) } }), ok({}))
  Api:saveGoal(nil, input)
  assert(sent[2].vars.object.privacy_setting_id == 1)
end)

check("changing a goal is one update_goal for its id, and does not ask for the account's visibility", function()
  answers(ok({ update_goal = { id = 42, goal = goal_row({ goal = 40 }) } }), ok({ update_goal_progress = { id = 42, goal = goal_row({ goal = 40, progress = 9.0 }) } }))
  local goal = Api:saveGoal(42, { description = "My goal", metric = "book", goal = 40, start_date = "2026-01-01", end_date = "2027-01-01" })
  assert(goal and goal.target == 40 and goal.progress == 9)
  assert(#sent == 2 and sent[1].q:find("update_goal(id: $id, object: $object)", 1, true))
  assert(sent[1].vars.id == 42 and sent[1].vars.object.goal == 40 and sent[1].vars.object.privacy_setting_id == nil)
  assert(not sent[1].q:find("account_privacy_setting_id", 1, true))
end)

check("only fields the API's GoalIdType has are asked for", function()
  answers(ok({ insert_goal = { id = 1 } }), ok({}))
  Api:saveGoal(nil, INPUT)
  local selection = sent[1].q:match("insert_goal%(object: %$object%)%s*(%b{})")
  assert(selection)
  -- GoalIdType is { errors, goal, id }
  local top = selection:gsub("goal%s*%b{}", "")
  for word in top:gmatch("[%a_]+") do
    assert(word == "id" or word == "errors", "selects a field GoalIdType does not have: " .. word)
  end
end)

print("\n== when it does not go well ==")

check("a refusal for the missing scope comes back as the error, and nothing else is sent", function()
  answers(fail({ errors = { "insufficient_scope" }, status = 403 }))
  local goal, err = Api:saveGoal(42, INPUT)
  assert(goal == nil and Lists.isScopeError(err), "the scope refusal was lost")
  assert(#sent == 1)
end)

check("Hardcover's own error text is returned as it is", function()
  answers(ok({ insert_goal = { errors = "End date must be after start date" } }))
  local goal, err = Api:saveGoal(nil, INPUT)
  assert(goal == nil and err == "End date must be after start date")
  assert(#sent == 1, "no recount for a goal that was not saved")
end)

check("junk answers are nil with an error, never a crash", function()
  for _, junk in ipairs({ {}, { insert_goal = "x" }, { insert_goal = false }, { insert_goal = {} }, { other = 1 } }) do
    answers(ok(junk))
    local goal, err = Api:saveGoal(nil, INPUT)
    assert(goal == nil and err, "a junk answer counted as saved")
  end
  answers(fail({ completed = false }))
  local goal, err = Api:saveGoal(nil, INPUT)
  assert(goal == nil and err.completed == false)
end)

check("if the recount fails the goal is still saved, with the number it had", function()
  answers(ok({ insert_goal = { id = 42, goal = goal_row({ progress = 3.0 }) } }), fail({ completed = false }))
  local goal = Api:saveGoal(nil, INPUT)
  assert(goal and goal.id == 42 and goal.progress == 3)
  answers(ok({ insert_goal = { id = 42, goal = goal_row({ progress = 3.0 }) } }), ok({ update_goal_progress = { errors = "nope" } }))
  goal = Api:saveGoal(nil, INPUT)
  assert(goal and goal.progress == 3, "a recount that reported an error replaced the saved goal")
end)

check("an answer with only an id still gives a goal, built from what was sent", function()
  answers(ok({ insert_goal = { id = 77 } }), ok({}))
  local goal = Api:saveGoal(nil, INPUT)
  assert(goal and goal.id == 77 and goal.target == 30 and goal.name == "My goal" and goal.progress == 0
    and goal.start_date == "2026-01-01" and goal.privacy_setting_id == 3)
end)

check("an update that comes back with goal: null reads the goal back, so its progress is real", function()
  -- what the real API does (seen with a real write): update_goal and update_goal_progress
  -- answer { id, errors, goal = null }
  answers(ok({ update_goal = { id = 42, errors = vim_null } }), ok({ update_goal_progress = { id = 42 } }),
    ok({ me = { { goals = { goal_row({ id = 42, goal = 31, progress = 9.0 }) } } } }))
  local goal = Api:saveGoal(42, INPUT)
  assert(goal and goal.id == 42 and goal.progress == 9 and goal.target == 31, "progress was " .. tostring(goal and goal.progress))
  assert(#sent == 3 and sent[3].vars.id == 42, "the goal was not read back")
  -- and when even that fails, what was sent is shown, not nothing
  answers(ok({ update_goal = { id = 42 } }), ok({ update_goal_progress = { id = 42 } }), fail({ completed = false }))
  goal = Api:saveGoal(42, INPUT)
  assert(goal and goal.id == 42 and goal.target == 30, "no fallback")
end)

print("\n== archiving ==")

-- Hardcover's GoalInput requires all of these on every insert_goal AND update_goal
-- (found by sending a real insert: "missing required field 'conditions'"; the
-- introspected type marks them all NON_NULL). Sending less fails on the real API.
local REQUIRED = { "description", "metric", "goal", "start_date", "end_date", "conditions" }

local function assertComplete(object, what)
  for _, key in ipairs(REQUIRED) do
    assert(object[key] ~= nil, what .. " is missing the required field " .. key)
  end
  assert(type(object.conditions) == "table", what .. ": conditions is not an object")
end

check("archiving sends the whole goal with archived set (the API requires every field)", function()
  answers(ok({ update_goal = { id = 42 } }))
  local goal = { id = 42, name = "Old", metric = "book", target = 12, start_date = "2026-01-01",
    end_date = "2027-01-01", privacy_setting_id = 1,
    conditions = { bookCategoryIds = { 5 }, goal = "12", startDate = "2026-01-01" } }
  assert(Api:archiveGoal(goal) == true)
  assert(sent[1].vars.id == 42)
  local object = sent[1].vars.object
  assertComplete(object, "the archive")
  assert(object.archived == true and object.description == "Old" and object.goal == 12)
  assert(object.conditions.bookCategoryIds and object.conditions.bookCategoryIds[1] == 5,
    "the goal's own conditions were not kept")
  assert(object.conditions.goal == nil and object.conditions.startDate == nil,
    "conditions the API does not accept were sent")
  assert(#sent == 1)
end)

check("every goal request carries the required fields", function()
  answers(ok({ insert_goal = { id = 77 } }), ok({}))
  Api:saveGoal(nil, INPUT)
  assertComplete(sent[1].vars.object, "a new goal")
  answers(ok({ update_goal = { id = 42 } }), ok({}))
  Api:saveGoal(42, INPUT)
  assertComplete(sent[1].vars.object, "an edit")
end)

check("an archive that failed is nil with the reason", function()
  answers(ok({ update_goal = { errors = "Goal not found" } }))
  local g = { id = 42, name = "Old", metric = "book", target = 12, start_date = "2026-01-01", end_date = "2027-01-01" }
  local out, err = Api:archiveGoal(g)
  assert(out == nil and err == "Goal not found")
  answers(fail({ errors = { "insufficient_scope" }, status = 403 }))
  out, err = Api:archiveGoal(g)
  assert(out == nil and Lists.isScopeError(err))
  answers(ok({}))
  assert(Api:archiveGoal(g) == nil)
end)

print("\n== the permission ==")

check("sign-in asks for write:goals (and still for what it had)", function()
  for _, file in ipairs({ "hardcover/lib/auth.lua", "hardcover/lib/default_config.lua" }) do
    local f = assert(io.open(PLUGIN .. "/" .. file)); local src = f:read("*a"); f:close()
    local scope = src:match('scope = "([^"]+)"') or src:match('DEFAULT_SCOPE = "([^"]+)"')
    assert(scope, file .. ": no scope line")
    local padded = " " .. scope .. " "
    for _, want in ipairs({ Goals.WRITE_SCOPE, "write:library", "read:social", "read:users" }) do
      assert(padded:find(" " .. want .. " ", 1, true), file .. " does not request " .. want)
    end
  end
end)

r.finish()
