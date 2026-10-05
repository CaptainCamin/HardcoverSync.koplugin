-- Where a goal change goes (send, hold, refuse), what a failed write says, and how
-- the saved goals follow a sync; and the saved-copy-then-refresh policy the Goals
-- and Stats screens share. No KOReader.
--
-- Run with:  lua spec/goal_actions_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local GoalActions = require("hardcover/lib/goal_actions")
local ScreenLoad = require("hardcover/lib/screen_load")

local function queue(pending)
  return { pendingFor = function(_, id) return pending[id] == true end }
end

print("\n== where a change goes ==")

check("a sign-in without the permission is told to sign in again, whatever else is true", function()
  assert(GoalActions.route { scope_missing = true, queue = queue({}), connected = true, goal_id = 1 } == "sign_in")
  assert(GoalActions.route { scope_missing = true, queue = nil, connected = false, goal_id = 1 } == "sign_in")
end)

check("online with nothing waiting, a change is sent", function()
  assert(GoalActions.route { queue = queue({}), connected = true, goal_id = 1 } == "send")
end)

check("online with no queue at all, a change is sent", function()
  assert(GoalActions.route { queue = nil, connected = true, goal_id = 1 } == "send")
end)

check("offline with a queue, a change is held", function()
  assert(GoalActions.route { queue = queue({}), connected = false, goal_id = 1 } == "queue")
end)

check("offline with no queue, a change is turned away", function()
  assert(GoalActions.route { queue = nil, connected = false, goal_id = 1 } == "offline")
end)

check("a goal with a change already waiting holds the next one, even online", function()
  assert(GoalActions.route { queue = queue({ [5] = true }), connected = true, goal_id = 5 } == "queue")
end)

check("a goal made offline has no id on Hardcover yet, so its edits are held", function()
  assert(GoalActions.route { queue = queue({}), connected = true, goal_id = "local:abc" } == "queue")
end)

check("a new goal (no id) goes straight out when online", function()
  assert(GoalActions.route { queue = queue({}), connected = true, goal_id = nil } == "send")
end)

print("\n== what a failed write says ==")

check("a refusal for the permission says to sign in again", function()
  assert(GoalActions.problem({ status = 403 }) == GoalActions.SIGN_IN_AGAIN)
  assert(GoalActions.problem("Missing scope write:goals") == GoalActions.SIGN_IN_AGAIN)
end)

check("Hardcover's own words are passed on, ending in a full stop", function()
  assert(GoalActions.problem("Goal name is taken") == "Goal name is taken.")
  assert(GoalActions.problem("Nope!  ") == "Nope!")
end)

check("no answer, or junk, is 'did not answer'", function()
  assert(GoalActions.problem(nil) == "Hardcover did not answer.")
  assert(GoalActions.problem("") == "Hardcover did not answer.")
  assert(GoalActions.problem({ foo = 1 }) == "Hardcover did not answer.")
end)

print("\n== the saved goals after a sync ==")

check("a goal made here takes its real id, in place of the local one", function()
  local goals = { { id = 1, name = "a" }, { id = "local:x", name = "draft" } }
  local out = GoalActions.afterFlush(goals, { { key = "local:x", goal = { id = 9, name = "draft" } } }, {})
  local ids = {}
  for _, g in ipairs(out) do ids[#ids + 1] = tostring(g.id) end
  assert(table.concat(ids, ",") == "1,9", table.concat(ids, ","))
end)

check("an edit replaces the goal with the same id", function()
  local out = GoalActions.afterFlush({ { id = 1, name = "old" } }, { { key = 1, goal = { id = 1, name = "new" } } }, {})
  assert(#out == 1 and out[1].name == "new")
end)

check("archived goals are gone", function()
  local out = GoalActions.afterFlush({ { id = 1 }, { id = 2 } }, {}, { 1 })
  assert(#out == 1 and out[1].id == 2)
end)

check("nothing sent leaves the goals as they are", function()
  local goals = { { id = 1 } }
  assert(GoalActions.afterFlush(goals, {}, {}) == goals)
end)

print("\n== the saved copy, then the refresh ==")

check("what is shown first", function()
  assert(ScreenLoad.start({}, true) == "saved")
  assert(ScreenLoad.start({}, false) == "saved_offline")
  assert(ScreenLoad.start(nil, true) == "loading")
  assert(ScreenLoad.start(nil, false) == "needs_network")
end)

check("an empty saved copy still counts as saved", function()
  assert(ScreenLoad.start({}, true) == "saved")
end)

check("what is done with the answer", function()
  assert(ScreenLoad.finish({ 1 }, nil) == "fresh")
  assert(ScreenLoad.finish({ 1 }, { 2 }) == "fresh")
  assert(ScreenLoad.finish(nil, { 2 }) == "stale")
  assert(ScreenLoad.finish(nil, nil) == "retry")
end)

r.finish()
