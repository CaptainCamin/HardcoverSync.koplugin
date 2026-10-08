-- The screen registry: which screen of each kind is open, taking the old one down
-- before its replacement, and reaching an open one only while it is shown. Fakes
-- only, no KOReader.
--
-- Run with:  lua spec/screen_registry_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local ScreenRegistry = require("hardcover/lib/screen_registry")

-- A fake window stack: show() puts a widget on it, close() takes it off.
local function setup()
  local stack, log = {}, {}
  local ui = {
    is_shown = function(w) return stack[w] == true end,
    close = function(w) stack[w] = nil; log[#log + 1] = "close:" .. w.name end,
  }
  local owner = {}
  local reg = ScreenRegistry.new(owner, ui)
  local function widget(name)
    local w = { name = name }
    function w:free() log[#log + 1] = "free:" .. name end
    return w
  end
  local function show(w) stack[w] = true end
  return reg, owner, widget, show, log, stack
end

print("\n== remembering screens ==")

check("a tracked screen is kept in the owner's <kind>_dialog field", function()
  local reg, owner, widget = setup()
  local w = widget("home")
  assert(reg:track("home", w) == w)
  assert(owner.home_dialog == w, "the field tests and screens read")
end)

check("track alone does not touch the screen it replaces", function()
  local reg, owner, widget, show, log = setup()
  local a, b = widget("a"), widget("b")
  show(a); reg:track("goal", a)
  show(b); reg:track("goal", b)
  assert(owner.goal_dialog == b and #log == 0, table.concat(log, ","))
end)

check("kinds are kept apart", function()
  local reg, owner, widget = setup()
  local h, s = widget("h"), widget("s")
  reg:track("home", h); reg:track("shelf", s)
  assert(owner.home_dialog == h and owner.shelf_dialog == s)
end)

print("\n== taking the old one down ==")

check("discard closes a screen that is still shown, then frees it, in that order", function()
  local reg, owner, widget, show, log = setup()
  local w = widget("shelf")
  show(w); reg:track("shelf", w)
  reg:discard("shelf")
  assert(table.concat(log, ",") == "close:shelf,free:shelf", table.concat(log, ","))
  assert(owner.shelf_dialog == nil, "the slot is cleared")
end)

check("discard of a screen already closed only frees it", function()
  local reg, _, widget, _, log = setup()
  local w = widget("shelf")
  reg:track("shelf", w)  -- never shown, or closed since
  reg:discard("shelf")
  assert(table.concat(log, ",") == "free:shelf", table.concat(log, ","))
end)

check("discard with nothing open does nothing", function()
  local reg, _, _, _, log = setup()
  reg:discard("shelf")
  assert(#log == 0)
end)

check("discard leaves other kinds alone", function()
  local reg, owner, widget, show, log = setup()
  local h, s = widget("h"), widget("s")
  show(h); show(s); reg:track("home", h); reg:track("shelf", s)
  reg:discard("shelf")
  assert(owner.home_dialog == h and table.concat(log, ",") == "close:s,free:s")
end)

print("\n== reaching an open screen ==")

check("open returns the screen while it is shown", function()
  local reg, _, widget, show = setup()
  local w = widget("goals")
  show(w); reg:track("goals", w)
  assert(reg:open("goals") == w)
end)

check("open returns nil once the screen has been closed", function()
  local reg, _, widget, show, _, stack = setup()
  local w = widget("goals")
  show(w); reg:track("goals", w)
  stack[w] = nil  -- closed by a tap, by KOReader, by anything
  assert(reg:open("goals") == nil)
end)

check("open returns nil for a kind that was never shown", function()
  local reg = setup()
  assert(reg:open("lists") == nil)
end)

check("a screen the registry never saw (set on the owner directly) is still found", function()
  local reg, owner, widget, show = setup()
  local w = widget("home")
  show(w); owner.home_dialog = w
  assert(reg:open("home") == w)
end)

r.finish()
