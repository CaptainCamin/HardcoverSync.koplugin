-- When a book that is not being read is offered "Currently Reading": pages are counted as they are
-- turned forward, the reader is asked once, and "Not now" keeps the question away for the session.
-- Plain data, no KOReader.
--
-- Run with:  lua spec/start_reading_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local StartReading = require("hardcover/lib/start_reading")
package.preload["version"] = package.preload["version"] or function() return { getNormalizedCurrentVersion = function() return 0 end } end
package.preload["luasettings"] = package.preload["luasettings"] or function() return {} end
local HardcoverSettings = require("hardcover/lib/hardcover_settings")

-- read forward one page at a time from `from`, returns the page where it asked (or nil)
local function read(state, from, pages, threshold)
  for i = 1, pages do
    if StartReading.turn(state, from + i - 1, from + i, threshold) then return from + i end
  end
end

print("\n== counting pages ==")

check("it asks once the threshold is reached, not before", function()
  local state = StartReading.new()
  assert(read(state, 10, 4, 5) == nil)
  assert(StartReading.turn(state, 14, 15, 5) == true)
end)

check("it asks only once", function()
  local state = StartReading.new()
  assert(read(state, 1, 5, 5) == 6)
  assert(read(state, 6, 20, 5) == nil)
end)

check("going back or standing still is not reading", function()
  local state = StartReading.new()
  for _ = 1, 10 do
    assert(StartReading.turn(state, 20, 19, 5) == false)
    assert(StartReading.turn(state, 20, 20, 5) == false)
  end
  assert(state.pages == 0)
end)

check("a jump (a chapter, a bookmark) is not counted as pages read", function()
  local state = StartReading.new()
  assert(StartReading.turn(state, 5, 120, 5) == false)
  assert(state.pages == 0)
end)

check("a turn that skips a page or two still counts what it moved", function()
  local state = StartReading.new()
  assert(StartReading.turn(state, 1, 3, 5) == false)
  assert(StartReading.turn(state, 3, 6, 5) == true)
end)

check("a page that is not known is ignored", function()
  local state = StartReading.new()
  assert(StartReading.turn(state, nil, 4, 5) == false)
  assert(StartReading.turn(state, 3, nil, 5) == false)
  assert(state.pages == 0)
end)

check("the threshold is the one given", function()
  local state = StartReading.new()
  assert(read(state, 1, 2, 2) == 3)
  local other = StartReading.new()
  assert(read(other, 1, 49, 50) == nil)
  assert(read(other, 50, 1, 50) == 51)
end)

print("\n== Not now ==")

check("after Not now the question does not come back this session", function()
  local state = StartReading.new()
  assert(read(state, 1, 5, 5) == 6)
  StartReading.declined(state)
  assert(read(state, 6, 50, 5) == nil)
end)

check("a new session (another book opened) asks again", function()
  local state = StartReading.new()
  assert(read(state, 1, 5, 5) == 6)
  StartReading.declined(state)
  StartReading.reset(state)
  assert(read(state, 1, 5, 5) == 6)
end)

print("\n== the setting ==")

local function settings_with(value)
  local fake = { settings = { readSetting = function() return value end } }
  return setmetatable(fake, { __index = HardcoverSettings })
end

check("the threshold defaults to 5 pages", function()
  assert(settings_with(nil):startReadingPages() == 5)
end)

check("a chosen threshold is used, and never below 1", function()
  assert(settings_with(12):startReadingPages() == 12)
  assert(settings_with(0):startReadingPages() == 1)
  assert(settings_with("junk"):startReadingPages() == 5)
end)

r.finish()
