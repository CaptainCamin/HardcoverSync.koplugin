-- Gestures a plugin window does not use go on to the window below it (see
-- components/passthrough.lua); taps in the middle of the screen do not.
--
-- Run with:  lua spec/passthrough_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local stack = {}
package.preload["ui/uimanager"] = function() return { _window_stack = stack } end
package.preload["device"] = function()
  return { screen = { getWidth = function() return 800 end, getHeight = function() return 1000 end } }
end

local Passthrough = dofile(PLUGIN .. "/hardcover/lib/ui/components/passthrough.lua")

local got
local under = { handleEvent = function(_, e) got = e return true end }
local top = {}
stack[1] = { widget = under }
stack[2] = { widget = top }

local function ev(ges, x, y)
  return { handler = "onGesture", args = { { ges = ges, pos = { x = x or 400, y = y or 500 } } } }
end

local function sent(e)
  got = nil
  local used = Passthrough.forward(top, e)
  return used, got
end

r.check("a swipe reaches the window below", pcall(function()
  local used, e = sent(ev("swipe"))
  assert(used and e, "not forwarded")
end))
r.check("a two finger gesture reaches the window below", pcall(function()
  assert(sent(ev("two_finger_swipe")))
end))
r.check("a tap in a corner reaches the window below", pcall(function()
  assert(sent(ev("tap", 10, 10)))
  assert(sent(ev("tap", 790, 990)))
end))
r.check("a tap in the middle stays with the window", pcall(function()
  local used, e = sent(ev("tap"))
  assert(not used and not e, "a middle tap was passed on")
end))
r.check("a hold stays with the window", pcall(function()
  assert(not sent(ev("hold", 10, 10)))
end))
r.check("events other than gestures are not passed on", pcall(function()
  assert(not sent({ handler = "onBack", args = {} }))
end))
r.check("nothing below means nothing happens", pcall(function()
  assert(not Passthrough.forward(under, ev("swipe")))
end))

r.finish()
