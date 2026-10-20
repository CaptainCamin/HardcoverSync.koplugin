-- The Edition button on the book details screen: offered only for the book open in the reader,
-- it opens the same list as the reader menu's link actions (change edition, link a different book,
-- unlink), and the details follow a change.
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

local check = r.test

local shown, reopened
local function newManager(opts)
  opts = opts or {}
  shown, closed, reopened = nil, {}, nil
  local store = { book_id = opts.linked_book or 7, edition_id = 10 }
  local m = setmetatable({
    ui = opts.no_document and {} or { document = { file = "/a.epub" } },
    settings = {
      getLinkedBookId = function() return store.book_id end,
      getLinkedEditionId = function() return store.edition_id end,
    },
  }, { __index = DialogManager })
  if not opts.no_menu then
    m.show_link_actions = function(on_close) shown = { on_close = on_close, store = store } end
  end
  function m:showBookDetail(book_id, edition_id) reopened = { book_id, edition_id } end
  return m
end

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

check("not offered when the plugin has no link actions to open", function()
  assert(not newManager({ no_menu = true }):canChangeEdition(7))
end)

print("\n== the button opens the reader menu's link list ==")

check("tapping it opens the link actions and leaves the details alone", function()
  local m = newManager()
  m:chooseEdition({}, 7)
  assert(shown, "the link actions did not open")
  assert(reopened == nil and #closed == 0)
end)

check("closing the list with nothing changed leaves the details as they are", function()
  local m = newManager()
  m:chooseEdition({}, 7)
  shown.on_close()
  assert(reopened == nil and #closed == 0)
end)

check("another edition: the details reopen on it", function()
  local m = newManager()
  m:chooseEdition({ name = "d" }, 7)
  shown.store.edition_id = 11
  shown.on_close()
  assert(reopened and reopened[1] == 7 and reopened[2] == 11, "details not reopened on the new edition")
  assert(closed[1] and closed[1].name == "d", "old details screen left open")
end)

check("a different book: the details reopen on that book", function()
  local m = newManager()
  m:chooseEdition({}, 7)
  shown.store.book_id, shown.store.edition_id = 9, 30
  shown.on_close()
  assert(reopened and reopened[1] == 9 and reopened[2] == 30)
end)

check("unlinked: the details reopen for the same book, without the button", function()
  local m = newManager()
  m:chooseEdition({}, 7)
  shown.store.book_id, shown.store.edition_id = nil, nil
  shown.on_close()
  assert(reopened and reopened[1] == 7 and reopened[2] == nil)
  assert(not m:canChangeEdition(7), "Edition still offered after unlinking")
end)

r.finish()
