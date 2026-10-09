--[[--
Title bar reload: book details has a reload icon just left of the X. The two tap areas do
not overlap, a tap on the reload icon reloads and leaves the screen open, and a tap on the
X still quits the plugin.
]]

local fixtures = require("fixtures")
local perf = require("perf")
local Theme = require("hardcover/lib/ui/theme")
local UIManager = require("ui/uimanager")
local ScreenRegistry = require("hardcover/lib/screen_registry")

local function plugin_windows()
  local stack = {}
  for i = #UIManager._window_stack, 1, -1 do stack[#stack + 1] = UIManager._window_stack[i].widget end
  return ScreenRegistry.pluginWindows(stack)
end

local function seed_all()
  for _, b in ipairs(fixtures.shelf_books) do
    local image = b.cached_image
    if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
  end
  for _, id in ipairs({ 101, 102, 103, 106, 109 }) do fixtures.seed_cover(fixtures.cover_url(id), id % 3 + 1) end
  for _, series in pairs(fixtures.series_books) do
    for _, b in ipairs(series.books) do fixtures.seed_cover(fixtures.cover_url(b.book_id), b.book_id % 3 + 1) end
  end
end

local function centre(button)
  return button.dimen.x + math.floor(button.dimen.w / 2), button.dimen.y + math.floor(button.dimen.h / 2)
end

return {
  name = "title_bar_reload",

  run = function(emu)
    seed_all()
    local manager, settings = perf.new_manager(emu, fixtures, "title_bar_reload")
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })

    -- the class default: every dialog the manager builds gets the reload icon
    local BookDetailDialog = require("hardcover/lib/ui/book_detail_dialog")
    local refreshed = 0
    BookDetailDialog.on_refresh = function(dialog) refreshed = refreshed + 1 end

    manager:showBookDetail(103)
    perf.run_loop()
    -- the manager keeps no reference to the dialog, so take the top of the stack
    local dialog = emu:top()
    assert(dialog and dialog.name == "hardcover_book_detail", string.format(
      "book details did not open on top (top is %s)", tostring(dialog and dialog.name)))
    assert(#plugin_windows() > 0, "book details is not counted as a plugin window")

    local bar = dialog.title_bar
    assert(bar, "book details has no title bar")
    local reload = bar.extra_right_button
    local close = bar.right_button
    assert(reload, "the title bar has no reload button")
    assert(close, "the title bar has no X")

    emu:shot("title_bar_reload")
    assert(reload.dimen and close.dimen, "the title bar buttons are not painted")

    -- the reload tap area ends where the X's begins, and both are at least a touch target wide
    assert(reload.dimen.x + reload.dimen.w <= close.dimen.x, string.format(
      "reload (%d..%d) overlaps the X (from %d)",
      reload.dimen.x, reload.dimen.x + reload.dimen.w, close.dimen.x))
    assert(reload.dimen.w >= Theme.TOUCH_MIN, string.format(
      "reload tap area is %dpx, under TOUCH_MIN %d", reload.dimen.w, Theme.TOUCH_MIN))
    assert(close.dimen.w >= Theme.TOUCH_MIN, string.format(
      "X tap area is %dpx, under TOUCH_MIN %d", close.dimen.w, Theme.TOUCH_MIN))

    -- a tap on reload reloads, and the screen stays open
    emu:tapExpecting(centre(reload))
    perf.run_loop()
    assert(refreshed == 1, string.format("reload ran %d time(s), expected 1", refreshed))
    assert(#plugin_windows() > 0, "the reload tap quit the plugin")

    -- the X closes the window it is in, so the tap is not "consumed" by a screen that is still
    -- there: judge it by what is left on the stack
    emu:tap(centre(close))
    perf.run_loop()
    local left = #plugin_windows()
    assert(left == 0, string.format("the X left %d plugin screen(s) open", left))

    BookDetailDialog.on_refresh = nil
    print(string.format("  title bar: reload tap %dx%d, X tap %dx%d; reload ran %d time, the X quit the plugin",
      reload.dimen.w, reload.dimen.h, close.dimen.w, close.dimen.h, refreshed))
  end,
}
