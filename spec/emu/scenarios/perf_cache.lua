--[[--
What the saved shelves cost: file size, how long they take to read and to write,
and what opening Home does with them. A 600 book shelf with realistic rows
(every field normalizeEntry keeps, a description at the 600 byte cap, authors and
a series), using KOReader's real LuaSettings.

Desktop timings are not a device's (an e-ink reader's CPU and flash are several
times slower): the file size and the number of writes are what carry over.
]]

local fixtures = require("fixtures")
local perf = require("perf")

local function row(i)
  local b = {
    book_id = 1000 + i, title = "A Reasonably Long Book Title Number " .. i, authors = "An Author, Another Author",
    series = (i % 3 == 0) and ("A Series Name #" .. (i % 7)) or nil,
    release_year = 1950 + i % 70, pages = 200 + i % 400, users_count = 1000 + i, community_rating = 4.1,
    ratings_count = 300 + i, status_id = 1, user_rating = (i % 5 == 0) and 4 or nil, date_added = "2026-01-01",
    user_book_id = 90000 + i,
    cached_image = { url = "https://assets.hardcover.app/books/" .. (100000 + i) .. "/10000" .. i .. ".jpg", width = 333, height = 500 },
    description = string.rep("A publisher's blurb that runs on and on about the book. ", 12),
    contributions = { { author = { name = "An Author" } }, { author = { name = "Another Author" } } },
    book_series = (i % 3 == 0) and { { position = i % 7, series = { id = i % 50, name = "A Series Name" } } } or {},
  }
  return b
end

local function size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local n = f:seek("end")
  f:close()
  return n
end

return {
  name = "perf_cache",

  run = function(emu)
    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_perf.lua"
    os.remove(path)

    local function new_cache()
      return ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end }
    end

    local entries = {}
    for i = 1, 600 do entries[i] = row(i) end

    local cache = new_cache()
    local t = os.clock()
    cache:put(fixtures.USER_ID, 1, entries, true)
    local put_cpu = os.clock() - t
    local one_shelf = size(path)

    -- three more shelves of the same size, as a heavy user would have
    for status = 2, 4 do cache:put(fixtures.USER_ID, status, entries, true) end
    cache:putCounts(fixtures.USER_ID, { [1] = 600, [2] = 600, [3] = 600, [5] = 0 })
    cache:putReading(fixtures.USER_ID, fixtures.currently_reading)
    local four = size(path)

    print(string.format("  file: one 600-book shelf %.0f KB, four shelves %.0f KB (%.1f KB per book)",
      one_shelf / 1024, four / 1024, four / 4 / 600 / 1024))
    print(string.format("  one put of a 600-book shelf: %.0f ms of desktop CPU (serialise + write)", put_cpu * 1000))

    -- what Home reads: the counts and the reading list, from a cold cache object
    collectgarbage(); collectgarbage()
    local before = collectgarbage("count")
    t = os.clock()
    local reader = new_cache()
    local counts = reader:counts(fixtures.USER_ID, { 1, 2, 3, 5 })
    local reading = reader:reading(fixtures.USER_ID)
    local home_cpu = os.clock() - t
    local held = collectgarbage("count") - before
    assert(counts[1] == 600 and reading)
    print(string.format("  Home's counts + reading list from that file: %.0f ms desktop CPU, %.1f MB of Lua heap held afterwards",
      home_cpu * 1000, held / 1024))

    -- writes: opening Home puts the counts and the reading list it just fetched,
    -- which for an unchanged library are the very same
    local flushes = 0
    local real_flush = LuaSettings.flush
    LuaSettings.flush = function(...) flushes = flushes + 1; return real_flush(...) end
    local writer = new_cache()
    t = os.clock()
    writer:putCounts(fixtures.USER_ID, { [1] = 600, [2] = 600, [3] = 600, [5] = 0 })
    writer:putReading(fixtures.USER_ID, fixtures.currently_reading)
    local write_cpu = os.clock() - t
    LuaSettings.flush = real_flush
    print(string.format("  Home refetches the same counts and list: %d file writes of %.0f KB, %.0f ms desktop CPU",
      flushes, four / 1024, write_cpu * 1000))

    assert(flushes == 0, "saving counts and a reading list that did not change rewrote a cache file " ..
      flushes .. " times")

    -- the usual change: reading progress moved, so the reading list is news
    local moved = fixtures.deepcopy(fixtures.currently_reading)
    moved[1].progress_pages = moved[1].progress_pages + 7
    flushes = 0
    LuaSettings.flush = function(...) flushes = flushes + 1; return real_flush(...) end
    writer:putReading(fixtures.USER_ID, moved)
    LuaSettings.flush = real_flush
    local small = size(emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_perf_home.lua")
    print(string.format("  reading progress changed: %d file write of %.1f KB (the shelves file is %.0f KB)",
      flushes, small / 1024, four / 1024))
    assert(flushes == 1 and small < 20 * 1024, "a changed reading list wrote " .. small .. " bytes in " .. flushes .. " writes")

  end,
}
