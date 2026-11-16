-- New installations start with tracking and exact-identifier auto-linking on;
-- an existing settings file keeps the old off defaults. Also checks the gate
-- main.lua uses for an actual progress upload.
--
-- Run with:  luajit spec/new_install_defaults_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
package.preload["version"] = function() return { getNormalizedCurrentVersion = function() return 202501010000 end } end

-- A LuaSettings stand-in with the methods HardcoverSettings uses, backed by the
-- `store` of the test in progress.
local store = {}
package.loaded["luasettings"] = nil
package.preload["luasettings"] = function()
  return {
    open = function()
      return {
        readSetting = function(_, key, default)
          if store[key] == nil and default ~= nil then store[key] = default end
          return store[key]
        end,
        saveSetting = function(_, key, value) store[key] = value end,
        flush = function() end,
      }
    end,
  }
end

local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local SETTING = require("hardcover/lib/constants/settings")
local BookActions = require("hardcover/lib/book_actions")
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
local r = support.reporter()
local check = r.test

local function settings(new_install, ui)
  return HardcoverSettings:new("/tmp/hardcover_new_install_test.lua", ui or {}, { new_install = new_install })
end

print("\n== a clean install ==")

check("new install turns global tracking on", function()
  store = {}
  assert(settings(true):readSetting(SETTING.ALWAYS_SYNC) == true)
end)

check("new install turns ISBN and Hardcover-id auto-linking on", function()
  store = {}
  local s = settings(true)
  assert(s:readSetting(SETTING.LINK_BY_ISBN) == true)
  assert(s:readSetting(SETTING.LINK_BY_HARDCOVER) == true)
  assert(s:readSetting(SETTING.LINK_BY_TITLE) ~= true, "title auto-linking was turned on")
  assert(s:autolinkEnabled() == true)
end)

check("new install tracking is the gate main.lua uses for a page upload", function()
  store = {}
  local s = settings(true)
  s:updateBookSetting("/book.epub", { book_id = 1, pages = 300 })
  assert(s:fileSyncEnabled("/book.epub") == true)
end)

check("new install leaves the progress and update defaults unchanged", function()
  store = {}
  local s = settings(true)
  assert(s:trackByTime() == true and s:trackByProgress() == false)
  assert(s:trackFrequency() == 5 and s:trackPercentageInterval() == 10)
  assert(s:readSetting(SETTING.SHOW_FOR_YOU) ~= false, "For you was turned off")
  assert(s:readSetting(SETTING.UPDATE_CHECK) ~= false, "update checks were turned off")
  assert(s:readSetting(SETTING.UPDATE_BETA) ~= true, "beta updates were turned on")
end)

print("\n== an upgrade ==")

check("an existing empty settings file keeps the old off defaults", function()
  store = {}
  local s = settings(false)
  assert(s:readSetting(SETTING.ALWAYS_SYNC) == nil)
  assert(s:readSetting(SETTING.LINK_BY_ISBN) == nil)
  assert(s:readSetting(SETTING.LINK_BY_HARDCOVER) == nil)
  assert(s:autolinkEnabled() == false)
  assert(s:fileSyncEnabled("/book.epub") == false)
end)

check("an existing user's explicit choices are preserved", function()
  store = {
    [SETTING.ALWAYS_SYNC] = false,
    [SETTING.LINK_BY_ISBN] = false,
    [SETTING.LINK_BY_HARDCOVER] = true,
    [SETTING.LINK_BY_TITLE] = true,
  }
  local s = settings(false)
  assert(s:readSetting(SETTING.ALWAYS_SYNC) == false)
  assert(s:readSetting(SETTING.LINK_BY_ISBN) == false)
  assert(s:readSetting(SETTING.LINK_BY_HARDCOVER) == true)
  assert(s:readSetting(SETTING.LINK_BY_TITLE) == true)
end)

check("applying new defaults never overwrites an explicit false", function()
  store = {
    [SETTING.ALWAYS_SYNC] = false,
    [SETTING.LINK_BY_ISBN] = false,
    [SETTING.LINK_BY_HARDCOVER] = false,
  }
  settings(true)
  assert(store[SETTING.ALWAYS_SYNC] == false)
  assert(store[SETTING.LINK_BY_ISBN] == false)
  assert(store[SETTING.LINK_BY_HARDCOVER] == false)
end)

check("a settings file that exists is not a new install", function()
  local path = os.tmpname()
  local f = assert(io.open(path, "w")); f:write("return {}\n"); f:close()
  assert(HardcoverSettings.newInstall(path) == false)
  os.remove(path)
end)

check("a missing settings file is a new install", function()
  local path = os.tmpname()
  os.remove(path)
  assert(HardcoverSettings.newInstall(path) == true)
end)

print("\n== per-book overrides ==")

check("a book without an override inherits the new global default", function()
  store = {}
  local s = settings(true)
  s:updateBookSetting("/book.epub", { book_id = 1 })
  assert(s:fileSyncEnabled("/book.epub") == true)
end)

check("an explicit per-book false wins over the new global default", function()
  store = {}
  local s = settings(true)
  s:updateBookSetting("/book.epub", { book_id = 1, sync = false })
  assert(s:fileSyncEnabled("/book.epub") == false)
end)

check("an explicit per-book true wins over an existing global false", function()
  store = { [SETTING.ALWAYS_SYNC] = false }
  local s = settings(false)
  s:updateBookSetting("/book.epub", { book_id = 1, sync = true })
  assert(s:fileSyncEnabled("/book.epub") == true)
end)

print("\n== rating no-op decision ==")

check("an unrated book at 0 is not a change", function()
  assert(BookActions.ratingChange(nil, 0) == false)
  assert(BookActions.ratingChange(0, 0) == false)
end)

check("an existing rating left alone is not a change", function()
  assert(BookActions.ratingChange(4, 4) == false)
end)

check("a rated book at 0 is a clear", function()
  assert(BookActions.ratingChange(4, 0) == true)
end)

check("moving to a rating is a change", function()
  assert(BookActions.ratingChange(nil, 0.5) == true)
  assert(BookActions.ratingChange(4, 5) == true)
end)

print("\n== the actual upload gate ==")

check("a new install sends a page turn, an upgrade does not", function()
  local App = KB.load_main()
  local function app_for(new_install)
    store = {}
    local ui = { document = { file = "/book.epub", getPageCount = function() return 300 end } }
    local s = settings(new_install, ui)
    s:updateBookSetting("/book.epub", { book_id = 1, pages = 300 })
    local sent = {}
    local app = KB.new_app {
      settings = s,
      ui = ui,
      state = { page = 10, book_status = { id = 500, status_id = 2 } },
      sync_queue = { statusOf = function() end },
      page_mapper = { getMappedPage = function(_, page) return page end },
      _debouncedPageUpdate = function() end,
      _throttledHandlePageUpdate = function(_, file, page) sent[#sent + 1] = { file, page } end,
      checkLastPage = function() end,
      pageWriteDecision = function() return "allow" end,
    }
    app:pageUpdateEvent(11)
    return sent, app
  end

  local new_sent = app_for(true)
  assert(#new_sent == 1 and new_sent[1][2] == 11, "a new install did not upload the page")
  local old_sent = app_for(false)
  assert(#old_sent == 0, "an upgrade uploaded a page with tracking off")
end)

r.finish()