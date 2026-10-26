-- The Edition button on the book details screen opens HardcoverMenu:showLinkActions. It must open
-- its two actions, Change edition and Unlink book, whether the device is online or not (editions
-- are fetched later by "Change edition", which reports a missing connection itself).
--
-- The bug this pins: showLinkActions called the file-local findItem before it was defined, so it
-- was a nil global and tapping Edition raised "attempt to call global 'findItem'" and crashed.
--
-- Run with:  lua spec/link_actions_harness.lua [plugin-root]

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
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return online end, isWifiOn = function() return online end,
           isOnline = function() return online end }
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
package.preload["ffi/util"] = function()
  return { template = function(fmt) return fmt end }
end

local dialog
package.preload["hardcover/lib/ui/settings_dialog"] = function()
  return { show = function(opts) dialog = opts end }
end

local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local HardcoverMenu = real_require("hardcover/lib/ui/hardcover_menu")

local function newMenu()
  return setmetatable({
    enabled = true,
    settings = {
      bookLinked = function() return true end,
      getLinkedTitle = function() return "A Book" end,
      getLinkedBookId = function() return 7 end,
      getLinkedEditionId = function() return 10 end,
      getLinkedEditionFormat = function() return nil end,
      syncEnabled = function() return false end,
      pages = function() return nil end,
    },
    state = { book_status = {} },
    sync_queue = { pendingCount = function() return 0 end, changeCount = function() return 0 end,
      hasPending = function() return false end },
    auth = { usingOAuth = function() return true end, needsReauth = function() return false end },
  }, { __index = HardcoverMenu })
end

for _, mode in ipairs({ { "online", true }, { "offline", false } }) do
  online = mode[2]
  dialog = nil
  local closed = false
  local ok, err = pcall(function() newMenu():showLinkActions(function() closed = true end) end)
  r.check("Edition opens the link actions " .. mode[1], ok, err)
  r.check("the list has change edition and unlink only (" .. mode[1] .. ")",
    ok and dialog ~= nil and #dialog.items == 2 and dialog.items[1].text == "Change edition"
      and type(dialog.items[1].callback) == "function"
      and dialog.items[2].text == "Unlink book", "items missing")
  local unlink = ok and dialog and dialog.items[2]
  r.check("Unlink book is in the list and can be tapped (" .. mode[1] .. ")",
    unlink and unlink.text == "Unlink book" and type(unlink.callback) == "function"
      and unlink.enabled_func() == true, "unlink missing or disabled")
  r.check("closing the list calls back (" .. mode[1] .. ")",
    ok and type(dialog.on_close) == "function", "no on_close")
end

-- Unlink only forgets the link on this device: a confirm, then a local settings write.
-- It must work with no connection and must not call the API.
online = false
local Api = real_require("hardcover/lib/hardcover_api")
local api_calls = 0
for k, v in pairs(Api) do
  if type(v) == "function" then Api[k] = function() api_calls = api_calls + 1 end end
end
local written, refreshed, confirmed
local m = newMenu()
m.ui = { document = { file = "/books/a.epub" } }
m.settings.updateBookSetting = function(_, file, change) written = { file = file, change = change } end
m.dialog_manager = { confirm = function(_, opts) confirmed = opts; opts.ok_callback() end }
local ok, err = pcall(function()
  m:getUnlinkMenuItem().callback({ updateItems = function() refreshed = true end })
end)
r.check("Unlink book works offline", ok, err)
r.check("it asks first, then deletes the link from this book's settings only",
  confirmed ~= nil and written and written.file == "/books/a.epub"
    and written.change._delete[1] == "book_id", "no local write")
r.check("it refreshes the menu and makes no API call", refreshed == true and api_calls == 0,
  "api calls: " .. api_calls)

r.finish()
