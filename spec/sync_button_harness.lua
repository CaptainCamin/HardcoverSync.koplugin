-- The "Sync now" menu item is greyed out when there is nothing to sync.
--
-- Loads the real menu with every KOReader module replaced by a permissive
-- stand-in, builds its items, finds the sync item by the one thing only it
-- does -- asking the queue how many changes are pending -- and checks when it
-- is enabled.
--
-- Run with:  lua spec/sync_button_harness.lua [plugin-root]

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

local HardcoverMenu = real_require("hardcover/lib/ui/hardcover_menu")

local pending = 0
local asked = false
local function newMenu(enabled)
  return setmetatable({
    enabled = enabled,
    settings = make(),
    state = { book_status = {} },
    sync_queue = {
      pendingCount = function() asked = true; return pending end,
      hasPending = function() return pending > 0 end,
    },
  }, { __index = HardcoverMenu })
end

-- the item whose label asks the queue how many changes are waiting
local function syncItem(menu)
  for _, item in ipairs(menu:getSubMenuItems(true)) do
    if type(item) == "table" and item.text_func then
      asked = false
      pcall(item.text_func)
      if asked then return item end
    end
  end
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

print("\n== the sync button ==")

check("the sync item is in the menu", function()
  assert(syncItem(newMenu(true)), "no menu item asks the queue for its pending count")
end)

check("greyed out when nothing is pending", function()
  pending = 0
  assert(syncItem(newMenu(true)).enabled_func() == false, "enabled with nothing to sync")
end)

check("enabled when changes are pending", function()
  pending = 2
  assert(syncItem(newMenu(true)).enabled_func() == true, "disabled with changes waiting")
end)

check("greyed out when the plugin is disabled, even with changes pending", function()
  pending = 2
  assert(not syncItem(newMenu(false)).enabled_func(), "enabled while the plugin is disabled")
end)

r.finish()
