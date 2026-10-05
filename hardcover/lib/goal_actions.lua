-- The decisions behind changing a goal, apart from drawing anything.
--
-- A change can be sent now, held here until the connection is back, refused
-- because the sign-in lacks the permission, or turned away because the device is
-- offline. Which of those it is, what the user is told when a write fails, and how
-- the saved goals follow a sync are decided here. The screens (dialog_manager.lua)
-- only act on the answer.
--
-- No KOReader requires beyond gettext, so it runs under stock Lua in the spec suite.

local _ = require("gettext")

local GoalQueue = require("hardcover/lib/goal_queue")
local Goals = require("hardcover/lib/goals")
local Lists = require("hardcover/lib/lists")

local GoalActions = {}

GoalActions.SIGN_IN_AGAIN = _("Sign out and back in (Settings > Account) to change goals.")

--
-- Where a save or an archive goes. `opts`:
--   scope_missing  true when the sign-in is known to lack write:goals
--   queue          the goal queue, or nil (nothing can be held then)
--   connected      whether the device is online
--   goal_id        the goal's id: a number, or "local:..." for one made offline
--
--   "sign_in"  tell the user to sign in again; nothing is sent or held
--   "queue"    hold it here and let the sync send it: offline, or a change to this
--              goal is already waiting (a goal made here has no id on Hardcover yet,
--              and a newer edit must not overtake an older one)
--   "offline"  turn it away, saying the changes are kept in the form (no queue)
--   "send"     send it now
--
function GoalActions.route(opts)
  if opts.scope_missing then return "sign_in" end

  local queue = opts.queue
  local waiting = queue and (GoalQueue.isLocal(opts.goal_id) or queue:pendingFor(opts.goal_id))
  if queue and (not opts.connected or waiting) then return "queue" end
  if not opts.connected then return "offline" end
  return "send"
end

--
-- Why a write failed, in a sentence: a refusal for the permission says to sign in
-- again, Hardcover's own words are passed on, anything else is "no answer".
--
function GoalActions.problem(err)
  if Lists.isScopeError(err) then return GoalActions.SIGN_IN_AGAIN end
  if type(err) == "string" and err ~= "" then
    -- Hardcover's text may or may not end in a full stop, and a sentence follows it
    err = err:gsub("%s+$", "")
    if not err:match("[%.!%?]$") then err = err .. "." end
    return err
  end
  return _("Hardcover did not answer.")
end

--
-- The saved goals after a sync sent some changes: a goal made here has its real id
-- now, and archived ones are gone. `sent` is a list of { key, goal }, `archived` a
-- list of keys.
--
function GoalActions.afterFlush(goals, sent, archived)
  for _i, entry in ipairs(sent) do
    goals = Goals.upsert(Goals.remove(goals, entry.key), entry.goal)
  end
  for _i, key in ipairs(archived) do
    goals = Goals.remove(goals, key)
  end
  return goals
end

return GoalActions
