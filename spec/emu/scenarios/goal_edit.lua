--[[--
Making, changing and archiving goals, driven with real taps: Goals > New goal, the
rows of the form (name, counting, target, period, visibility), checking before saving,
the save and what it sends, editing from the goal screen, archiving, and the ways a
save can go wrong (offline, no permission, Hardcover says no) -- each keeping what was
typed. Hardcover is a stand-in that records what is sent.

Screens: goal_form_new, goal_form_error, goal_form_edit, goal_form_failed, goals_after_save.
]]

local fixtures = require("fixtures")
local Goals = require("hardcover/lib/goals")
local UIManager = require("ui/uimanager")

local function top() return UIManager:getTopmostVisibleWidget() end

-- a widget under `root` with this text that can be tapped (a button), painted first
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

return {
  name = "goal_edit",

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
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_goal_edit.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      sync_queue = { finishedCount = function() return 0 end },
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
    }

    -- ------------------------------------------------------------------ New goal
    manager:showGoals()
    emu:pump()
    emu:expectText("Existing Reading Goal")
    tap_button(emu, "New goal")
    local form = top()
    assert(form and form.name == "hardcover_goal_form" and not form.goal, "New goal did not open the form: " .. tostring(form and form.name))
    for _, label in ipairs({ "New goal", "Name", "Counting", "Target", "Period", "Visible to", "Same as your account", "12 books", "Save", "Cancel" }) do
      emu:expectText(label)
    end
    for _, node in ipairs(emu:screenNodes()) do
      assert(node.text ~= "Archive this goal", "a new goal offers Archive")
    end
    emu:shot("goal_form_new")

    -- the target: a text box; a number sets it
    tap_row(emu, form, "target")
    local input = top()
    assert(input and input.getInputText, "the target row did not open a text box: " .. tostring(input and input.name))
    input:setInputText("20")
    tap_button(emu, "Set")
    assert(form.form.target == 20, "target is " .. tostring(form.form.target))
    emu:expectText("20 books")

    -- what is counted: a list of two
    tap_row(emu, form, "metric")
    emu:expectText("Books")
    emu:expectText("Pages")
    tap_button(emu, "Pages")
    assert(form.form.metric == "page")
    emu:expectText("20 pages")

    -- the period: presets, and the name follows while it is still a preset's name
    local presets = Goals.presets(today)
    assert(form.form.name == presets[1].name)
    tap_row(emu, form, "period")
    emu:expectText(presets[3].label)
    emu:expectText("Choose dates")
    tap_button(emu, presets[3].label)
    assert(form.form.start_date == presets[3].start_date and form.form.end_date == presets[3].end_date, "the period did not change")
    assert(form.form.name == presets[3].name, "the name did not follow the period")

    -- a target that is not a whole number cannot be saved: Save says why, sends nothing
    tap_row(emu, form, "target")
    top():setInputText("0")
    tap_button(emu, "Set")
    tap_button(emu, "Save")
    emu:expectText("The target must be a whole number, at least 1.")
    assert(#writes("saveGoal") == 0, "an invalid goal was sent")
    emu:shot("goal_form_error")

    -- fixed: Save sends the goal once, and the form closes on the Goals screen
    tap_row(emu, form, "target")
    top():setInputText("25")
    tap_button(emu, "Set")
    emu:expectText("25 pages")
    tap_button(emu, "Save")
    local sent = writes("saveGoal")
    assert(#sent == 1, "saves sent: " .. #sent)
    assert(sent[1].id == nil, "a new goal was sent as a change")
    local input_sent = sent[1].input
    assert(input_sent.description == presets[3].name and input_sent.metric == "page" and input_sent.goal == 25
      and input_sent.start_date == presets[3].start_date and input_sent.end_date == presets[3].end_date,
      "wrong request")
    assert(input_sent.privacy_setting_id == nil, "visibility was chosen for the reader")
    local screen = top()
    assert(screen and screen.name == "hardcover_goals", "the form did not close onto the Goals screen: " .. tostring(screen and screen.name))
    emu:expectText(presets[3].name)
    emu:expectText("of 25 pages")
    -- and the saved copy has it, for offline
    local saved = manager:savedGoals()
    assert(#saved == 2, "saved goals: " .. #saved)
    emu:shot("goals_after_save")

    -- ------------------------------------------------------------------ Edit
    local new_goal
    for _, g in ipairs(saved) do if g.name == presets[3].name then new_goal = g end end
    assert(new_goal and new_goal.target == 25)
    manager:showGoal(new_goal, nil)
    emu:pump()
    emu:expectText("Edit goal")
    tap_button(emu, "Edit goal")
    form = top()
    assert(form.name == "hardcover_goal_form" and form.goal and form.goal.id == new_goal.id, "Edit did not open the goal's form")
    emu:expectText("25 pages")
    emu:expectText("Archive this goal")
    emu:shot("goal_form_edit")

    -- a failed save keeps the form and what was typed, and says why
    tap_row(emu, form, "target")
    top():setInputText("30")
    tap_button(emu, "Set")
    fixtures.goal_write_fail = "End date is in the past"
    tap_button(emu, "Save")
    assert(top() == form, "the form closed on a failed save")
    emu:expectText("Couldn't save the goal: End date is in the past. Your changes are kept.")
    emu:expectText("30 pages")
    emu:shot("goal_form_failed")

    -- a refusal for the permission says to sign in again
    fixtures.goal_write_fail = { errors = { "insufficient_scope" }, status = 403 }
    tap_button(emu, "Save")
    emu:expectText("Sign out and back in")
    fixtures.goal_write_fail = nil

    -- a sign-in known to lack the permission sends nothing at all
    local before = #writes("saveGoal")
    Api.auth = fixtures.fake_auth(false)
    tap_button(emu, "Save")
    emu:expectText("Sign out and back in")
    assert(#writes("saveGoal") == before, "sent a save without the permission")
    Api.auth = fixtures.fake_auth(true)

    -- offline: the form is kept, nothing is sent
    local was = NetworkManager.isConnected
    NetworkManager.isConnected = function() return false end
    -- the plugin also trusts KOReader's own record of the connection, so go offline in both
    local was_state = NetworkManager.getConnectionState
    NetworkManager.getConnectionState = function() return false end
    tap_button(emu, "Save")
    emu:expectText("You're offline")
    assert(#writes("saveGoal") == before, "sent a save while offline")
    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state

    -- online again: it saves, as a change to that goal, and the goal screen shows it
    tap_button(emu, "Save")
    sent = writes("saveGoal")
    assert(#sent == before + 1 and sent[#sent].id == new_goal.id and sent[#sent].input.goal == 30, "the change was not sent")
    local one = top()
    assert(one and one.name == "hardcover_goal", "the form did not close onto the goal: " .. tostring(one and one.name))
    emu:expectText("of 30 pages")

    -- ------------------------------------------------------------------ Cancel
    tap_button(emu, "Edit goal")
    form = top()
    tap_row(emu, form, "target")
    top():setInputText("99")
    tap_button(emu, "Set")
    tap_button(emu, "Cancel")
    emu:expectText("Discard your changes?")
    tap_button(emu, "Discard")
    assert(top().name == "hardcover_goal", "Discard did not close the form")
    assert(#writes("saveGoal") == before + 1, "a cancelled form was sent")

    -- ------------------------------------------------------------------ Archive
    tap_button(emu, "Edit goal")
    form = top()
    tap_button(emu, "Archive this goal")
    emu:expectText("Archive this goal?")
    tap_button(emu, "Archive")
    local archived = writes("archiveGoal")
    assert(#archived == 1 and archived[1].id == new_goal.id, "the goal was not archived")
    -- the form and the goal's own screen are gone; the Goals screen no longer lists it
    assert(top().name == "hardcover_goals", "after archiving, top is " .. tostring(top().name))
    for _, node in ipairs(emu:screenNodes()) do
      assert(not node.text:find(presets[3].name, 1, true), "an archived goal is still listed")
    end
    assert(#manager:savedGoals() == 1, "the saved copy still has the archived goal")

    emu:closeAll()
  end,
}
