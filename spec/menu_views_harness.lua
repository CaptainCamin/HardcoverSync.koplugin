-- The plugin menu is two menus: one in the reader, one in the file browser.
--
--   * Reader: tracking and information about the open book. Nothing about the
--     rest of the library, so no Home, no shelves, no About.
--   * File browser: the home screen first, then sync, account, settings, about.
--     Nothing about a book, because there is none open.
--
-- Builds the real menu and reads the top-level entries it produces for each.
--
-- Run with:  lua spec/menu_views_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
package.preload["ffi/util"] = function()
  local util = {
    -- KOReader's template: replace %1, %2 ... with the arguments
    template = function(fmt, ...)
      local args = { ... }
      return (tostring(fmt):gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
  }
  return util
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local HardcoverMenu = real_require("hardcover/lib/ui/hardcover_menu")

local function newMenu(opts)
  opts = opts or {}
  return setmetatable({
    enabled = true,
    settings = {
      bookLinked = function() return false end,
      getLinkedTitle = function() return nil end,
      getLinkedBookId = function() return nil end,
      syncEnabled = function() return false end,
      pages = function() return nil end,
    },
    state = { book_status = {} },
    sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
    auth = {
      usingOAuth = function() return true end,
      needsReauth = function() return opts.signed_out == true end,
      statusText = function(_, name) return name and ("Signed in as " .. name) or "Signed in" end,
    },
  }, { __index = HardcoverMenu })
end

-- the label of every top-level entry, in order
local function labels(book_view, opts)
  local out = {}
  for _, item in ipairs(newMenu(opts):getSubMenuItems(book_view)) do
    local text = item.text
    if not text and item.text_func then
      local ok, value = pcall(item.text_func)
      text = ok and value or "?"
    end
    out[#out + 1] = tostring(text)
  end
  return out
end

local function has(list, wanted)
  for _, label in ipairs(list) do
    if label == wanted or label:find(wanted, 1, true) then return true end
  end
  return false
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function shown(list) return table.concat(list, " | ") end

print("\n== the reader menu: tracking and this book ==")

check("it offers linking, tracking, status and book details", function()
  local m = labels(true)
  for _, wanted in ipairs({ "Link book", "Automatically track progress", "Update status", "Book details", "Sync now", "Settings" }) do
    assert(has(m, wanted), "missing '" .. wanted .. "': " .. shown(m))
  end
end)

check("it leaves out the library: no Home, shelves or About", function()
  local m = labels(true)
  for _, unwanted in ipairs({ "Home", "Want to Read list", "Currently Reading list", "About" }) do
    assert(not has(m, unwanted), "'" .. unwanted .. "' is in the reader menu: " .. shown(m))
  end
end)

check("the account is not in the way while signed in", function()
  assert(not has(labels(true, { signed_out = false }), "Account"), "Account shown to a signed in reader")
end)

check("but it is offered when signed out, since tracking cannot work without it", function()
  assert(has(labels(true, { signed_out = true }), "Account"), "no way to sign in from the reader")
end)

local function settingsLabels(opts)
  local out = {}
  for _, item in ipairs(newMenu(opts):getSubMenuItems(true)) do
    if item.text == "Settings" then
      for _, sub in ipairs(item.sub_item_table_func()) do
        local text = sub.text
        if not text and sub.text_func then
          local ok, value = pcall(sub.text_func)
          text = ok and value or "?"
        end
        out[#out + 1] = tostring(text)
      end
    end
  end
  return out
end

check("signed in, the reader's Settings holds the account (to sign out) but not a second Sync", function()
  local m = settingsLabels({ signed_out = false })
  assert(has(m, "Account"), "no account in the reader's settings: " .. shown(m))
  assert(not has(m, "Sync"), "Sync is listed twice: " .. shown(m))
  assert(has(m, "Automatically link by ISBN"), shown(m))
end)

check("signed out, the account is not listed twice in the reader", function()
  assert(not has(settingsLabels({ signed_out = true }), "Account"), "Account is in both places")
end)

print("\n== one button: Home in the file browser, the book's panel while reading ==")

-- the entry as KOReader's menu sees it: a document being open decides which
local function mainMenuItem(has_document, opts)
  local m = newMenu(opts)
  m.ui = { document = has_document and {} or nil }
  m.dialog_manager = { home_opened = 0, showHome = function(self) self.home_opened = self.home_opened + 1 end }
  return m, m:mainMenu()
end

check("with no book open the entry is a button that opens Home, not a submenu", function()
  local m, item = mainMenuItem(false)
  assert(item.sub_item_table_func == nil and item.sub_item_table == nil, "it still opens a menu")
  assert(type(item.callback) == "function", "it does nothing when chosen")
  item.callback()
  assert(m.dialog_manager.home_opened == 1, "it did not open the home screen")
  assert(item.text_func() == "Hardcover", tostring(item.text_func()))
end)

check("with a book open the same entry opens the book's panel, not a menu", function()
  local m, item = mainMenuItem(true)
  assert(item.sub_item_table_func == nil and item.sub_item_table == nil, "it still opens a menu")
  local panels = 0
  m.showReaderPanel = function() panels = panels + 1 end
  item.callback()
  assert(panels == 1, "it did not open the panel")
  assert(m.dialog_manager.home_opened == 0, "it opened Home inside a book")
  assert(item.text_func() == "Hardcover" or item.text_func():find("Hardcover", 1, true))
end)

check("open() is what the gesture action runs: Home with no book, the panel with one", function()
  local m = mainMenuItem(false)
  m:open()
  assert(m.dialog_manager.home_opened == 1)
  local r = mainMenuItem(true)
  local panels = 0
  r.showReaderPanel = function() panels = panels + 1 end
  r:open()
  assert(panels == 1 and r.dialog_manager.home_opened == 0)
end)

check("it can be disabled like the rest of the plugin", function()
  local m, item = mainMenuItem(false)
  m.enabled = false
  assert(item.enabled_func() == false)
end)

print("\n== the account line ==")

check("the account item names the signed-in user when the name is saved, and says plain 'Signed in' before", function()
  local User = real_require("hardcover/lib/user")
  local m = newMenu()
  User.settings = { readSetting = function() return nil end, updateSetting = function() end }
  User.name_pending = true -- no lookup from a harness
  assert(m:getAccountMenuItem().text_func() == "Account: Signed in", m:getAccountMenuItem().text_func())
  User.settings = { readSetting = function(_, k) return k == "user_name" and "ChananyaMinster" or nil end, updateSetting = function() end }
  assert(m:getAccountMenuItem().text_func() == "Account: Signed in as ChananyaMinster", m:getAccountMenuItem().text_func())
  User.settings = nil
end)

print("\n== pending changes ==")

check("Pending changes (N) is listed only while something waits, and counts ratings and goals too", function()
  local m = newMenu()
  m.sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end }
  local none = {}
  for _, item in ipairs(m:getSubMenuItems(true)) do
    local ok, t = pcall(function() return item.text or (item.text_func and item.text_func()) end)
    none[#none + 1] = ok and tostring(t) or "?"
  end
  assert(not has(none, "Pending changes (0)"), "listed with nothing waiting")
  m.sync_queue = { pendingCount = function() return 1 end, hasPending = function() return true end }
  m.goal_queue = { count = function() return 1 end }
  m.rating_queue = { count = function() return 1 end }
  local item
  for _, it in ipairs(m:getSubMenuItems(true)) do
    local ok, t = pcall(function() return it.text or (it.text_func and it.text_func()) end)
    if ok and tostring(t):find("Pending changes", 1, true) then item = it end
  end
  assert(item, "no Pending changes item with changes waiting")
  assert(item.text_func() == "Pending changes (3)", item.text_func())
end)

print("\n== updates: the beta switch ==")

check("Include beta versions is off by default, and the switch turns it on and asks again soon", function()
  local m = newMenu()
  local store = {}
  m.settings.readSetting = function(_, k) return store[k] end
  m.settings.updateSetting = function(_, k, v) store[k] = v end
  local item
  for _, it in ipairs(m:getUpdateMenuItems()) do if it.text == "Include beta versions" then item = it end end
  assert(item, "no Include beta versions item")
  assert(item.checked_func() == false, "on by default")
  store.update_last_check = 123456
  item.callback()
  assert(store.update_beta == true and item.checked_func() == true, "not turned on")
  assert(store.update_last_check == 0, "the next check is not asked for")
  item.callback()
  assert(store.update_beta == false and item.checked_func() == false, "not turned off")
end)

print("\n== the settings screen holds what the first menu screen used to ==")

local function homeSettingsLabels(opts)
  local out = {}
  for _, item in ipairs(newMenu(opts):getHomeSettingsItems()) do
    local text = item.text
    if not text and item.text_func then
      local ok, value = pcall(item.text_func)
      text = ok and value or "?"
    end
    out[#out + 1] = tostring(text)
  end
  return out
end

check("sync, account, the settings and about are all there", function()
  local m = homeSettingsLabels()
  for _, wanted in ipairs({ "Sync now", "Account", "Automatically link by ISBN", "About" }) do
    assert(has(m, wanted), "missing '" .. wanted .. "': " .. shown(m))
  end
end)

check("sync comes first and about last", function()
  local m = homeSettingsLabels()
  assert(m[1] == "Sync now" and m[#m] == "About", shown(m))
end)

check("it has nothing about a book, because none is open", function()
  local m = homeSettingsLabels()
  for _, unwanted in ipairs({ "Link book", "Book details", "Update status", "Automatically track progress" }) do
    assert(not has(m, unwanted), "'" .. unwanted .. "' is in the settings screen: " .. shown(m))
  end
end)

check("the reader menu has no About or Home (they live behind the home screen)", function()
  local m = labels(true)
  assert(not has(m, "About") and not has(m, "Home"), shown(m))
end)

check("the old shelf entries are gone (Home replaces them)", function()
  local m = labels(true)
  assert(not has(m, "Want to Read list") and not has(m, "Currently Reading list"), shown(m))
end)

r.finish()
