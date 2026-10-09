-- Proves the refresh helpers queue the repaint the panel expects: a region refresh
-- asks for its rectangle, and only a refresh that shows a picture asks for dithering,
-- as the third value UIManager reads from the refresh function.
--
-- Run with:  lua spec/refresh_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local check = function(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end
local function expect(cond, msg) if not cond then error(msg or "expectation failed", 2) end end

-- What the stubbed UIManager was asked to queue: each setDirty's refresh function.
local queued = {}
package.preload["ui/uimanager"] = function()
  return {
    setDirty = function(_, widget, refresh)
      queued[#queued + 1] = { widget = widget, refresh = refresh }
    end,
  }
end
package.preload["ui/geometry"] = function()
  return { new = function(_, o) return o end }
end
package.preload["device"] = function()
  return { screen = { getWidth = function() return 1200 end, getHeight = function() return 1600 end } }
end

local Refresh = dofile(PLUGIN .. "/hardcover/lib/ui/refresh.lua")
local window = { name = "window" }
local screen = { x = 0, y = 0, w = 1200, h = 1600 }

print("\n== refresh: dithering for pictures ==")

check("a region refresh asks for its rectangle, and no dithering unless asked", function()
  queued = {}
  Refresh.region(window, function() return { x = 10, y = 20, w = 30, h = 40 } end)
  expect(#queued == 1 and queued[1].widget == window, "nothing queued for the window")
  local mode, region, dither = queued[1].refresh()
  expect(mode == "ui" and region and region.x == 10 and region.y == 20 and region.w == 30 and region.h == 40,
    "wrong rectangle: " .. tostring(region and region.x))
  expect(dither == nil, "a plain refresh was dithered")
end)

check("a region refresh asked to dither returns the flag as the third value", function()
  queued = {}
  Refresh.region(window, function() return { x = 10, y = 20, w = 30, h = 40 } end, nil, true)
  local mode, region, dither = queued[1].refresh()
  expect(mode == "ui" and region ~= nil and dither == true, "dither flag missing: " .. tostring(dither))
end)

check("a dithered refresh with no known rectangle is still dithered (whole panel)", function()
  queued = {}
  Refresh.region(window, function() return nil end, nil, true)
  local mode, region, dither = queued[1].refresh()
  expect(mode == "ui" and region == nil and dither == true, "fell back without the flag")
end)

check("a refresh with no known rectangle and no dithering has no dither flag", function()
  queued = {}
  Refresh.region(window, function() return nil end)
  local mode, region, dither = queued[1].refresh()
  expect(mode == "ui" and region == nil and dither == nil, "unexpected values")
end)

check("the mode given is kept when dithering", function()
  queued = {}
  Refresh.region(window, function() return { x = 1, y = 2, w = 3, h = 4 } end, "partial", true)
  local mode, _, dither = queued[1].refresh()
  expect(mode == "partial" and dither == true)
end)

check("a box refresh passes the flag on, and leaves it off when not asked", function()
  queued = {}
  local dimen = { x = 100, y = 100, w = 135, h = 200 }
  local queuedBox = Refresh.box(window, function() return dimen end, function() return screen end, nil, true)
  expect(queuedBox == true and #queued == 1, "the box was not queued")
  local _, region, dither = queued[1].refresh()
  expect(dither == true and region ~= nil and region.w == 135, "box picture not dithered")

  Refresh.box(window, function() return dimen end, function() return screen end)
  local _, _, plain = queued[2].refresh()
  expect(plain == nil, "a box refresh not asked to dither returned the flag")
end)

check("a box scrolled out of view queues nothing, dithered or not", function()
  queued = {}
  local dimen = { x = 100, y = 2000, w = 135, h = 200 }
  expect(Refresh.box(window, function() return dimen end, function() return screen end, nil, true) == false)
  expect(#queued == 0, "something was queued for a box off screen")
end)

r.finish()
