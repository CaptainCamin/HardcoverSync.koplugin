--[[--
The panel resized while the shell is up (issue #341): a window made smaller on a device or
emulator left the shell and its tab bodies at the old size, so wide content was clipped at the
right edge and the navigation bar sat below the panel, with no scroll to reach it. A
SetDimensions event rebuilds the shell and its bodies at the new size: the nav bar is back on
screen, and a Home too tall for the smaller panel scrolls, so Sync now stays tappable. Growing
the panel again rebuilds a Home that fits, with no scroll.

Screens: shell_resize_shrunk, shell_resize_restored.
]]

local fixtures = require("fixtures")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

return {
  name = "shell_resize",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_shell_resize.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local sent_now = 0
    local manager = DialogManager:new { settings = settings,
      sync_queue = { finishedCount = function() return 0 end, pendingCount = function() return 0 end,
        changeCount = function() return 0 end, conflictCount = function() return 0 end,
        decisions = function() return {} end,
        shelfOp = function() return nil end, keys = function() return {} end },
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
      send_now = function() sent_now = sent_now + 1 end }

    manager:showHome()
    emu:pump()
    local shell = UIManager:getTopmostVisibleWidget()
    assert(shell and shell.name == "hardcover_shell", "Home did not open the shell")

    local Home = require("hardcover/lib/home")
    local home = shell.bodies.home
    home:setReading(fixtures.currently_reading)
    home:setRows(Home.rows(fixtures.shelf_counts))
    emu:pump()

    -- A SetDimensions event follows the device screen's own resize (sdl/device.lua), so the
    -- screen reports the new size first, as on a real window resize.
    local real_w, real_h = Screen.getWidth, Screen.getHeight
    local W, H = Screen:getWidth(), Screen:getHeight()
    local function resize(w, h)
      Screen.getWidth = function() return w end
      Screen.getHeight = function() return h end
      UIManager:broadcastEvent(Event:new("SetDimensions", Geom:new { w = w, h = h }))
      emu:pump()
    end

    -- the nav bar is the last row of the shell's column: its cells' painted bottom is the
    -- panel's bottom only if the shell rebuilt at the new size (positions are real once painted)
    local function nav_inside(w, h)
      emu:screenNodes()
      local row = shell.frame[1] and shell.frame[1][3] and shell.frame[1][3][3]
      local first, last = row and row[1], row and row[#row]
      return first and last and first.dimen.x == 0 and last.dimen.x + last.dimen.w == w
        and last.dimen.y + last.dimen.h == h or false
    end

    local function find_button(widget, label, seen)
      seen = seen or {}
      if type(widget) ~= "table" or seen[widget] then return end
      seen[widget] = true
      if widget.name == "hardcover_tap_row" and widget.text == label then return widget end
      for k, v in pairs(widget) do
        if type(k) == "number" and type(v) == "table" then
          local found = find_button(v, label, seen)
          if found then return found end
        end
      end
    end

    -- shrunk: the shell and its body are rebuilt at the new size, the nav bar is on screen and
    -- a page that cannot fit scrolls
    local W2, H2 = math.floor(W * 0.5), math.floor(H * 0.3)
    resize(W2, H2)
    assert(shell.dimen.w == W2 and shell.dimen.h == H2, "the shell kept its old size")
    assert(shell.frame:getSize().w == W2 and shell.frame:getSize().h == H2,
      "the shell kept its old frame")
    local small = shell.bodies.home
    assert(small and small ~= home, "the Home body was not rebuilt for the new size")
    assert(small.width == W2, "the Home body kept its old width: " .. tostring(small.width))
    assert(nav_inside(W2, H2), "the nav bar is off the smaller panel")
    assert(small.scroll, "a Home too tall for the smaller panel did not scroll")
    assert(small.layout.note, "the sync box was dropped instead of scrolling to reach it")

    -- page down until the sync box's Sync now is inside the scroll's view (a child's dimen is
    -- in screen space already, so inside the view means tappable there), then tap it
    emu:screenNodes() -- paint, so the scroll area and the button know where they are
    local sc = small.scroll
    local control_x = sc.dimen.x + sc.dimen.w - 10
    local bottom_y = sc.dimen.y + sc.dimen.h - 10
    local function visible(widget)
      return widget and widget.dimen.y >= sc.dimen.y
        and widget.dimen.y + widget.dimen.h <= sc.dimen.y + sc.dimen.h
    end
    local sync
    for _ = 1, 30 do
      emu:screenNodes()
      sync = find_button(small, "Sync now")
      if visible(sync) then break end
      if sc:getScrolledOffset().y >= (sc._max_scroll_offset_y or 0) then break end
      emu:tapExpecting(control_x, bottom_y)
      emu:pump()
    end
    assert(visible(sync), "Sync now never scrolled into reach")
    assert(sync.dimen.x >= sc.dimen.x and sync.dimen.x + sync.dimen.w <= sc.dimen.x + sc.dimen.w,
      "Sync now sticks out of the panel")
    emu:shot("shell_resize_shrunk")
    emu:tapExpecting(sync.dimen.x + math.floor(sync.dimen.w / 2),
      sync.dimen.y + math.floor(sync.dimen.h / 2))
    emu:pump()
    assert(sent_now == 1, "Sync now did not send from the shrunk panel")

    -- a tap on the nav bar reaches the tab it sits over, and back (its cells are painted, so
    -- their ranges are real)
    local nav_row = shell.frame[1][3][3]
    local last_cell = nav_row[#nav_row]
    emu:tapExpecting(last_cell.dimen.x + math.floor(last_cell.dimen.w / 2),
      last_cell.dimen.y + math.floor(last_cell.dimen.h / 2))
    assert(shell.active == "stats", "a tap on the nav bar did not switch tabs")
    emu:screenNodes()
    nav_row = shell.frame[1][3][3]
    local first_cell = nav_row[1]
    emu:tapExpecting(first_cell.dimen.x + math.floor(first_cell.dimen.w / 2),
      first_cell.dimen.y + math.floor(first_cell.dimen.h / 2))
    assert(shell.active == "home", "a tap on the nav bar did not return to Home")

    -- a mirrored layout reserves the scroll gutter on the left (KOReader crops its content in
    -- from that edge), so the arrows go there: page down until a shelf row reaches the up
    -- arrow's height, then tap it -- the page scrolls back, the shelf does not open
    local Bidi = require("ui/bidi")
    Bidi._mirrored_ui_layout = true
    resize(W2, H2)
    local mirrored = shell.bodies.home
    assert(mirrored and mirrored.scroll, "mirrored Home did not scroll")
    local msc = mirrored.scroll
    local touch = require("hardcover/lib/ui/theme").TOUCH_MIN
    local function shelf_row_at(top, bottom)
      for _, title in ipairs({ "Want to Read", "Currently Reading", "Read", "Did Not Finish" }) do
        local row = find_button(mirrored, title)
        if row and row.dimen.y < bottom and row.dimen.y + row.dimen.h > top then return row end
      end
    end
    local arrow_row
    for _ = 1, 30 do
      emu:screenNodes()
      if (msc:getScrolledOffset().y or 0) > 0 then
        arrow_row = shelf_row_at(msc.dimen.y, msc.dimen.y + touch)
        if arrow_row then break end
      end
      if msc:getScrolledOffset().y >= (msc._max_scroll_offset_y or 0) then break end
      emu:tapExpecting(msc.dimen.x + 10, msc.dimen.y + msc.dimen.h - 10)
      emu:pump()
    end
    assert(arrow_row, "no shelf row reached the mirrored up arrow")
    local before = msc:getScrolledOffset().y
    local tap_y = math.floor((math.max(arrow_row.dimen.y, msc.dimen.y)
      + math.min(arrow_row.dimen.y + arrow_row.dimen.h, msc.dimen.y + touch)) / 2)
    emu:tapExpecting(msc.dimen.x + 10, tap_y)
    emu:pump()
    assert(msc:getScrolledOffset().y < before, "the mirrored up arrow did not scroll")
    assert(UIManager:getTopmostVisibleWidget() == shell,
      "a tap on the mirrored scroll arrow opened a shelf")
    Bidi._mirrored_ui_layout = false

    -- grown again: rebuilt once more. Grown taller than the content needs, a Home that fits has
    -- no scroll; back at the panel's own size nothing is dropped -- the sync box and every
    -- shelf row stay reachable (by the scroll when the panel is short of them).
    resize(W, H * 2)
    local grown = shell.bodies.home
    assert(grown and grown ~= mirrored, "the Home body was not rebuilt on the way back")
    assert(grown.width == W and not grown.scroll
      and grown.layout.shelves == grown.layout.total_shelves,
      "the grown Home did not fill its panel")
    resize(W, H)
    Screen.getWidth, Screen.getHeight = real_w, real_h
    local restored = shell.bodies.home
    assert(restored and restored ~= grown, "the Home body was not rebuilt on the way back")
    assert(restored.width == W, "the restored Home did not fill its panel")
    assert(restored.layout.note and restored.layout.shelves == restored.layout.total_shelves,
      "the restored Home dropped the sync box or a shelf row")
    assert(nav_inside(W, H), "the nav bar is off the restored panel")
    emu:shot("shell_resize_restored")
  end,
}
