-- The four older Hardcover cards (goal, goal ring, stats, year) through the
-- real Bookshelf 6.2 host: its fit search, clipping and tap routing, at a
-- square cell and a short 2x1 strip, plus their start-menu and empty states.
-- KO_EMU_BOOKSHELF points to an upstream checkout; CI pins it in test.yml.
local fixtures = require("fixtures")

return {
  name = "bookshelf_goal_stats",
  run = function(emu)
    local bookshelf = os.getenv("KO_EMU_BOOKSHELF")
    if not bookshelf then print("  skipped: set KO_EMU_BOOKSHELF to Bookshelf 6.2"); return end
    package.path = bookshelf .. "/?.lua;" .. package.path
    local UIManager = emu.UIManager
    local Theme = require("hardcover/lib/ui/theme")
    local Goals = require("hardcover/lib/goals")
    local Stats = require("hardcover/lib/stats")
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })
    local user_id = fixtures.USER_ID
    local LuaSettings = require("luasettings")
    local cache_path = emu.DataStorage:getSettingsDir() .. "/goal_stats_modules.lua"
    os.remove(cache_path)
    local cache = require("hardcover/lib/shelf_cache"):new {
      path = cache_path, open = function(p) return LuaSettings:open(p) end,
    }

    -- 46 of 70 books, running around today, so the pace line has something to say.
    local function iso(days)
      local t = os.date("*t", os.time() + days * 86400)
      return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
    end
    cache:putGoals(user_id, Goals.normalize({
      { id = 1, goal = 70, metric = "book", description = "Reading goal",
        start_date = iso(-200), end_date = iso(165), progress = 46, archived = false },
    }))

    -- One finish a month, with pages. The current month always has one, so the
    -- year chart draws its hollow "still counting" bar in every run.
    local today = os.date("*t")
    local pages = { [1] = 320, [2] = 690, [3] = 1130, [4] = 300, [5] = 620,
      [7] = 560, [8] = 720, [9] = 480, [10] = 1030, [11] = 360 }
    pages[today.month] = 360
    local rows, total, peak, peak_month = {}, 0, 0, nil
    for month = 1, 12 do
      local n = pages[month]
      if n then
        total = total + n
        if n > peak then peak, peak_month = n, month end
        rows[#rows + 1] = { id = month, status_id = 3, rating = 4.5,
          last_read_date = string.format("%04d-%02d-01", today.year, month),
          book = { id = month, title = "Reference " .. month, pages = n } }
      end
    end
    cache:putStats(user_id, { rows = Stats.normalizeAll(rows), complete = true })
    local function grouped(n)
      local body, commas = tostring(n):reverse():gsub("(%d%d%d)", "%1,")
      local out = body:reverse()
      if commas > 0 then out = out:gsub("^,", "") end
      return out
    end
    local best = os.date("%B", os.time { year = today.year, month = peak_month, day = 1 })

    local opened
    local manager = {
      finishedOffline = function() return 0 end,
      showGoals = function() opened = "goals" end,
      showStats = function() opened = "stats" end,
    }
    local plugin_path = emu.DataStorage:getDataDir() .. "/plugins/hardcoversync.koplugin"
    local app = { path = plugin_path, shelf_cache = cache, dialog_manager = manager }
    local current_app = app
    require("pluginloader").getPluginInstance = function(_, name)
      if name == "hardcoversync" then return current_app end
    end

    local SM = require("lib/bookshelf_start_menu_modules")
    local Hero = require("lib/bookshelf_hero_modules")
    local Kit = require("lib/bookshelf_module_kit")
    local keys = { "hardcover_goal", "hardcover_goal_ring", "hardcover_stats", "hardcover_year" }
    for _, key in ipairs(keys) do
      local spec = assert(loadfile(plugin_path .. "/bookshelf_modules/" .. key .. ".lua"))(plugin_path .. "/bookshelf_modules")
      assert(spec.key == key)
      SM.register(key, spec)
    end

    local VGroup = require("ui/widget/verticalgroup")
    local HGroup = require("ui/widget/horizontalgroup")
    local VSpan = require("ui/widget/verticalspan")
    local HSpan = require("ui/widget/horizontalspan")
    local Frame = require("ui/widget/container/framecontainer")
    local Center = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local entries, slots, screen = {}, {}, nil
    local margin, gap = Theme.space.m, Theme.space.s
    local width = emu.Screen:getWidth() - 2 * margin
    local unit = math.floor((width - 5 * gap) / 6)

    local function findClip(widget)
      if widget._child_dx ~= nil then return widget end
      for _, child in ipairs(widget) do
        local clip = findClip(child)
        if clip then return clip end
      end
    end
    local function expectFit()
      emu:screenNodes()
      for i, slot in ipairs(slots) do
        local clip = assert(findClip(slot), keys[i] .. ": no host clipping container")
        local size = clip[1]:getSize()
        assert(size.w <= clip.w and size.h <= clip.h, string.format("%s content %dx%d clipped to %dx%d",
          keys[i], size.w, size.h, clip.w, clip.h))
        for _, r in ipairs(clip[1]._tap_regions or {}) do
          assert(r.w >= Theme.TOUCH_MIN and r.h >= Theme.TOUCH_MIN, keys[i] .. ": undersized touch target")
          assert(r.x >= 0 and r.y >= 0 and r.x + r.w <= size.w and r.y + r.h <= size.h,
            keys[i] .. ": button outside visible content")
        end
      end
    end
    local function cell(i, w, h)
      local entry = entries[i] or { id = i, module = keys[i] }
      entries[i] = entry
      local slot = Center:new { dimen = Geom:new { w = w, h = h } }
      local function refresh()
        local old = slot[1]
        slot[1] = Hero._makeCell(nil, entry, w, h, 100, false, false)
        if old then old:free() end
        UIManager:setDirty(screen, "ui")
      end
      Hero.adopt(entry, { surface = "hero", save = function() end, refresh = refresh })
      refresh()
      slots[i] = slot
      return slot
    end
    local function show(cw, ch, only)
      local requests = #fixtures.calls
      if screen then UIManager:close(screen) end
      slots = {}
      local all = VGroup:new { align = "left" }
      if only then
        all[#all + 1] = cell(only, cw, ch)
      else
        for row = 1, 2 do
          local line = HGroup:new { align = "top" }
          for col = 1, 2 do
            local i = (row - 1) * 2 + col
            if col > 1 then line[#line + 1] = HSpan:new { width = gap } end
            line[#line + 1] = cell(i, cw, ch)
          end
          if row > 1 then all[#all + 1] = VSpan:new { width = gap } end
          all[#all + 1] = line
        end
      end
      screen = Frame:new { padding = margin, margin = 0, bordersize = 0, background = Theme.WHITE,
        width = emu.Screen:getWidth(), height = emu.Screen:getHeight(), all }
      UIManager:show(screen)
      emu:pump()
      expectFit()
      assert(#fixtures.calls == requests, "render made an API request")
    end

    local square = 3 * unit + 2 * gap
    show(square, square)
    for _, text in ipairs({ "Reading goal", "46", "70", "books", "66%", "10",
      tostring(today.year), grouped(total), "pages", "Best: " .. best }) do
      emu:expectText(text)
    end
    emu:shot("bookshelf_goal_stats")

    -- Tap through Bookshelf's real coordinate translation. Each card opens the
    -- screen that owns its data.
    local function tap(i, expected)
      emu:screenNodes()
      local clip = assert(findClip(slots[i]), "no module tap region")
      emu:tapExpecting(math.floor(clip.dimen.x + clip._child_dx + clip.w / 2),
        math.floor(clip.dimen.y + clip._child_dy + clip.h / 2))
      emu:pump()
      assert(opened == expected, keys[i] .. " opened " .. tostring(opened) .. ", expected " .. expected)
      opened = nil
    end
    tap(1, "goals")
    tap(2, "goals")
    tap(3, "stats")
    tap(4, "stats")

    -- The short 2x1 cell every one of these cards can be sized to on the shelf.
    show(2 * unit + gap, unit)
    for _, text in ipairs({ "46", "books", "66%", grouped(total), tostring(today.year) }) do
      emu:expectText(text)
    end
    emu:shot("bookshelf_goal_stats_small")

    -- The ring's one-cell tile: it is the one card allowed to drop its name.
    show(unit, unit, 2)
    emu:expectText("66%")
    emu:shot("bookshelf_goal_stats_tile")

    -- Start-menu rows have no cell height and no host font-fit search.
    for _, key in ipairs(keys) do
      local entry = { module = key }
      local w = math.floor(width * 0.6)
      local card = SM.get(key).render({ width = w, height = nil, scale = 100,
        shape = Kit.shape(w, nil), surface = "start_menu", config = Kit.entryConfig(entry),
        set_tap_regions = function() end })
      local size = card:getSize()
      assert(size.w <= w and size.h < emu.Screen:getHeight(), key .. " oversized menu row")
      card:free()
    end

    -- No saved data must say so, not show a zero or a blank card.
    local empty = {
      goals = function() return {} end,
      stats = function() return nil end,
    }
    current_app = { path = plugin_path, shelf_cache = empty, dialog_manager = manager }
    show(square, square)
    emu:expectText("No current goal. Tap to set one.")
    emu:expectText("Open Hardcover once to load this.")
    emu:shot("bookshelf_goal_stats_empty")
    emu:closeAll()
  end,
}