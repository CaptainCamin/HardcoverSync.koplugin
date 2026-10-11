-- Three fixes to the shell: Home's Sync now is found by a stable key (not the translated label), a
-- failed load's Cancel inside the shell leaves the tab usable, and every queue tells Home's sync box
-- when it saves, so the box does not wait for a sync to update.
--
-- Run with:  lua spec/shell_fixes_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function read(path)
  local f = assert(io.open(PLUGIN .. "/" .. path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

print("\n== Sync now finds its item by key ==")

check("the Sync item carries a key, and Sync now looks for it, not the translated tile", function()
  assert(read("hardcover/lib/ui/hardcover_menu.lua"):find('key = "sync"', 1, true), "no key on the Sync item")
  local dm = read("hardcover/lib/ui/dialog_manager.lua")
  assert(dm:find('item.key == "sync"', 1, true), "syncNow does not match on the key")
  assert(not dm:find('item.tile == "Sync"', 1, true), "syncNow still matches the label")
end)

print("\n== Cancel on a failed load inside the shell ==")

local closed, message
package.preload["ui/uimanager"] = function() return { close = function(_, w) closed = w end } end
package.preload["gettext"] = function() return function(s) return s end end
local Hosted = dofile(PLUGIN .. "/hardcover/lib/ui/hosted.lua")

check("on its own the screen closes", function()
  closed = nil
  local screen = { setMessage = function() message = "set" end }
  Hosted.cancelLoad(screen, nil)()
  assert(closed == screen, "the screen was not closed")
end)

check("in the shell the tab stays and says it did not load", function()
  closed, message = nil, nil
  local screen = { setMessage = function(_, m) message = m end }
  Hosted.cancelLoad(screen, { shell = {} })()
  assert(closed == nil, "a tab was closed")
  assert(message and message:find("Couldn't load"), "no message: " .. tostring(message))
end)

check("every load's Cancel goes through it", function()
  for _, path in ipairs({ "hardcover/lib/ui/dialog_manager.lua", "hardcover/lib/ui/list_flows.lua" }) do
    assert(not read(path):find("if not host then UIManager:close(dialog) end", 1, true), path .. " still closes only when not hosted")
  end
end)

print("\n== the sync box follows the queues ==")

local OfflineQueue = dofile(PLUGIN .. "/hardcover/lib/offline_queue.lua")

check("saving a queue calls its on_change", function()
  local calls = 0
  local q = OfflineQueue:new { settings = { flush = function() end }, on_change = function() calls = calls + 1 end }
  q:persist()
  assert(calls == 1, "on_change called " .. calls .. " times")
end)

check("a failing on_change does not break the save", function()
  local flushed = false
  local q = OfflineQueue:new { settings = { flush = function() flushed = true end }, on_change = function() error("boom") end }
  q:persist()
  assert(flushed)
end)

check("a queue without on_change saves as before", function()
  OfflineQueue:new { settings = { flush = function() end } }:persist()
end)

check("main wires every queue to Home, and Home redraws only when its count changed", function()
  local main = read("main.lua")
  assert(main:find("queue.on_change = function() self.dialog_manager:queueChanged() end", 1, true), "queues not wired")
  assert(main:find("self.list_queue }", 1, true), "list queue missing from the wiring")
  local dm = read("hardcover/lib/ui/dialog_manager.lua")
  assert(dm:find("home.shown_pending == home.pending_fn()", 1, true), "queueChanged redraws on every save")
  assert(read("hardcover/lib/ui/home_body.lua"):find("self.shown_pending = waiting", 1, true), "Home does not record the count it shows")
end)

r.finish()
