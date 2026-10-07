--[[--
PROTOTYPE -- throwaway. The modular-Home variants, rendered through the real
showHome path with fixture data. Run: spec/emu/prototype_modular_home.sh

Screens: home_proto_A, home_proto_A_edit, home_proto_A_reordered, home_proto_B,
home_proto_C_reading, home_proto_C_shelves, home_proto_C_goal.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function iso(days)
  local t = os.date("*t", os.time() + days * 86400)
  return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

local function center(w)
  local r = w.dimen
  return r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2)
end

return {
  name = "home_modular_prototype",

  run = function(emu)
    local P = require("hardcover/lib/ui/home_modular_prototype")
    G_reader_settings:saveSetting(P.SETTING, "A")

    local settings = fixtures.real_settings(emu)
    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_proto.lua"
    os.remove(path)
    for _, id in ipairs({ 101, 102 }) do
      fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg")
    end
    fixtures.install({
      settings = settings,
      goals_rows = {
        { id = 3, goal = 70, metric = "book", description = "Year Reading Goal",
          start_date = iso(-200), end_date = iso(165), progress = 46.0, archived = false },
      },
    })
    local manager = require("hardcover/lib/ui/dialog_manager"):new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
    }

    manager:showHome()
    emu:pump()
    local d = manager.home_dialog
    assert(d and d.prototype_variant == "A", "the prototype variant was not picked up")
    assert(type(d.goals) == "table" and #d.goals > 0, "no goals reached Home")

    local function show(key)
      P.select(d, key)
      emu:pump()
      assert(UIManager:getTopmostVisibleWidget() == d, "Home is not on top")
      emu:expectText("PROTOTYPE  " .. key)
    end

    -- a book card / hero opens that book, whatever the layout
    local function tapBook(title)
      local node = emu:expectText(title)
      emu:tapExpecting(node.x + 5, node.y + 5)
      local top = UIManager:getTopmostVisibleWidget()
      assert(top and top.name == "hardcover_book_detail", "tapping " .. title .. " did not open the book")
      UIManager:close(top)
      emu:pump()
    end

    --[[ A: Stack ]]
    show("A")
    emu:expectText("Customize Home")
    emu:expectText("Year Reading Goal")
    emu:shot("home_proto_A")
    if not d.scroll then tapBook("The Dispossessed") end

    -- edit mode (the button is below the fold on a scrolling page: its callback)
    d.customize_button.callback()
    emu:pump()
    emu:expectText("Up")
    emu:shot("home_proto_A_edit")
    -- move the goal up twice, hide Discover, leave edit mode
    local i_goal
    for i, k in ipairs(P.state.order) do if k == "goal" then i_goal = i end end
    P.state.order[i_goal], P.state.order[i_goal - 1] = P.state.order[i_goal - 1], P.state.order[i_goal]
    i_goal = i_goal - 1
    P.state.order[i_goal], P.state.order[i_goal - 1] = P.state.order[i_goal - 1], P.state.order[i_goal]
    P.state.hidden.discover = true
    P.state.editing = false
    d:rebuild()
    emu:pump()
    assert(P.state.order[2] == "goal", "the goal did not move up")
    emu:shot("home_proto_A_reordered")

    --[[ B: Dashboard -- the switcher's own arrow ]]
    emu:tapExpecting(center(d.proto_next))
    assert(d.prototype_variant == "B", "the › arrow did not move to B")
    emu:expectText("NOW READING")
    assert(not d.scroll, "the dashboard scrolls; it is meant to fit")
    emu:shot("home_proto_B")
    tapBook("The Dispossessed")

    --[[ C: Tabs ]]
    show("C")
    emu:shot("home_proto_C_reading")
    tapBook("A Wizard of Earthsea")
    for _, tab in ipairs({ "shelves", "goal" }) do
      emu:tapExpecting(center(d.proto_tabs[tab]))
      assert(P.state.tab == tab, "the " .. tab .. " tab did not open")
      emu:shot("home_proto_C_" .. tab)
    end

    -- wraps around: › from C is A
    emu:tapExpecting(center(d.proto_next))
    assert(d.prototype_variant == "A", "the switcher did not wrap")

    G_reader_settings:delSetting(P.SETTING)
    emu:closeAll()
  end,
}
