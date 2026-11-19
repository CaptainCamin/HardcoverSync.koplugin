--[[--
Home given too little room for its card, or just enough for the card but not the sync box (issue
#341): the body must stay inside the room it was given, with the rest reachable through the plugin's
visible scroll control, so Sync now can be tapped and a shell's nav bar cannot be pushed off screen.

Screens: home_overflow, home_sync_scroll.
]]--

local fixtures = require("fixtures")
local Device = require("device")
local UIManager = require("ui/uimanager")

local Home = require("hardcover/lib/home")
local HomeBody = require("hardcover/lib/ui/home_body")

local function find_button(widget, label, seen)
  seen = seen or {}
  if type(widget) ~= "table" or seen[widget] then return end
  seen[widget] = true
  if widget.text == label and widget.callback and widget.dimen and widget.dimen.w > 0 then
    return widget
  end
  for _, child in ipairs(widget) do
    local found = find_button(child, label, seen)
    if found then return found end
  end
end

return {
  name = "home_overflow",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local h = math.floor(Device.screen:scaleBySize(150))
    local shelves = Home.rows(fixtures.shelf_counts)
    local home_shelves = Home.homeOrder(shelves) -- Home leaves Paused out
    local shell = { isActive = function() return true end }
    local body = HomeBody:new {
      shell = shell, width = Device.screen:getWidth(), height = h,
      entries = fixtures.currently_reading,
      rows = shelves,
    }
    UIManager:show(body, "full")
    emu:pump()

    assert(body.scroll, "the overflowing Home has no scroll")
    local size = body[1]:getSize()
    assert(size.h <= h, string.format("Home grew to %d in %d of room", size.h, h))
    assert(size.w <= body.dimen.w, "Home grew past the side of the screen")
    assert(body.layout.note, "the scrollable Home dropped the sync box")
    assert(body.layout.shelves == #home_shelves, "the scrollable Home dropped shelf rows")
    emu:shot("home_overflow")

    -- The down and up triangles are the visible control, distinct from the container's page keys.
    emu:screenNodes()
    local control_x = Device.screen:getWidth() - 10
    local top_y = body.scroll.dimen.y + 20
    local bottom_y = body.scroll.dimen.y + h - 20
    emu:tap(control_x, bottom_y)
    emu:pump()
    assert(body.scroll:getScrolledOffset().y > 0, "the down triangle did not scroll")
    emu:tap(control_x, top_y)
    emu:pump()
    assert(body.scroll:getScrolledOffset().y == 0, "the up triangle did not return to the top")

    -- Page keys still scroll the same container.
    local before = body.scroll:getScrolledOffset().y
    emu:press("LPgFwd")
    emu:pump()
    assert(body.scroll:getScrolledOffset().y > before, "the page keys cannot scroll Home")

    -- A page with room for the card but not the note is the case where the sync box alone has to
    -- make Home scroll. Derive that height from the widgets just measured rather than a DPI guess.
    local column = body.scroll[1]
    local used, note_h = 0, column[5]:getSize().h
    for i = 1, 4 do used = used + column[i]:getSize().h end
    local note_room = math.floor(used + note_h - 1)
    emu:closeAll()

    local syncs = 0
    local note_body = HomeBody:new {
      shell = shell, width = Device.screen:getWidth(), height = note_room,
      entries = fixtures.currently_reading, rows = shelves,
      sync_cb = function() syncs = syncs + 1 end,
    }
    UIManager:show(note_body, "full")
    emu:pump()
    assert(note_body.scroll, "the sync box alone did not make Home scroll")
    assert(note_body.layout.note, "the note-only scroll dropped the sync box")
    assert(note_body.layout.shelves == #home_shelves, "the note-only scroll dropped shelf rows")
    assert(note_body[1]:getSize().h <= note_room, "Home grew past the note-only room")

    -- Bring the sync box into view with the visible arrows, not by setting the offset directly.
    local sc = note_body.scroll
    local note_column = sc[1]
    local note_top = 0
    for i = 1, 4 do note_top = note_top + note_column[i]:getSize().h end
    local note_bottom = note_top + note_column[5]:getSize().h
    emu:screenNodes()
    local note_control_x = Device.screen:getWidth() - 10
    local note_top_y = sc.dimen.y + 20
    local note_bottom_y = sc.dimen.y + note_room - 20
    for _ = 1, 12 do
      local offset = sc:getScrolledOffset().y
      if note_top - offset < note_room and note_bottom - offset > 0 then break end
      emu:tap(note_control_x, note_bottom - offset > note_room and note_bottom_y or note_top_y)
      emu:pump()
    end
    local offset = sc:getScrolledOffset().y
    assert(note_top - offset < note_room and note_bottom - offset > 0,
      "the arrows could not bring Sync now into view")
    emu:screenNodes()
    emu:shot("home_sync_scroll")
    local button = find_button(note_body, "Sync now")
    assert(button and button.dimen, "Sync now is not in the scrolled Home")
    local bx = button.dimen.x + math.floor(button.dimen.w / 2)
    local by = button.dimen.y + offset + math.floor(button.dimen.h / 2)
    assert(by >= 0 and by <= note_room, string.format("Sync now tap at %d outside %d", by, note_room))
    emu:tap(bx, by)
    emu:pump()
    assert(syncs == 1, "tapping Sync now in the scrolled Home did not send")
    emu:closeAll()
  end,
}
