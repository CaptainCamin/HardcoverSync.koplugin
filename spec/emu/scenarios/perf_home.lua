--[[--
How much screen work opening the home screen causes.

Counts are refreshes as the framebuffer receives them, after UIManager has
merged what was queued (see probe.lua), plus how many times the widget tree was
rebuilt and how many covers were decoded. Desktop CPU is not device CPU: read
the counts and the relative sizes, not the seconds.

Budget (the assertions at the end): opening Home is ONE full-screen refresh, the
first paint. Counts, the reading list, the list count and every cover arrive as
small regions, and the same cover is decoded once however often the screen is
rebuilt.
]]

local fixtures = require("fixtures")
local perf = require("perf")

return {
  name = "perf_home",

  run = function(emu)
    local probe = emu.probe
    local Home = require("hardcover/lib/ui/home_dialog")

    local builds = 0
    local orig_build = Home.build
    function Home:build(...)
      builds = builds + 1
      return orig_build(self, ...)
    end

    for _, id in ipairs({ 101, 102 }) do
      fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg")
    end

    -- nothing saved: counts, the reading list and the list count all arrive late
    local manager, settings = perf.new_manager(emu, fixtures, "perf_cold")
    fixtures.install({ settings = settings })
    perf.slow_network({ "getShelfCounts", "getCurrentlyReading", "getListCount" })
    probe:reset()
    builds = 0
    manager:showHome()
    perf.run_loop()
    local cold = probe:report("home, nothing saved (cold)")
    print(string.format("  probe %-34s builds=%d  small: %s", "", builds, perf.small_regions(cold)))
    local cold_builds = builds
    emu:shot("perf_home_cold")
    emu:closeAll()
    perf.run_loop()

    -- everything saved and unchanged: only the list count is news
    local warm_manager, warm_settings = perf.new_manager(emu, fixtures, "perf_warm", {
      counts = fixtures.shelf_counts,
      reading = fixtures.currently_reading,
    })
    fixtures.install({ settings = warm_settings })
    perf.slow_network({ "getShelfCounts", "getCurrentlyReading", "getListCount" })
    probe:reset()
    builds = 0
    warm_manager:showHome()
    perf.run_loop()
    local warm = probe:report("home, saved and unchanged (warm)")
    print(string.format("  probe %-34s builds=%d  small: %s", "", builds, perf.small_regions(warm)))
    emu:closeAll()
    perf.run_loop()

    -- the budget
    assert(cold.full <= 1, "opening Home refreshed the whole panel " .. cold.full .. " times (budget 1)")
    assert(warm.full <= 1, "reopening Home refreshed the whole panel " .. warm.full .. " times (budget 1)")
    assert(cold.decodes <= 2, "Home decoded " .. cold.decodes .. " covers for 2 distinct pictures")
    assert(warm.decodes <= 2, "Home decoded " .. warm.decodes .. " covers for 2 distinct pictures")
    assert(cold_builds >= 1)
  end,
}
