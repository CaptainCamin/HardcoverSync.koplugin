--[[--
Making and changing goals with no connection: an edit and a new goal are kept on
the device, show at once on the screens marked "Waiting to sync", send nothing, and
go to Hardcover when the sync runs (the new goal under its real id, afterwards).

Screens: goal_offline_list, goal_synced.
]]

local fixtures = require("fixtures")
local Goals = require("hardcover/lib/goals")
local UIManager = require("ui/uimanager")

-- the topmost window that is not a toast (the "saved on this device" notice floats above)
local function top()
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    if w and not w.toast then return w end
  end
end

local function find_button(root, label, seen)
  seen = seen or {}
  if type(root) ~= "table" or seen[root] then return end
  seen[root] = true
  if root.text == label and root.callback and root.dimen and root.dimen.w and root.dimen.w > 0 then return root end
  for _, child in pairs(root) do
    local found = find_button(child, label, seen)
    if found then return found end
  end
end

-- the toast times out on a device; here nothing advances time, and it would be
-- the only thing emu:expectText reads
local function drop_toasts(emu)
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    if w and w.toast then UIManager:close(w) end
  end
  emu:pump()
end

local function tap_button(emu, label)
  emu:screenNodes()
  local b = find_button(top(), label)
  assert(b, "no button '" .. label .. "' on top (" .. tostring(top() and top().name) .. "):\n" .. emu:screenText())
  emu:tapExpecting(b.dimen.x + math.floor(b.dimen.w / 2), b.dimen.y + math.floor(b.dimen.h / 2))
  emu:pump()
end

local function tap_row(emu, form, key)
  emu:screenNodes()
  local row = form.row_taps[key]
  assert(row and row.dimen, "no row " .. key)
  emu:tapExpecting(row.dimen.x + math.floor(row.dimen.w / 2), row.dimen.y + math.floor(row.dimen.h / 2))
  emu:pump()
end

local function writes(name)
  local out = {}
  for _, c in ipairs(fixtures.calls) do if c.name == name then out[#out + 1] = c.args end end
  return out
end

local function text_count(emu, needle)
  local n = 0
  for _, node in ipairs(emu:screenNodes()) do
    if node.text:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

return {
  name = "goal_offline",

  run = function(emu)
    local Api = require("hardcover/lib/hardcover_api")
    local NetworkManager = require("ui/network/manager")
    local settings = fixtures.real_settings(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)

    local today = Goals.today()
    local rows = {
      { id = 3, goal = 70, metric = "book", description = "Existing Reading Goal",
        start_date = Goals.dateString(today - 200), end_date = Goals.dateString(today + 165), progress = 46.0,
        archived = false, privacy_setting_id = 1 },
    }
    fixtures.install({ settings = settings, goals_rows = rows })
    Api.auth = fixtures.fake_auth(true)

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local GoalQueue = require("hardcover/lib/goal_queue")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_goal_offline.lua"
    os.remove(path)
    local queue = GoalQueue:new { settings = { readSetting = function(self, k) return self[k] end,
      saveSetting = function(self, k, v) self[k] = v end, flush = function() end } }
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      sync_queue = { finishedCount = function() return 0 end },
      goal_queue = queue,
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
    }

    -- online first, so the goal is saved on the device
    manager:showGoals()
    emu:pump()
    emu:expectText("Existing Reading Goal")
    emu:expectText("of 70 books")

    -- offline in both of the plugin's checks
    local was = NetworkManager.isConnected
    local was_state = NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end

    -- ------------------------------------------------------------ edit, offline
    manager:showGoal(manager:savedGoals()[1], nil)
    emu:pump()
    tap_button(emu, "Edit goal")
    local form = top()
    assert(form.name == "hardcover_goal_form", "Edit did not open the form")
    tap_row(emu, form, "target")
    top():setInputText("80")
    tap_button(emu, "Set")
    tap_button(emu, "Save")
    assert(#writes("saveGoal") == 0, "an offline save was sent")
    assert(queue:count() == 1, "the edit was not kept: " .. queue:count())
    emu:expectText("Saved on this device")
    drop_toasts(emu)
    local one = top()
    assert(one and one.name == "hardcover_goal", "the form did not close onto the goal: " .. tostring(one and one.name))
    emu:expectText("of 80 books")
    emu:expectText("Waiting to sync")
    assert(manager:savedGoals()[1].target == 70, "the saved copy took the unsent edit")

    -- ------------------------------------------------------------ new goal, offline
    UIManager:close(one)
    emu:pump()
    manager:showGoals()
    emu:pump()
    emu:expectText("of 80 books")
    tap_button(emu, "New goal")
    tap_button(emu, "Save")
    assert(#writes("saveGoal") == 0, "an offline new goal was sent")
    assert(queue:count() == 2, "the new goal was not kept: " .. queue:count())
    drop_toasts(emu)
    local screen = top()
    assert(screen and screen.name == "hardcover_goals", "the form did not close onto the Goals screen: " .. tostring(screen and screen.name))
    assert(text_count(emu, "Waiting to sync") == 2, "both changes should say they are waiting")
    emu:shot("goal_offline_list")
    assert(#manager:savedGoals() == 1, "the saved copy took the unsent goal")

    -- ------------------------------------------------------------ the sync
    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state
    local sent, archived = {}, {}
    local result = queue:flush(Api, {
      on_saved = function(key, goal) sent[#sent + 1] = { key = key, goal = goal } end,
      on_archived = function(key) archived[#archived + 1] = key end,
    })
    manager:goalsFlushed(sent, archived)
    emu:pump()
    local w = writes("saveGoal")
    assert(#w == 2 and w[1].id == 3 and w[1].input.goal == 80 and w[2].id == nil, "what was sent is wrong")
    assert(result.waiting == 0 and queue:isEmpty(), "something is still waiting")
    assert(text_count(emu, "Waiting to sync") == 0, "still marked as waiting after the sync")
    local saved = manager:savedGoals()
    assert(#saved == 2 and saved[1].target == 80, "the saved copy is not up to date")
    assert(type(saved[2].id) == "number", "the new goal kept its local key")
    emu:shot("goal_synced")
    emu:closeAll()
  end,
}
