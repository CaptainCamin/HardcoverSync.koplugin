-- Real Bookshelf 6.2 cards, including its fit search, clipping and tap routing.
-- KO_EMU_BOOKSHELF points to an upstream checkout; CI pins it in test.yml.
local fixtures = require("fixtures")

return {
  name = "bookshelf_modules",
  run = function(emu)
    local bookshelf = os.getenv("KO_EMU_BOOKSHELF")
    if not bookshelf then print("  skipped: set KO_EMU_BOOKSHELF to Bookshelf 6.2"); return end
    package.path = bookshelf .. "/?.lua;" .. package.path
    local UIManager = emu.UIManager
    local Theme = require("hardcover/lib/ui/theme")
    local Stats = require("hardcover/lib/stats")
    local Modules = require("hardcover/lib/bookshelf_modules")
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })
    local user_id = fixtures.USER_ID
    local LuaSettings = require("luasettings")
    local cache_path = emu.DataStorage:getSettingsDir() .. "/module_stats.lua"
    os.remove(cache_path)
    local cache = require("hardcover/lib/shelf_cache"):new {
      path = cache_path, open = function(p) return LuaSettings:open(p) end,
    }
    local db_path = emu.DataStorage:getSettingsDir() .. "/module_library.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
    local db = require("hardcover/lib/sqlite_store"):new { path = db_path }
    local books = require("hardcover/lib/book_store"):new { db = db }
    local shelves = require("hardcover/lib/shelf_store"):new { db = db, books = books }
    local today = os.date("*t")
    local raw = {}
    for i = 1, 84 do
      local book = fixtures.deepcopy(fixtures.books[(i - 1) % 3 + 1])
      book.id = i <= 3 and book.book_id or 1000 + i
      book.cached_contributors = { { primary = true,
        author = { id = (i - 1) % 17 + 1, name = book.contributions[1].author.name } } }
      local month = i <= 3 and today.month or today.month % 12 + 1
      local reads = {}
      for j = 1, ((i >= 4 and i <= 9) and 3 or 1) do
        reads[#reads + 1] = { id = i * 10 + j, finished_at_precision = 1,
          finished_at = string.format("%04d-%02d-%02d", today.year - j, month, i <= 3 and today.day or 1) }
      end
      raw[#raw + 1] = { id = i, status_id = 3, rating = i <= 19 and 5 or 4.5,
        book = book, user_book_reads = reads }
      if i <= 3 then fixtures.seed_cover(book.cached_image.url, i) end
    end
    local saved = { rows = Stats.normalizeAll(raw), history = Stats.history(raw), complete = true }
    cache:putStats(user_id, saved)
    local tbr = {}
    for i = 1, 3 do
      local book = fixtures.books[i + 3]
      tbr[#tbr + 1] = { book_id = book.book_id, title = book.title,
        authors = book.contributions[1].author.name, cached_image = book.cached_image,
        date_added = string.format("%04d-02-%02d", today.year - i, i), user_book_id = 200 + i }
      if book.cached_image then fixtures.seed_cover(book.cached_image.url, i) end
    end
    shelves:putEntries(user_id, 1, tbr, true, "fixture")
    local manager = require("hardcover/lib/ui/dialog_manager"):new {
      settings = settings, shelf_cache = cache, shelf_store = shelves, book_store = books,
    }
    local plugin_path = emu.DataStorage:getDataDir() .. "/plugins/hardcoversync.koplugin"
    local app = { path = plugin_path, shelf_cache = cache, shelf_store = shelves, dialog_manager = manager }
    -- Only the plugin discovery boundary is injected, not Kit, the host or widgets.
    require("pluginloader").getPluginInstance = function(_, name)
      if name == "hardcoversync" then return app end
    end
    local SM = require("lib/bookshelf_start_menu_modules")
    local Hero = require("lib/bookshelf_hero_modules")
    local Kit = require("lib/bookshelf_module_kit")
    local keys = { "hardcover_authors", "hardcover_books_read", "hardcover_five_star", "hardcover_rereads",
      "hardcover_memories", "hardcover_tbr" }
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
        local clip = assert(findClip(slot), "no host clipping container")
        local size = clip[1]:getSize()
        assert(size.w <= clip.w and size.h <= clip.h, string.format("%s content %dx%d clipped to %dx%d",
          keys[i], size.w, size.h, clip.w, clip.h))
        for _, r in ipairs(clip[1]._tap_regions or {}) do
          assert(r.w >= Theme.TOUCH_MIN and r.h >= Theme.TOUCH_MIN, "undersized touch target")
          assert(r.x >= 0 and r.y >= 0 and r.x + r.w <= size.w and r.y + r.h <= size.h,
            keys[i] .. " button outside visible content")
        end
      end
    end
    local function cell(i, w, h, surface)
      local entry = entries[i] or { id = i, module = keys[i] }
      entries[i] = entry
      local slot = Center:new { dimen = Geom:new { w = w, h = h } }
      local function refresh()
        local old = slot[1]
        slot[1] = Hero._makeCell(nil, entry, w, h, 100, false, false)
        if old then old:free() end
        UIManager:setDirty(screen, "ui")
      end
      Hero.adopt(entry, { surface = surface or "hero", save = function() end, refresh = refresh })
      refresh()
      slots[i] = slot
      return slot
    end
    local function show(wide, small)
      local requests = #fixtures.calls
      if screen then UIManager:close(screen) end
      local all = VGroup:new { align = "left" }
      local numbers = HGroup:new { align = "top" }
      local unit = math.floor((width - 5 * gap) / 6)
      for i = 1, 4 do
        if i > 1 then numbers[#numbers + 1] = HSpan:new { width = gap } end
        numbers[#numbers + 1] = cell(i, small and unit or math.floor((width - 3 * gap) / 4),
          small and unit or Theme.space.xl * 3)
      end
      all[#all + 1] = numbers
      all[#all + 1] = VSpan:new { width = gap }
      if wide then
        all[#all + 1] = cell(5, width, Theme.space.xl * 4, "shelf")
        all[#all + 1] = VSpan:new { width = gap }
        all[#all + 1] = cell(6, width, Theme.space.xl * 4, "shelf")
      else
        local w = small and 2 * unit + gap or math.floor((width - gap) / 2)
        local h = small and w or math.floor(emu.Screen:getHeight() * 0.48)
        all[#all + 1] = HGroup:new { align = "top", cell(5, w, h), HSpan:new { width = gap }, cell(6, w, h) }
      end
      screen = Frame:new { padding = margin, margin = 0, bordersize = 0, background = Theme.WHITE,
        width = emu.Screen:getWidth(), height = emu.Screen:getHeight(), all }
      UIManager:show(screen)
      emu:pump()
      expectFit()
      assert(#fixtures.calls == requests, "render made an API request")
    end
    local function showLargeTotals(w, h, name)
      local requests = #fixtures.calls
      if screen then UIManager:close(screen) end
      slots = {}
      local size = math.floor((width - gap) / 2)
      w, h = w or size, h or size
      local all = VGroup:new { align = "left" }
      for row = 1, 2 do
        if row > 1 then all[#all + 1] = VSpan:new { width = gap } end
        all[#all + 1] = HGroup:new { align = "top",
          cell((row - 1) * 2 + 1, w, h), HSpan:new { width = gap },
          cell((row - 1) * 2 + 2, w, h) }
      end
      screen = Frame:new { padding = margin, margin = 0, bordersize = 0, background = Theme.WHITE,
        width = emu.Screen:getWidth(), height = emu.Screen:getHeight(), all }
      UIManager:show(screen)
      emu:pump()
      expectFit()
      for _, text in ipairs({ "17", "Authors read", "84", "Books read", "19", "Five-star books", "12", "Rereads" }) do
        emu:expectText(text)
      end
      assert(not emu:screenText():find("tap to refresh", 1, true), "cached totals replaced by refresh copy")
      assert(not emu:screenText():find("Saved history", 1, true), "cached totals still have the stale footer")
      assert(#fixtures.calls == requests, "render made an API request")
      emu:shot(name or "bookshelf_totals_large")
    end
    local function expectTotalLayout(stacked, hidden)
      -- Measure actual paint positions in each cell's offscreen buffer, not
      -- the particular group/container tree used to arrange these widgets.
      local painted, restore = {}, {}
      for i, count in ipairs({ "17", "84", "19", "12" }) do
        painted[i] = {}
        local function watch(node)
          local role = node.is_icon and "icon" or node.text == count and "value"
          if role then
            local paint = node.paintTo
            restore[#restore + 1] = function() node.paintTo = paint end
            node.paintTo = function(self, bb, x, y)
              local s = self:getSize()
              painted[i][role] = { x = x, y = y, w = s.w, h = s.h }
              return paint(self, bb, x, y)
            end
          end
          for _, child in ipairs(node) do watch(child) end
        end
        watch(slots[i])
      end
      UIManager:setDirty(screen, "ui")
      emu:pump()
      emu:screenNodes()
      for _, reset in ipairs(restore) do reset() end
      for i, drawn in ipairs(painted) do
        local icon, value = drawn.icon, assert(drawn.value, "total not painted")
        if hidden and i == 1 then
          assert(not icon, "hidden icon was painted")
        else
          assert(icon, keys[i] .. ": icon missing")
          if stacked then
            assert(icon.y + icon.h <= value.y, keys[i] .. ": icon not above number")
            assert(math.abs(icon.x + icon.w / 2 - value.x - value.w / 2) <= 1,
              keys[i] .. ": icon and number not centered")
          else
            assert(icon.x >= value.x + value.w, keys[i] .. ": icon not beside number")
          end
        end
      end
    end
    local requests = #fixtures.calls
    show(false)
    for _, text in ipairs({ "17", "Authors read", "84", "Books read", "19", "Five-star books", "12", "Rereads",
      "This month in", "On your TBR", "Added to Hardcover", "Another" }) do emu:expectText(text) end
    assert(#fixtures.calls == requests, "render made an API request")
    emu:shot("bookshelf_modules")

    -- Tap through Bookshelf's real coordinate translation, not spec.on_tap.
    local function tap(i, another)
      emu:screenNodes()
      local clip = assert(findClip(slots[i]), "no module tap regions")
      local r = clip[1]._tap_regions[1]
      local x = clip.dimen.x + clip._child_dx + (another and r.x + r.w / 2 or Theme.space.s)
      local y = clip.dimen.y + clip._child_dy + (another and r.y + r.h / 2 or Theme.space.s)
      emu:tapExpecting(math.floor(x), math.floor(y))
      emu:pump()
      if another then expectFit() end
    end
    local before = Modules.memoryCard(cache, user_id)
    tap(5, true)
    assert(entries[5].discovery_choice.offset == 1, "Another did not cycle this instance")
    local after = Modules.memoryCard(cache, user_id, nil, 1)
    assert(before.book_id ~= after.book_id)
    emu:expectText(after.title)
    assert(entries[6].discovery_choice == nil, "cycling memories also changed TBR")
    tap(6, true)
    assert(entries[6].discovery_choice.offset == 1, "TBR Another did not cycle")
    emu:shot("bookshelf_modules_another")
    tap(5, false)
    for _ = 1, 5 do emu:pump() end
    assert(manager.book_dialog and manager.book_dialog.detail, "main tap did not open Hardcover details")
    emu:expectText(after.title)
    manager.book_dialog:onClose()
    emu:pump()
    show(true)
    emu:shot("bookshelf_modules_wide")
    tap(5, true)
    tap(6, true)
    assert(entries[5].discovery_choice.offset == 2 and entries[6].discovery_choice.offset == 2,
      "wide buttons did not cycle")
    show(false, true)
    emu:shot("bookshelf_modules_small")
    tap(5, true)
    tap(6, true)

    -- Exercise the actual settings buttons and host save/re-fit path. The
    -- hidden button and whole-card cycling are independent per instance.
    local function tapText(text)
      local node = emu:expectText(text)
      assert(not node.relative, "unpainted settings control " .. text)
      emu:tapExpecting(math.floor(node.x + node.w / 2), math.floor(node.y + node.h / 2))
    end
    local function settings(i)
      SM.get(keys[i]).show_settings(Hero._ctx(nil, nil, entries[i]))
      emu:pump()
    end
    local function choose(i, label, value)
      settings(i)
      tapText(label)
      tapText(value)
      expectFit()
    end
    show(false)
    settings(5)
    for _, label in ipairs({ "Window: This month", "Reach: All previous years", "Cover: Hide",
      "Rating: Show", "Another button: Show", "Tap action: Open book details" }) do emu:expectText(label) end
    emu:shot("bookshelf_memories_settings")
    tapText("Window:")
    tapText("This day")
    choose(5, "Reach:", "Last year")
    choose(5, "Cover:", "Show")
    choose(5, "Rating:", "Hide")
    choose(5, "Another button:", "Hide")
    choose(5, "Tap action:", "Show another saved book")
    choose(6, "Cover:", "Hide")
    choose(6, "Another button:", "Hide")
    choose(6, "Tap action:", "Show another saved book")
    choose(1, "Icon:", "Hide")
    emu:expectText("This day in")
    local visible = emu:screenText()
    assert(not visible:find("Another", 1, true) and not visible:find("Your rating:", 1, true))
    assert(#findClip(slots[5])[1]._tap_regions == 0 and #findClip(slots[6])[1]._tap_regions == 0)
    local offset = entries[5].discovery_choice.offset
    tap(5, false)
    assert(entries[5].discovery_choice.offset == offset + 1)
    assert(entries[6].discovery_choice.offset == 3, "memory tap changed another instance")
    emu:shot("bookshelf_modules_custom")
    show(true)
    emu:shot("bookshelf_modules_custom_wide")
    show(false, true)
    emu:shot("bookshelf_modules_custom_small")
    -- Restore defaults for the existing offline/empty-state checks below.
    for _, entry in ipairs(entries) do
      for _, name in ipairs({ "memory_window", "memory_reach", "show_cover", "show_rating",
        "show_another", "show_icon", "tap_action" }) do entry[name] = nil end
    end

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

    -- The uncached-cover and no-data states use the same real host.
    for _, row in ipairs(tbr) do row.cached_image = nil end
    shelves:putEntries(user_id, 1, tbr, true, "fixture")
    app._bookshelf_tbr = nil
    show(false)
    emu:shot("bookshelf_modules_no_cover")
    cache:invalidate(user_id, { 3 })
    show(false)
    emu:shot("bookshelf_modules_saved")
    showLargeTotals() -- stale, complete history still shows the actual totals
    expectTotalLayout(false)
    local size = math.floor((width - gap) / 2)
    -- Grid rounding can leave a square-looking cell a pixel taller than it
    -- is wide. Bookshelf still classifies this as square, not portrait.
    showLargeTotals(size, size + 1, "bookshelf_totals_near_square")
    expectTotalLayout(false)
    showLargeTotals(math.floor(size * 0.8), size, "bookshelf_totals_square_band")
    expectTotalLayout(false)
    local tall_w = math.floor(width / 3)
    showLargeTotals(tall_w, size, "bookshelf_totals_tall")
    expectTotalLayout(true)
    choose(1, "Icon:", "Hide")
    expectTotalLayout(true, true)
    emu:shot("bookshelf_totals_tall_no_icon")
    choose(1, "Icon:", "Show")
    expectTotalLayout(true)
    showLargeTotals(size, math.floor(size / 2), "bookshelf_totals_wide")
    expectTotalLayout(false)
    show(false, true)
    cache:putStats(user_id, { rows = {} }) -- pre-upgrade history is unknown, not zero
    show(false, true)
    emu:expectText("Load Stats")
    emu:shot("bookshelf_modules_first_load")
    cache:putStats(user_id, { rows = {}, history = {}, complete = true })
    shelves:putEntries(user_id, 1, {}, true, "empty")
    app._bookshelf_tbr = nil
    show(false)
    emu:expectText("No finishes this month in earlier years.")
    emu:expectText("No books saved before this month on Want to Read.")
    emu:shot("bookshelf_modules_empty")
    emu:closeAll()
    db:close()
  end,
}
