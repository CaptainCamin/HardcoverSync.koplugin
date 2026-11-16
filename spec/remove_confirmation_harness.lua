-- Removing a book from the reader's status list asks first even with the default settings.
--
-- "Confirm changes to book read status" is off unless the reader turns it on, and it governs
-- status changes only. Removal deletes the status, rating and reading history, so it has its
-- own always-on confirmation, with the same copy as the book details screen's Remove.
--
-- Run with:  lua spec/remove_confirmation_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
table.unpack = table.unpack or unpack

package.preload["version"] = function()
  return { getNormalizedCurrentVersion = function() return 999999999999 end }
end
package.preload["luasettings"] = function()
  local LS = {}
  LS.__index = LS
  function LS:open() return setmetatable({ data = {} }, LS) end
  function LS:readSetting(key, default)
    if self.data[key] == nil and default ~= nil then self.data[key] = default end
    return self.data[key]
  end
  function LS:saveSetting(key, value) self.data[key] = value end
  function LS:flush() end
  return LS
end

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
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local r = KB.support.reporter()
local check = r.test

local HardcoverSettings = real_require("hardcover/lib/hardcover_settings")
local HardcoverMenu = real_require("hardcover/lib/ui/hardcover_menu")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local User = real_require("hardcover/lib/user")
local SETTING = real_require("hardcover/lib/constants/settings")

local FILE = "/books/a.epub"
local settings = HardcoverSettings:new("/nonexistent/remove_confirmation.lua", { document = { file = FILE } })
settings:updateSetting(SETTING.USER_ID, 1)
settings:updateBookSetting(FILE, { book_id = 7, title = "Dune", edition_id = 3, sync = true })
User.settings = settings

print("\n== removal confirmation with default settings ==")

check("the optional status confirmation is off by default", function()
  assert(settings:menuConfirm() == false, "menu_confirm default changed")
end)

check("the status menu's Remove asks with the shared copy before removing", function()
  local confirms = {}
  local real_confirm = StatusDialogs.confirm
  StatusDialogs.confirm = function(options) confirms[#confirms + 1] = options end

  local removed_with
  local menu = setmetatable({
    enabled = true,
    settings = settings,
    state = { book_status = { id = 500, book_id = 7, status_id = 2, edition_id = 3,
      user_book_reads = { { id = 900, progress_pages = 10, edition_id = 3 } } } },
    ui = { document = { file = FILE }, doc_props = { display_title = "a.epub" } },
    dialog_manager = {
      maybeConfirm = function() error("Remove used the optional status confirmation") end,
    },
    removeCurrentRead = function(self, menu_instance) removed_with = menu_instance end,
  }, { __index = HardcoverMenu })

  local remove_item
  for _, item in ipairs(menu:getStatusSubMenuItems()) do
    local text = item.text or (item.text_func and item.text_func())
    if type(text) == "string" and text:find("Remove", 1, true) and item.keep_menu_open then
      remove_item = item
    end
  end
  assert(remove_item, "the status menu has no Remove item")

  local menu_instance = { updateItems = function() end }
  remove_item.callback(menu_instance)
  StatusDialogs.confirm = real_confirm

  assert(#confirms == 1, "Remove did not ask first")
  assert(confirms[1].text ==
    "Remove \"Dune\" from your library? Your status, rating and reading history for it are deleted.",
    "different removal copy: " .. tostring(confirms[1].text))
  assert(confirms[1].ok_text == "Remove", "the confirmation's action is not Remove")
  assert(removed_with == nil, "the book was removed before confirmation")

  confirms[1].ok_callback()
  assert(removed_with == menu_instance, "confirming did not run the removal")
end)

r.finish()
