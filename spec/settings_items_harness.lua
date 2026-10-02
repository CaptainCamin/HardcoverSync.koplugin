-- The settings screen's rows: how menu item tables become Menu rows.
--
-- Run with:  lua spec/settings_items_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local SettingsItems = require("hardcover/lib/settings_items")
local CHECK = "\226\156\147"

local function noop() end

print("\n== rows ==")

check("a ticked option shows a tick, an unticked one does not", function()
  local rows = SettingsItems.rows({
    { text = "On", checked_func = function() return true end, callback = noop },
    { text = "Off", checked_func = function() return false end, callback = noop },
  }, noop, noop)
  assert(rows[1].mandatory == CHECK and rows[2].mandatory == nil)
end)

check("text_func is resolved", function()
  local rows = SettingsItems.rows({ { text_func = function() return "Dynamic" end, callback = noop } }, noop, noop)
  assert(rows[1].text == "Dynamic")
end)

check("gated-off (false) items are skipped", function()
  local rows = SettingsItems.rows({ false, { text = "A", callback = noop }, false }, noop, noop)
  assert(#rows == 1 and rows[1].text == "A")
end)

check("choosing an option runs its callback and redraws", function()
  local ran, drawn = false, 0
  local rows = SettingsItems.rows({ { text = "A", callback = function() ran = true end } }, noop, function() drawn = drawn + 1 end)
  rows[1].choose()
  assert(ran and drawn == 1)
end)

check("a callback that asks the menu to update redraws the level", function()
  local drawn = 0
  local rows = SettingsItems.rows({ { text = "A", callback = function(menu) menu:updateItems() end } },
    noop, function() drawn = drawn + 1 end)
  rows[1].choose()
  assert(drawn == 2, "drawn " .. drawn)
end)

check("a disabled item is dimmed and does nothing", function()
  local ran = false
  local rows = SettingsItems.rows({ { text = "A", enabled_func = function() return false end, callback = function() ran = true end } }, noop, noop)
  assert(rows[1].dim == true)
  rows[1].choose()
  assert(not ran, "a disabled item ran")
end)

check("an item with children opens them, under its own title", function()
  local opened_title, opened_items
  local kids = { { text = "kid", callback = noop } }
  local rows = SettingsItems.rows({ { text = "Group", sub_item_table_func = function() return kids end } },
    function(t, items) opened_title, opened_items = t, items end, noop)
  rows[1].choose()
  assert(opened_title == "Group" and opened_items == kids)
  assert(rows[1].mandatory ~= nil, "no sign that it opens")
end)

check("an item without children does not open anything", function()
  local opened = false
  local rows = SettingsItems.rows({ { text = "A", callback = noop } }, function() opened = true end, noop)
  rows[1].choose()
  assert(not opened)
end)

r.finish()
