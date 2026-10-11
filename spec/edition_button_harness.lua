-- The Edition button on the book details screen: offered only for the book open in the reader,
-- it lists the book's editions and relinks the file to the one picked; with no other edition it
-- says so instead of opening a list of one.
--
-- Run with:  lua spec/edition_button_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local online = true
local closed = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function() end, close = function(_, w) closed[#closed + 1] = w end,
    isWidgetShown = function() return true end, setDirty = function() end,
    scheduleIn = function() end, unschedule = function() end, forceRePaint = function() end,
    nextTick = function(_, fn) fn() end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return online end }
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local Api = real_require("hardcover/lib/hardcover_api")
local User = real_require("hardcover/lib/user")
local Background = real_require("hardcover/lib/background")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
User.getId = function() return 1 end
Background.run = function(fn) fn() end

local infos = {}
StatusDialogs.info = function(text) infos[#infos + 1] = text end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local linked, picker, reopened, editions
local function newManager(opts)
  opts = opts or {}
  infos, closed, linked, picker, reopened = {}, {}, {}, nil, nil
  local store = { book_id = opts.linked_book or 7, edition_id = 10 }
  local m = setmetatable({
    ui = opts.no_document and {} or { document = { file = "/a.epub" } },
    settings = {
      getLinkedBookId = function() return store.book_id end,
      getLinkedEditionId = function() return store.edition_id end,
    },
  }, { __index = DialogManager })
  if not opts.no_link then
    m.link_book = function(book)
      linked[#linked + 1] = book
      return opts.link_fails ~= true
    end
  end
  function m:buildLoadingSearchDialog(title, fetch, active, on_pick, _, _, edition_rows)
    picker = { title = title, fetch = fetch, active = active, on_pick = on_pick, edition_rows = edition_rows }
  end
  function m:showBookDetail(book_id, edition_id) reopened = { book_id, edition_id } end
  return m
end

Api.findEditionsAsync = function(_, _, _, cb) cb(editions) end

print("\n== when the button is offered ==")

check("only for the book the open file is linked to", function()
  local m = newManager()
  assert(m:canChangeEdition(7), "not offered for the linked book")
  assert(not m:canChangeEdition(8), "offered for another book")
  assert(not m:canChangeEdition(nil))
end)

check("not offered with no book open (opened from Home, a shelf or a list)", function()
  assert(not newManager({ no_document = true }):canChangeEdition(7))
end)

check("not offered when the plugin cannot relink", function()
  assert(not newManager({ no_link = true }):canChangeEdition(7))
end)

print("\n== choosing an edition ==")

check("offline: says so and opens nothing", function()
  online = false
  local m = newManager()
  m:chooseEdition({}, 7)
  online = true
  assert(picker == nil and #infos == 1)
end)

check("opens the edition picker on the current edition, rows showing format and pages", function()
  local m = newManager()
  m:chooseEdition({}, 7)
  assert(picker and picker.title == "Select edition" and picker.edition_rows == true)
  assert(picker.active.edition_id == 10)
end)

check("one edition or none: no list, a line saying there is nothing else", function()
  for _, list in ipairs({ {}, { { edition_id = 10, book_id = 7 } } }) do
    local m = newManager()
    editions = list
    m.search_dialog = { name = "picker" }
    m:chooseEdition({}, 7)
    local got
    picker.fetch(function(items) got = items end)
    assert(got == list, "the list was not passed on")
    assert(closed[1] == m.search_dialog, "the empty picker stayed open")
    assert(infos[1] == "This book has no other editions.", tostring(infos[1]))
  end
end)

check("several editions: the list is passed on untouched", function()
  local m = newManager()
  editions = { { edition_id = 10 }, { edition_id = 11 } }
  m:chooseEdition({}, 7)
  local got
  picker.fetch(function(items) got = items end)
  assert(got == editions and #infos == 0 and #closed == 0)
end)

check("picking another edition relinks the file and reopens the details on it", function()
  local m = newManager()
  m:chooseEdition({ name = "d" }, 7)
  picker.on_pick({ book_id = 7, edition_id = 11, pages = 400 })
  assert(#linked == 1 and linked[1].edition_id == 11)
  assert(reopened and reopened[1] == 7 and reopened[2] == 11, "details not reopened on the new edition")
  assert(closed[1] and closed[1].name == "d", "old details screen left open")
end)

check("picking the current edition changes nothing", function()
  local m = newManager()
  m:chooseEdition({}, 7)
  picker.on_pick({ book_id = 7, edition_id = 10 })
  assert(#linked == 0 and reopened == nil)
end)

check("a refused change leaves the details screen as it was", function()
  local m = newManager({ link_fails = true })
  m:chooseEdition({}, 7)
  picker.on_pick({ book_id = 7, edition_id = 11 })
  assert(#linked == 1 and reopened == nil and #closed == 0)
end)

r.finish()
