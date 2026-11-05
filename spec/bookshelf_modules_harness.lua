-- The goal and stats cards Hardcover Sync gives Bookshelf's micro-modules:
-- the module pack in bookshelf_modules/ (loaded here the way Bookshelf loads
-- it), what the cards say, and the cleanup of the stub files older versions
-- wrote into Bookshelf's own module folder.
--
-- Run with:  lua spec/bookshelf_modules_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

-- ------------------------------------------------------------ Bookshelf's side
-- Bookshelf hands a pack file its own folder as `...` and calls the chunk with
-- it (lib/bookshelf_start_menu_modules.lua, loadSpec), so load it the same way.
local PACK_DIR = PLUGIN .. "/bookshelf_modules"
local function loadPack(name)
  local chunk = assert(loadfile(PACK_DIR .. "/" .. name .. ".lua"))
  return chunk(PACK_DIR)
end

-- The kit the plugin draws with. It captures the card it is asked for, so the
-- assertions read what the plugin handed Bookshelf rather than a rendered
-- widget tree (which would need a screen).
local kit_has_plugin = true
local kit_strip = false
local plugin_instance
local card_args          -- the last card the kit was asked for
local cards_drawn = {}   -- every card, for a render that asks for two
local widgets_drawn = {} -- the stand-in widgets those cards came back as
local function clear() card_args = nil; cards_drawn = {}; widgets_drawn = {} end
package.preload["lib/bookshelf_module_kit"] = function()
  local Kit = {
    valueCard = function(o)
      card_args = o
      cards_drawn[#cards_drawn + 1] = o
      -- The real card is a group with a natural height; the strip's rule is as
      -- tall as the taller half, so the stand-in needs one too.
      local lines = (o.heading and 1 or 0) + (o.value and 1 or 0)
        + (o.sub and 1 or 0) + (o.context and 1 or 0)
      local widget = { card = o,
        getSize = function() return { w = o.width or 0, h = lines * 20 } end }
      widgets_drawn[#widgets_drawn + 1] = widget
      return widget
    end,
    progressBar = function(o)
      return { bar = o,
        getSize = function() return { w = o.width or 0, h = o.height or 0 } end }
    end,
    sc = function(scale) local s = (scale or 100) / 100; return function(n) return math.floor(n * s + 0.5) end end,
    face = function(size) return size or 15, false end,
    fitText = function(o)
      return require("lib/bookshelf_colour_text"):new { text = o.text, face = o.size }
    end,
    isStrip = function() return kit_strip end,
    radioRow = function(o)
      return {
        text = (o.active and "\226\156\147 " or "  ") .. o.label,
        callback = function()
          if o.active and not o.toggle then return end
          o.on_pick()
        end,
      }
    end,
    withClose = function(spec) return spec end,
  }
  if kit_has_plugin then Kit.plugin = function() return plugin_instance end end
  return Kit
end

-- The ring card builds its own widget tree instead of asking the kit for a
-- card, so stand in for the widgets it uses and record the text it draws and
-- the ring it paints. Text widths are rough but grow with the text, which is
-- all the card's layout maths needs.
local ring_texts, ring_paints = {}, 0
do
  local function class()
    local C = {}
    C.__index = C
    function C.new(self, o)
      o = o or {}
      setmetatable(o, self)
      if o.init then o:init() end
      return o
    end
    function C.extend(_, o)
      local sub = o or {}
      sub.__index = sub
      sub.new = C.new
      return sub
    end
    function C:free() end
    function C:resetLayout() end
    return C
  end

  local Widget = class()
  package.preload["ui/widget/widget"] = function() return Widget end
  package.preload["ui/geometry"] = function()
    return { new = function(_, o) return o end }
  end

  local function group(axis)
    local G = class()
    function G:getSize()
      local w, h = 0, 0
      for _, child in ipairs(self) do
        local s = child:getSize()
        w = axis == "x" and w + s.w or math.max(w, s.w)
        h = axis == "x" and math.max(h, s.h) or h + s.h
      end
      return { w = w, h = h }
    end
    return G
  end
  local VGroup, HGroup = group("y"), group("x")
  package.preload["ui/widget/verticalgroup"] = function() return VGroup end
  package.preload["ui/widget/horizontalgroup"] = function() return HGroup end

  local Span = class()
  function Span:init() self.dimen = { w = self.width or 0, h = 0 } end
  function Span:getSize() return self.dimen end
  package.preload["ui/widget/verticalspan"] = function() return Span end
  package.preload["ui/widget/horizontalspan"] = function() return Span end

  local Box = class()
  function Box:init() self.dimen = self.dimen or { w = 0, h = 0 } end
  function Box:getSize() return self.dimen end
  package.preload["ui/widget/overlapgroup"] = function() return Box end
  package.preload["ui/widget/container/centercontainer"] = function() return Box end

  local Text = class()
  function Text:init()
    local s = tostring(self.text or "")
    self.is_text = true
    ring_texts[#ring_texts + 1] = s
    -- A line's height follows its face, the way a real one does: the card's
    -- layout maths is all about how many lines fit in a cell.
    local size = type(self.face) == "number" and self.face or 15
    self.dimen = { w = #s * 7, h = math.max(8, math.floor(size * 1.4)) }
  end
  function Text:getSize() return self.dimen end
  function Text:getBaseline() return 12 end
  function Text:paintTo() end
  package.preload["lib/bookshelf_colour_text"] = function() return Text end

  package.preload["lib/bookshelf_color"] = function()
    return { paintRect = function() ring_paints = ring_paints + 1 end }
  end
  package.preload["ffi/blitbuffer"] = function()
    return {
      COLOR_BLACK = { getColor8 = function(self) return self end, a = 0 },
      Color8 = function(v)
        return { a = v, getColor8 = function(self) return self end }
      end,
    }
  end
  package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, n) return n end } }
  end
end
support.preload_theme_stubs()

local current_user_id = 7
package.preload["hardcover/lib/user"] = function()
  return { settings = { readSetting = function() return current_user_id end } }
end

-- The cleanup test needs a real directory listing, so back the lfs stand-in
-- with the shell.
local function sh(cmd)
  local p = io.popen(cmd)
  local out = p:read("*l")
  p:close()
  return out
end
package.preload["libs/libkoreader-lfs"] = function()
  return {
    attributes = function(path)
      if sh("test -d '" .. path .. "' && echo directory") then return "directory" end
      local f = io.open(path, "rb")
      if f then f:close() return "file" end
      return nil
    end,
    dir = function(path)
      local p = io.popen("ls -1 '" .. path .. "' 2>/dev/null")
      local names = {}
      for name in p:lines() do names[#names + 1] = name end
      p:close()
      local i = 0
      return function() i = i + 1; return names[i] end
    end,
  }
end

local Goals = require("hardcover/lib/goals")
local Modules = require("hardcover/lib/bookshelf_modules")
-- The card renders at the real "today", so the fixtures run either side of it:
-- they never expire, whenever the suite is run.
local TODAY = Goals.today()

local function cache(goals, stats)
  return {
    goals = function() return goals end,
    stats = function() return stats end,
  }
end

local year_goal = { id = 1, name = "Reading goal", metric = "book", target = 70, progress = 46,
  start_days = TODAY - 180, end_days = TODAY + 180 }

-- Ends sooner than the year goal, so it is the one a card shows by default.
local pages_goal = { id = 2, name = "Pages goal", metric = "page", target = 3000, progress = 900,
  start_days = TODAY - 10, end_days = TODAY + 10 }

-- ------------------------------------------------------------------- the pack

check("the cards ship as Bookshelf module pack files", function()
  for _, key in ipairs({ "hardcover_goal", "hardcover_goal_ring", "hardcover_stats", "hardcover_year" }) do
    local spec = loadPack(key)
    assert(type(spec) == "table", key .. " did not return a spec")
    assert(spec.key == key, tostring(spec.key))
    assert(type(spec.title) == "string" and spec.title ~= "", key .. " title")
    assert(type(spec.summary) == "string" and spec.summary:find("offline"), key .. " summary")
    assert(type(spec.render) == "function" and type(spec.on_tap) == "function", key .. " handlers")
    -- The bar and stats cards are sentences, so they need two cells to read; the
    -- ring drops to a bare ring in a short cell and can be a single tile.
    local min_w = (key == "hardcover_goal_ring") and 1 or 2
    assert(spec.min_w == min_w, key .. " min_w " .. tostring(spec.min_w))
    -- The goal cards let the reader pick which goal they show.
    if key == "hardcover_goal" or key == "hardcover_goal_ring" then
      assert(type(spec.show_settings) == "function", key .. " settings")
    end
    -- No category or pack name: the cards belong under the plugin's own chip.
    assert(spec.category == nil and spec.pack == nil, key .. " grouping")
  end
end)

check("a Bookshelf too old for Kit.plugin gets no card", function()
  kit_has_plugin = false
  package.loaded["lib/bookshelf_module_kit"] = nil
  local ok, spec = pcall(loadPack, "hardcover_goal")
  kit_has_plugin = true
  package.loaded["lib/bookshelf_module_kit"] = nil
  assert(ok, spec)
  assert(type(spec) == "table" and spec.key == nil, "expected an empty list")
end)

-- ------------------------------------------------------------------ rendering

local opened
local function app(goals, stats)
  return {
    shelf_cache = cache(goals, stats),
    dialog_manager = {
      finishedOffline = function() return 0 end,
      showGoals = function() opened = "goals" end,
      showStats = function() opened = "stats" end,
    },
  }
end

local ctx = { width = 300, height = 150, scale = 100 }

check("goal card shows progress, target and pace", function()
  local c = Modules.goalCard(cache({ year_goal }), nil, 7, 0, TODAY)
  assert(c.heading == "Reading goal")
  assert(c.value == "46" and c.suffix == " / 70 books", c.suffix)
  assert(c.fraction > 0.65 and c.fraction < 0.66)
  assert(c.sub:find("pace"), c.sub)
end)

check("goal card counts books finished offline", function()
  local c = Modules.goalCard(cache({ year_goal }), nil, 7, 2, TODAY)
  assert(c.value == "48", c.value)
end)

check("goal card says why there is nothing to show", function()
  local _, why = Modules.goalCard(cache(nil), nil, 7, 0, TODAY)
  assert(why == "no_data")
  _, why = Modules.goalCard(cache({}), nil, 7, 0, TODAY)
  assert(why == "no_goal")
  _, why = Modules.goalCard(cache({ year_goal }), nil, nil, 0, TODAY)
  assert(why == "signed_out")
end)

check("goal module draws the saved goal", function()
  plugin_instance = app({ year_goal })
  current_user_id = 7
  clear()
  loadPack("hardcover_goal").render(ctx)
  assert(card_args, "no card drawn")
  assert(card_args.heading == "Reading goal", tostring(card_args.heading))
  assert(card_args.value == "46", tostring(card_args.value))
  assert(card_args.bar and card_args.bar.bar.fraction > 0.65, "no progress bar")
  assert(card_args.bar_fraction > 0.65, "no bar fraction for the strip layout")
end)

check("goal module puts two goals on a strip, each with its own bar", function()
  plugin_instance = app({ year_goal, pages_goal })
  current_user_id = 7
  clear()
  local group = loadPack("hardcover_goal").render({ width = 900, height = 260, scale = 100 })
  assert(#cards_drawn == 2, "expected two cards, got " .. #cards_drawn)
  -- Soonest-ending first, the same order the card has always used.
  assert(cards_drawn[1].heading == "Pages goal", tostring(cards_drawn[1].heading))
  assert(cards_drawn[2].heading == "Reading goal", tostring(cards_drawn[2].heading))
  -- Each half gets half the strip, less the gutter the rule sits in.
  for _, c in ipairs(cards_drawn) do
    assert(c.width == 430, "half width " .. tostring(c.width))
    assert(c.bar and c.bar.bar.width == 430, "bar not the width of its half")
    assert(c.context == nil, "the pace line belongs on a single goal")
  end
  assert(cards_drawn[1].bar.bar.fraction > 0.29 and cards_drawn[1].bar.bar.fraction < 0.31)
  assert(cards_drawn[2].bar.bar.fraction > 0.65 and cards_drawn[2].bar.bar.fraction < 0.66)
  -- A rule divides the two halves: an unfilled bar, as tall as the taller one.
  local rule
  for _, child in ipairs(group) do
    if child.bar and child.bar.fraction == 0 then rule = child.bar end
  end
  assert(rule, "no rule between the two goals")
  assert(rule.width >= 1, "the rule has no width")
  assert(rule.height == math.max(widgets_drawn[1]:getSize().h, widgets_drawn[2]:getSize().h),
    "the rule is not as tall as the taller half: " .. tostring(rule.height))
end)

check("goal module keeps one goal on a cell that is wide but not a strip", function()
  plugin_instance = app({ year_goal, pages_goal })
  current_user_id = 7
  clear()
  loadPack("hardcover_goal").render({ width = 430, height = 240, scale = 100 })
  assert(#cards_drawn == 1, "expected one card, got " .. #cards_drawn)
  assert(cards_drawn[1].heading == "Pages goal", tostring(cards_drawn[1].heading))
  assert(cards_drawn[1].width == 430, tostring(cards_drawn[1].width))
  assert(cards_drawn[1].context ~= nil, "the single goal keeps its pace line")
end)

check("goal module steps in from the frame of a square cell", function()
  plugin_instance = app({ year_goal, pages_goal })
  current_user_id = 7
  clear()
  -- The host hands a square cell its whole inner width, so the card has to
  -- leave its own margin or the bar touches the frame.
  loadPack("hardcover_goal").render({ width = 380, height = 380, scale = 100, shape = "square" })
  assert(#cards_drawn == 1, "expected one card, got " .. #cards_drawn)
  assert(cards_drawn[1].width < 380, "the card runs into the frame: " .. tostring(cards_drawn[1].width))
  assert(cards_drawn[1].bar.bar.width == cards_drawn[1].width, "bar not the width of the card")
end)

-- The text actually in the card's tree. Text the card built to measure
-- something and then left out never reaches the tree, so this is what the
-- reader sees rather than everything the render touched.
local function treeTexts(node)
  local out = {}
  local function walk(n)
    if type(n) ~= "table" then return end
    if n.text then out[#out + 1] = tostring(n.text) end
    for _, child in ipairs(n) do walk(child) end
  end
  walk(node)
  return table.concat(out, "|")
end

check("goal module asks a signed-out reader to sign in", function()
  plugin_instance = app({ year_goal })
  current_user_id = nil
  clear()
  local text = treeTexts(loadPack("hardcover_goal").render(ctx))
  assert(text:find("Sign in to Hardcover Sync.", 1, true), text)
end)

check("goal module points at the goal screen when there is no goal", function()
  plugin_instance = app({})
  current_user_id = 7
  clear()
  local text = treeTexts(loadPack("hardcover_goal").render(ctx))
  assert(text:find("No current goal. Tap to set one.", 1, true), text)
end)

check("goal module says so when the plugin is off", function()
  plugin_instance = nil
  clear()
  local text = treeTexts(loadPack("hardcover_goal").render(ctx))
  assert(text:find("Turn on Hardcover Sync.", 1, true), text)
end)

-- ------------------------------------------------------- choosing the goal

-- A card's own saved settings, as Bookshelf hands them to render and
-- show_settings: get/set/delete, with no save callback in a plain render.
local function entryConfig()
  local saved = {}
  return {
    get = function(_, name, default)
      local v = saved[name]
      if v == nil then return default end
      return v
    end,
    set = function(_, name, value) saved[name] = value end,
    delete = function(_, name) saved[name] = nil end,
  }
end

local shown, closed
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, dialog) shown = dialog end,
    close = function() closed = (closed or 0) + 1 end,
  }
end
package.preload["ui/widget/buttondialog"] = function()
  return { new = function(_, spec) return spec end }
end

local function showGoalSettings(spec, ctx)
  spec.show_settings(ctx)
  assert(shown.buttons[1][1].text == "Which goal to show")
  shown.buttons[1][1].callback()
end

check("a card pinned to a goal shows it, and Automatic shows the one ending soonest", function()
  plugin_instance = app({ year_goal, pages_goal })
  current_user_id = 7
  local config = entryConfig()
  local function heading()
    clear()
    loadPack("hardcover_goal").render({ width = 300, height = 150, scale = 100, config = config })
    return cards_drawn[1] and cards_drawn[1].heading
  end
  assert(heading() == "Pages goal", tostring(heading()))
  config:set("goal", 1)
  assert(heading() == "Reading goal", tostring(heading()))
  -- A pin that has since ended falls back to Automatic, not to an empty card.
  config:set("goal", 99)
  assert(heading() == "Pages goal", tostring(heading()))
end)

check("the goal card's settings pin a goal, and Automatic unpins it", function()
  plugin_instance = app({ year_goal, pages_goal })
  current_user_id = 7
  package.loaded["ui/uimanager"] = nil
  package.loaded["ui/widget/buttondialog"] = nil
  local config = entryConfig()
  local spec = loadPack("hardcover_goal")

  shown, closed = nil, nil
  showGoalSettings(spec, { config = config })
  assert(shown and #shown.buttons == 3, "expected Automatic and two goals")
  assert(shown.title == "Which goal to show", tostring(shown.title))
  assert(shown.buttons[1][1].text == "\226\156\147 Automatic (ends soonest)", shown.buttons[1][1].text)
  assert(shown.buttons[2][1].text == "  Pages goal \194\183 3000 pages", shown.buttons[2][1].text)
  assert(shown.buttons[3][1].text == "  Reading goal \194\183 70 books", shown.buttons[3][1].text)

  shown.buttons[2][1].callback()
  assert(closed == 2, "dialog left open")
  assert(tostring(config:get("goal")) == "2", tostring(config:get("goal")))
  clear()
  spec.render({ width = 300, height = 150, scale = 100, config = config })
  assert(card_args.heading == "Pages goal", tostring(card_args.heading))

  shown, closed = nil, nil
  showGoalSettings(spec, { config = config })
  assert(shown.buttons[2][1].text:sub(1, 3) == "\226\156\147",
    "pin not marked: " .. shown.buttons[2][1].text)

  shown.buttons[1][1].callback()
  assert(tostring(config:get("goal")) == "nil", tostring(config:get("goal")))
end)

check("a shelf goal change keeps its style and works again next time", function()
  plugin_instance = app({ year_goal, pages_goal })
  current_user_id = 7
  package.loaded["ui/uimanager"] = nil
  package.loaded["ui/widget/buttondialog"] = nil
  -- The shelf's editor holds copies: a save that writes the whole copy back
  -- loses a style set elsewhere, and a stale copy makes the next pick wrong.
  local stored = { { id = "tab1", shelf_modules = { {
    id = "sm_1", module = "hardcover_goal_ring", goal = 1,
    bg = false, colors = { ink = "black" }, after = 4, w = 2,
  } } } }
  local saves, reloads, resets = 0, 0, 0
  package.preload["lib/bookshelf_tab_model"] = function()
    return {
      load = function() return stored end,
      save = function(tabs) stored = tabs; saves = saves + 1 end,
    }
  end
  package.preload["lib/bookshelf_module_cache"] = function()
    return {
      read = function() return { ["shelf|hardcover_goal_ring|sm_1|100|100|100|100"] = {} } end,
      save = function() end,
    }
  end
  package.preload["lib/bookshelf_hero_modules"] = function()
    return { _resetFitMemo = function() resets = resets + 1 end }
  end
  local entry = { id = "sm_1", module = "hardcover_goal_ring", goal = 1,
    bg = false, colors = { ink = "black" } }
  local ctx = { surface = "shelf", bw = { chip = "tab1" }, entry = entry,
    config = entryConfig(entry), menu = { _reload = function() reloads = reloads + 1 end } }
  local spec = loadPack("hardcover_goal_ring")
  local function pick(label)
    for _, row in ipairs(shown.buttons) do
      if row[1].text:find(label, 1, true) then row[1].callback(); return true end
    end
  end

  shown = nil
  showGoalSettings(spec, ctx)
  assert(pick("Pages goal"), "no Pages goal choice")
  local m = stored[1].shelf_modules[1]
  assert(m.goal == 2, "first change not stored: " .. tostring(m.goal))
  assert(entry.goal == 2, "the editor copy kept the old goal: " .. tostring(entry.goal))
  assert(m.bg == false and m.colors.ink == "black" and m.after == 4 and m.w == 2,
    "the goal save dropped the style or position")
  assert(saves == 1 and reloads == 1 and resets == 1, "the shelf was not saved and refreshed")

  -- The second dialog must start from the stored goal, not the editor's copy.
  shown = nil
  showGoalSettings(spec, ctx)
  local active
  for _, row in ipairs(shown.buttons) do
    if row[1].text:sub(1, 3) == "\226\156\147" and row[1].text:find("Pages goal", 1, true) then
      active = true
    end
  end
  assert(active, "the stored goal was not marked active on the next open")
  assert(pick("Reading goal"), "no Reading goal choice")
  m = stored[1].shelf_modules[1]
  assert(m.goal == 1, "second change not stored: " .. tostring(m.goal))
  assert(m.bg == false and m.colors.ink == "black", "style lost on the second change")
  assert(saves == 2 and reloads == 2 and resets == 2, "the second change did not refresh")

  -- Automatic removes the pin, and the next open must not fall back to the
  -- stale copy's goal.
  shown = nil
  showGoalSettings(spec, ctx)
  assert(pick("Automatic"), "no Automatic choice")
  m = stored[1].shelf_modules[1]
  assert(m.goal == nil, "Automatic left a goal: " .. tostring(m.goal))
  assert(m.bg == false and m.colors.ink == "black", "style lost on Automatic")
  shown = nil
  showGoalSettings(spec, ctx)
  active = nil
  for _, row in ipairs(shown.buttons) do
    if row[1].text:find("Automatic", 1, true) and row[1].text:sub(1, 3) == "\226\156\147" then
      active = true
    end
  end
  assert(active, "Automatic was not marked active after unpinning")

  spec.show_settings(ctx)
  assert(pick("Presentation"))
  assert(pick("Bar"))
  m = stored[1].shelf_modules[1]
  assert(m.presentation == "bar" and entry.presentation == "bar" and m.goal == nil)
  assert(m.bg == false and m.colors.ink == "black" and m.after == 4 and m.w == 2)
  spec.show_settings(ctx)
  assert(pick("Presentation"))
  assert(pick("Ring"))
  assert(m.presentation == "ring" and entry.presentation == "ring", "second presentation change was lost")

  package.preload["lib/bookshelf_tab_model"] = nil
  package.preload["lib/bookshelf_module_cache"] = nil
  package.preload["lib/bookshelf_hero_modules"] = nil
  package.loaded["lib/bookshelf_tab_model"] = nil
  package.loaded["lib/bookshelf_module_cache"] = nil
  package.loaded["lib/bookshelf_hero_modules"] = nil
end)

check("the settings say so when no goal is running", function()
  plugin_instance = app({})
  current_user_id = 7
  package.loaded["ui/uimanager"] = nil
  package.loaded["ui/widget/buttondialog"] = nil
  shown = nil
  showGoalSettings(loadPack("hardcover_goal"), { config = entryConfig() })
  assert(shown and #shown.buttons == 2, "expected Automatic and a note")
  assert(shown.buttons[2][1].text:find("No goal is running"), shown.buttons[2][1].text)
end)

-- The ring is a widget in the tree, so paint it the way Bookshelf would.
local function paintRings(node)
  local rings = 0
  local function paint(n)
    if type(n) ~= "table" then return end
    if n.paintTo then
      if not n.is_text then rings = rings + 1 end
      n:paintTo({}, 0, 0)
    end
    for _, child in ipairs(n) do paint(child) end
  end
  paint(node)
  return rings
end

local function ringRender(goals, size, pinned)
  plugin_instance = app(goals)
  current_user_id = 7
  local config = entryConfig()
  if pinned then config:set("goal", pinned) end
  ring_texts, ring_paints = {}, 0
  clear()
  local card = loadPack("hardcover_goal_ring").render(
    { width = size[1], height = size[2], scale = 100, config = config })
  assert(card_args == nil, "the ring card asked the kit for a bar card")
  return card, table.concat(ring_texts, "|")
end

check("the ring card keeps a square cell to the name, the count and the ring", function()
  -- A square can put the ring beside its facts; the one-cell fallback below
  -- must still keep the percentage when the words will not fit.
  local card, text = ringRender({ year_goal, pages_goal }, { 380, 380 }, 1)
  assert(text:find("Reading goal"), text)
  assert(text:find("46"), text)
  assert(text:find("70"), text)
  assert(text:find("66%%"), text)
  assert(paintRings(card) == 1, "expected one ring widget")
  assert(ring_paints > 0, "the ring was never painted")
end)

check("the ring card keeps one goal on a strip, its numbers as labelled stats", function()
  -- Two rings on a strip left neither room for its own numbers, so the ring
  -- card shows one goal and spends the width on three labelled facts.
  local card, text = ringRender({ year_goal, pages_goal }, { 900, 260 }, 1)
  assert(text:find("Reading goal"), text)
  assert(not text:find("Pages goal"), "a second goal on the ring card: " .. text)
  assert(text:find("66%%"), text)
  assert(paintRings(card) == 1, "expected one ring widget")
  for _, label in ipairs({ "Pace", "Time left", "Per week" }) do
    assert(text:find(label, 1, true), "no " .. label .. " label: " .. text)
  end
  assert(text:find("11 books ahead", 1, true), text)
  assert(text:find("180 days", 1, true), text)
  assert(text:find("0.9 books", 1, true), text)
  -- The sentences are what the stats replaced, not an addition to them.
  assert(not text:find("a week to finish", 1, true), text)
end)

check("the ring card falls back to the sentences when the stat row will not fit", function()
  -- The stat row is measured first, so its words are in `text` either way; the
  -- sentence that only the fallback draws is what says which layout ran.
  local card, text = ringRender({ year_goal }, { 400, 240 }, 1)
  assert(text:find("66%%"), text)
  assert(text:find("ahead of pace", 1, true), text)
  assert(text:find("days left", 1, true), text)
  assert(paintRings(card) == 1, "expected one ring widget")
end)

check("the ring card drops to the ring alone when the cell is too short for a name", function()
  -- One cell on a 6" screen: a ring and a name do not both fit, so the card
  -- keeps the ring and its percentage and lets the name go. This is what makes
  -- the ring card's min_w 1 while the bar and stats cards keep theirs at 2.
  local card, text = ringRender({ year_goal, pages_goal }, { 90, 90 }, 1)
  assert(text:find("66%%"), text)
  local drawn = treeTexts(card)
  assert(drawn:find("66%%"), "no percentage in the tile: " .. drawn)
  assert(not drawn:find("Reading goal"), "the name should have been dropped: " .. drawn)
  assert(not drawn:find("46"), "the count should have been dropped: " .. drawn)
  assert(paintRings(card) == 1, "expected one ring widget")
  assert(ring_paints > 0, "the ring was never painted")
end)

check("the ring card says why there is nothing to show", function()
  plugin_instance = app({})
  current_user_id = 7
  clear()
  local text = treeTexts(loadPack("hardcover_goal_ring").render({ width = 300, height = 150, scale = 100 }))
  assert(text:find("Goal ring", 1, true), text)
  assert(text:find("No current goal. Tap to set one.", 1, true), text)
end)

local rows = {
  { date = "2026-03-14", pages = 300, rating = 4 },
  { date = "2026-03-20", pages = 200, rating = 5 },
  { date = "2026-06-01", pages = 100 },
  { date = "2025-12-31", pages = 999 },
}

check("stats card counts the year's finished books", function()
  local c = Modules.statsCard(cache(nil, { rows = rows }), 7, 2026)
  assert(c.heading == "Finished in 2026")
  assert(c.value == "3" and c.suffix == " books")
  assert(c.sub:find("600 pages") and c.sub:find("4.5"), c.sub)
  assert(c.context:find("March") and c.context:find("%(2%)"), c.context)
end)

check("stats card with nothing saved", function()
  local _, why = Modules.statsCard(cache(nil, nil), 7, 2026)
  assert(why == "no_data")
end)

check("stats module draws the saved stats", function()
  plugin_instance = app(nil, { rows = rows })
  current_user_id = 7
  clear()
  loadPack("hardcover_stats").render(ctx)
  assert(card_args.value == "3" and card_args.suffix == " books", tostring(card_args.value))
  assert(card_args.bar == nil, "stats has no bar to fill")
end)

check("stats keeps its unit when the cell is too short for anything else", function()
  -- A bare "3" is not a statistic a reader can interpret. The shortest stats
  -- card still says what it counts, even when the heading and facts are gone.
  plugin_instance = app(nil, { rows = rows })
  current_user_id = 7
  clear()
  loadPack("hardcover_stats").render({ width = 90, height = 10, scale = 100 })
  assert(card_args.value == "3", tostring(card_args.value))
  assert(card_args.suffix == " books", "lost the unit: " .. tostring(card_args.suffix))
end)

-- The year card's series comes from Stats.compute, so the fixture year is the
-- one the rows name, never the wall clock.
check("year card splits the year into months, pages first", function()
  local c = Modules.yearCard(cache(nil, { rows = rows }), 7, 2026)
  assert(c and c.year == 2026, "no card")
  assert(c.unit == "pages", c.unit)
  assert(c.total == 600, tostring(c.total))
  -- March: 300 + 200 pages. June: 100. The rest are empty.
  assert(c.months[3] == 500, tostring(c.months[3]))
  assert(c.months[6] == 100, tostring(c.months[6]))
  assert(c.months[1] == 0 and c.months[12] == 0)
  assert(c.peak == 500 and c.peak_month == 3,
    tostring(c.peak) .. " / " .. tostring(c.peak_month))
end)

check("year card falls back to books when no edition has a page count", function()
  local c = Modules.yearCard(cache(nil, { rows = {
    { date = "2026-02-01" }, { date = "2026-02-10" }, { date = "2026-07-04" },
  } }), 7, 2026)
  assert(c.unit == "books", c.unit)
  assert(c.total == 3, tostring(c.total))
  assert(c.months[2] == 2 and c.months[7] == 1)
  assert(c.peak_month == 2, tostring(c.peak_month))
end)

check("year card says so when the year is empty", function()
  local _, why = Modules.yearCard(cache(nil, { rows = rows }), 7, 2024)
  assert(why == "no_books", tostring(why))
  local _, none = Modules.yearCard(cache(nil, nil), 7, 2026)
  assert(none == "no_data", tostring(none))
end)

check("year module paints a bar per month that has one", function()
  plugin_instance = app(nil, { rows = rows })
  current_user_id = 7
  ring_paints = 0
  clear()
  local card = loadPack("hardcover_year").render({ width = 300, height = 300, scale = 100 })
  assert(card, "no card")
  local drawn = treeTexts(card)
  assert(drawn:find("2026", 1, true), drawn)
  assert(drawn:find("600", 1, true), drawn)
  assert(drawn:find("pages", 1, true), drawn)
  assert(drawn:find("Best: March", 1, true), drawn)
  paintRings(card)
  -- Two months have pages, so two bars, and no third.
  assert(ring_paints == 2, "expected two bars, painted " .. tostring(ring_paints))
end)

check("tapping a card opens its screen, and nothing when the plugin is off", function()
  opened = nil
  plugin_instance = app({ year_goal }, { rows = rows })
  loadPack("hardcover_goal").on_tap({})
  assert(opened == "goals", tostring(opened))
  loadPack("hardcover_stats").on_tap({})
  assert(opened == "stats", tostring(opened))
  plugin_instance.dialog_manager.showHome = function() opened = "home" end
  local config = entryConfig()
  for _, name in ipairs({ "goal", "goal_ring", "stats", "year", "authors", "books_read", "five_star", "rereads" }) do
    config:set("tap_action", "home")
    loadPack("hardcover_" .. name).on_tap({ config = config })
    assert(opened == "home", name .. " ignored its configured tap")
    config:set("tap_action", "source")
    loadPack("hardcover_" .. name).on_tap({ config = config })
    assert(opened == ((name == "goal" or name == "goal_ring") and "goals" or "stats"), name .. " wrong source")
  end
  opened = nil
  plugin_instance = nil
  loadPack("hardcover_goal").on_tap({})
  assert(opened == nil, tostring(opened))
end)

-- --------------------------------------------------------- lifetime/discovery

local history = {
  { book_id = 101, title = "First", rating = 5, completions = 3,
    authors = { { id = 1, name = "A" }, { id = 2, name = "B" } },
    reads = { "2023-11-02", "2024-11", "2025-12-01" } },
  { book_id = 102, title = "Second", rating = 4.5, completions = 1,
    authors = { { id = 1, name = "A" } }, reads = { "2025-11-03" } },
  { book_id = 103, title = "Undated import", rating = 5, completions = 1,
    authors = {}, reads = {} },
}

check("the four lifetime counts distinguish books, authors, five stars and additional reads", function()
  local saved = cache(nil, { rows = {}, history = history, complete = true })
  for kind, expected in pairs({ authors = "2", books = "3", five_star = "2", rereads = "2" }) do
    assert(Modules.totalCard(saved, 7, kind).value == expected, kind)
  end
  assert(Modules.totalCard(cache(nil, { rows = {}, history = {} }), 7, "books").value == "0")
  for _, saved_stats in ipairs({ { rows = rows }, { rows = {}, history = history, complete = false } }) do
    assert(Modules.totalCard(cache(nil, saved_stats), 7, "books") == nil, "partial/legacy rows became a full total")
  end
end)

check("memories match the month in earlier years, rotate stably and preserve date precision", function()
  local saved = cache(nil, { rows = {}, history = history })
  local seen = {}
  for offset = 0, 2 do
    local c = Modules.memoryCard(saved, 7, "2026-11-03", offset)
    assert(c.candidates == 3)
    assert(c.date == Modules.memoryCard(saved, 7, "2026-11-03", offset).date, "a render re-rolled the memory")
    seen[c.date] = true
  end
  assert(seen["2023-11-02"] and seen["2024-11"] and seen["2025-11-03"], "lost a reread or fabricated a day")
  local c = Modules.memoryCard(saved, 7, "2024-11-03")
  assert(c.candidates == 1 and c.date == "2023-11-02", "this year/future finishes leaked in")
  local _, why = Modules.memoryCard(saved, 7, "2026-10-03")
  assert(why == "no_memories", "an unrelated month was substituted")
end)

check("memory Window falls back without broadening Reach or inventing dates", function()
  local saved = cache(nil, { rows = {}, history = history })
  local function memory(today, window, reach)
    return Modules.memoryCard(saved, 7, today, 0, window, reach)
  end
  local c = memory("2026-11-03", "day", "all")
  assert(c.date == "2025-11-03" and c.window == "day" and c.candidates == 1)
  c = memory("2026-11-05", "day", "all")
  assert(c.window == "week" and c.candidates == 2, "day did not widen to the nearest nonempty window")
  c = memory("2026-11-20", "week", "all")
  assert(c.window == "month" and c.candidates == 3, "month-only dates were lost in fallback")
  c = memory("2026-11-20", "day", "last_year")
  assert(c.window == "month" and c.candidates == 1 and c.date == "2025-11-03")
  assert(memory("2025-11-03", "day", "last_year").date == "2024-11", "partial date was treated as exact")
  assert(memory("2023-11-03", "day", "all") == nil, "current/future year leaked in")
  assert(memory("2024-12-01", "day", "last_year") == nil, "empty reach silently widened")

  saved = cache(nil, { rows = {}, history = {
    { book_id = 201, reads = { "2025-12-29", "2025-12-28", "2025-01-04", "2025-01-05" } },
  } })
  c = memory("2026-01-01", "week", "last_year")
  assert(c.window == "week" and c.candidates == 2, "New Year or inclusive ±3-day boundary is wrong")
  c = memory("2026-12-31", "week", "last_year")
  assert(c.window == "week" and c.candidates == 2, "reverse New Year boundary is wrong")
  saved = cache(nil, { rows = {}, history = {
    { book_id = 202, reads = { "2024-02-29", "2025-02-26", "2025-02-25" } },
  } })
  c = memory("2026-03-01", "week", "all")
  assert(c.date == "2025-02-26" and c.candidates == 1, "non-leap week included a phantom day")
  c = memory("2028-02-29", "day", "all")
  assert(c.date == "2024-02-29" and c.window == "day", "leap-day anniversary was lost")
end)

local function pickSetting(spec, ctx, label, value)
  spec.show_settings(ctx)
  local function pick(text)
    for _, row in ipairs(shown.buttons) do
      if row[1].text:find(text, 1, true) then row[1].callback(); return end
    end
    error("missing option " .. text)
  end
  pick(label)
  pick(value)
end

check("discovery settings persist per instance and hidden Another does not change taps", function()
  current_user_id = 7
  local last_month = tostring(tonumber(os.date("%Y")) - 1) .. os.date("-%m")
  plugin_instance = app(nil, { rows = {}, history = {
    { book_id = 101, reads = { last_month } }, { book_id = 102, reads = { last_month } },
  } })
  plugin_instance.dialog_manager.showHome = function() opened = "home" end
  local spec, other = loadPack("hardcover_memories"), entryConfig()
  local ctx = { config = entryConfig() }
  pickSetting(spec, ctx, "Window", "This day")
  pickSetting(spec, ctx, "Reach", "Last year")
  pickSetting(spec, ctx, "Another button", "Hide")
  assert(ctx.config:get("memory_window") == "day" and ctx.config:get("memory_reach") == "last_year")
  assert(ctx.config:get("show_another") == false and ctx.config:get("tap_action") == nil)
  assert(other:get("memory_window") == nil and other:get("show_another") == nil)
  pickSetting(spec, ctx, "Tap action", "Open Hardcover Home")
  assert(not spec.keep_open(ctx))
  spec.on_tap(ctx)
  assert(opened == "home")
  pickSetting(spec, ctx, "Tap action", "Show another saved book")
  assert(spec.keep_open(ctx))
  spec.on_tap(ctx)
  spec.on_tap(ctx)
  assert(ctx.config:get("discovery_choice").offset == 2)
  ctx.tapped_region = "another"
  ctx.config:set("tap_action", "home")
  spec.on_tap(ctx)
  assert(ctx.config:get("discovery_choice").offset == 3, "visible button obeyed card action")
  plugin_instance = nil
end)

check("both goal entries switch presentation without losing their goal pin", function()
  current_user_id = 7
  plugin_instance = app({ year_goal, pages_goal })
  local ctx = { config = entryConfig(), width = 400, height = 300, scale = 100 }
  ctx.config:set("goal", 2)
  local spec = loadPack("hardcover_goal")
  pickSetting(spec, ctx, "Presentation", "Ring")
  ring_paints = 0
  assert(paintRings(spec.render(ctx)) == 1 and ctx.config:get("goal") == 2)
  spec = loadPack("hardcover_goal_ring")
  pickSetting(spec, ctx, "Presentation", "Bar")
  clear()
  spec.render(ctx)
  assert(card_args.heading == "Pages goal" and ctx.config:get("goal") == 2)
  plugin_instance = nil
end)

check("refresh taps preserve history on failure and replace it only on complete success", function()
  local names = { "hardcover/lib/network", "hardcover/lib/ui/status_dialogs", "hardcover/lib/hardcover_api" }
  local previous = {}
  for _, name in ipairs(names) do previous[name] = package.loaded[name] end
  local online, message, callback = false, nil, nil
  package.loaded[names[1]] = { connected = function() return online end }
  package.loaded[names[2]] = { info = function(text) message = text end,
    loading = function() return {} end, close = function() end }
  package.loaded[names[3]] = { getStatsAsync = function(_, _, cb) callback = cb end }
  current_user_id = 7
  local saved = { rows = {}, history = history }
  local cache = { stats = function() return saved end,
    putStats = function(_, _, value) saved = value; return true end }
  plugin_instance = { shelf_cache = cache }
  local ctx = { config = entryConfig(), refresh = function() opened = "refreshed" end }
  ctx.config:set("tap_action", "refresh")
  local spec = loadPack("hardcover_memories")
  assert(spec.keep_open(ctx))
  spec.on_tap(ctx)
  assert(message:find("internet") and callback == nil and saved.history == history)
  online = true
  spec.on_tap(ctx)
  callback(nil)
  assert(saved.history == history and message:find("unchanged"))
  spec.on_tap(ctx)
  callback({ rows = {}, history = {}, complete = false })
  assert(saved.history == history, "partial history replaced complete data")
  spec.on_tap(ctx)
  callback({ rows = {}, history = {}, complete = true })
  assert(#saved.history == 0 and opened == "refreshed" and message == "Updated from Hardcover.")
  for _, name in ipairs(names) do package.loaded[name] = previous[name] end
  plugin_instance = nil
end)

check("TBR rediscovery uses only older saved Want to Read members and refuses a partial shelf", function()
  local store = {
    members = function(_, user, status)
      assert(user == 7 and status == 1)
      return { { book_id = 301, date_added = "2023-01-01" }, { book_id = 302, date_added = "2026-10-31" },
        { book_id = 303, date_added = "2026-11-01" }, { book_id = 304 } }, { complete = true, fingerprint = "x" }
    end,
    entriesOf = function(_, members)
      return { { book_id = members[1].book_id, title = "Saved book", authors = "Author" } }
    end,
  }
  local first = Modules.tbrCard(store, 7, "2026-11-03", 0)
  local second = Modules.tbrCard(store, 7, "2026-11-03", 1)
  assert(first.candidates == 2 and first.book_id ~= second.book_id)
  assert(first.book_id == Modules.tbrCard(store, 7, "2026-11-03", 0).book_id)
  assert(first.date == "2026-10-31" or first.date == "2023-01-01")
  store.members = function() return {}, { complete = false } end
  local _, why = Modules.tbrCard(store, 7, "2026-11-03")
  assert(why == "incomplete_tbr")
end)

check("the six additions are packs, the totals allow a single cell, and missing data opens its source", function()
  plugin_instance = app(nil, nil)
  plugin_instance.dialog_manager.showShelf = function(_, status) opened = status end
  for _, key in ipairs({ "hardcover_authors", "hardcover_books_read", "hardcover_five_star", "hardcover_rereads",
    "hardcover_memories", "hardcover_tbr" }) do
    local spec = loadPack(key)
    assert(spec.key == key and spec.summary:find("offline") and spec.render and spec.on_tap)
    assert(spec.min_w == ((key == "hardcover_memories" or key == "hardcover_tbr") and 2 or 1))
    clear()
    local rendered = assert(spec.render(ctx), key .. " missing-data render failed")
    local text = treeTexts(rendered)
    assert(text:find("Stats", 1, true) or text:find("Want to Read", 1, true), "missing data shown as a total")
    opened = nil
    spec.on_tap({})
    assert(opened == (key == "hardcover_tbr" and 1 or "stats"), key .. " tap")
  end
  plugin_instance = nil
end)

-- -------------------------------------------------------------------- cleanup

local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

check("cleanStubs removes our old stubs and leaves other files alone", function()
  local dir = os.tmpname()
  os.remove(dir)
  os.execute("mkdir -p '" .. dir .. "'")
  local stub = dir .. "/hardcover_goal.lua"
  local foreign = dir .. "/someone_else.lua"
  local other = dir .. "/notes.txt"
  write(stub, "-- Written by Hardcover Sync; rewritten on start.\nreturn nil\n")
  write(foreign, "-- another plugin's module\nreturn {}\n")
  write(other, "-- Written by Hardcover Sync\n")
  assert(Modules.cleanStubs(dir) == true, "nothing removed")
  assert(not exists(stub), "stub left behind")
  assert(exists(foreign), "removed another plugin's module")
  assert(exists(other), "removed a non-module file")
  assert(Modules.cleanStubs(dir) == false, "second run should find nothing")
  os.execute("rm -rf '" .. dir .. "'")
end)

check("cleanStubs does nothing without a module folder", function()
  assert(Modules.cleanStubs("/nonexistent/bookshelf/micromodules") == false)
end)

r.finish()
