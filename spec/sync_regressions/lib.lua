-- Shared scaffolding for the scripts in spec/sync_regressions/.
--
-- Each script there reproduces ONE bug found by auditing the offline sync code
-- (all fixed now) and exits non-zero if it ever comes back. They are not named
-- *_harness.lua; spec/run_all.sh runs them in their own loop.
--
-- Run one with:  luajit spec/sync_regressions/<file>.lua [plugin-root]

local KB = {}

KB.root = arg and arg[1] or "."
package.path = KB.root .. "/?.lua;" .. KB.root .. "/?/init.lua;" .. package.path

KB.support = dofile(KB.root .. "/spec/support.lua")

local failures = {}

-- check(label, fn): fn errors (or an assertion fails) if the bug is back.
function KB.check(label, fn)
  local ok, err = pcall(fn)
  if ok then
    print("  [ok  ] " .. label)
  else
    failures[#failures + 1] = label
    print("  [BUG ] " .. label .. "\n         " .. tostring(err))
  end
end

function KB.eq(a, b, label)
  if a ~= b then
    error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

function KB.finish(title)
  if #failures == 0 then
    print("\n  FIXED: " .. title)
    os.exit(0)
  end
  print("\n  STILL REPRODUCES (" .. #failures .. "): " .. title)
  os.exit(1)
end

-- A settings double like LuaSettings: readSetting hands back the live table.
function KB.fakeSettings()
  local store = {}
  return {
    store = store,
    readSetting = function(_, key) return store[key] end,
    saveSetting = function(_, key, value) store[key] = value return true end,
    flush = function() return true end,
  }
end

function KB.newQueue()
  local SyncQueue = require("hardcover/lib/sync_queue")
  local settings = KB.fakeSettings()
  return SyncQueue:new { settings = settings }, settings
end

-- An API double. `shelf` maps book_id -> the user_book the "server" holds.
-- Every call is recorded in api.calls. Hooks let a test override a call.
function KB.fakeApi(shelf)
  local api = { calls = {}, shelf = shelf or {} }
  local function rec(op, t)
    t = t or {}
    t.op = op
    api.calls[#api.calls + 1] = t
  end
  function api:findUserBook(book_id, user_id)
    rec("findUserBook", { book_id = book_id, user_id = user_id })
    if self.find_hook then return self.find_hook(book_id, user_id) end
    return self.shelf[book_id]
  end
  function api:updateUserBook(book_id, status_id, privacy, edition_id)
    rec("updateUserBook", { book_id = book_id, status_id = status_id })
    if self.update_hook then return self.update_hook(book_id, status_id) end
    local ub = self.shelf[book_id] or { id = 1000 + book_id, book_id = book_id, user_book_reads = {} }
    ub.status_id = status_id
    self.shelf[book_id] = ub
    return ub
  end
  function api:updatePage(read_id, edition_id, page, started_at)
    rec("updatePage", { read_id = read_id, page = page, started_at = started_at })
    if self.page_hook then return self.page_hook(read_id, page) end
    for _, ub in pairs(self.shelf) do
      for _, r in ipairs(ub.user_book_reads or {}) do
        if r.id == read_id then
          r.progress_pages = page
          return ub
        end
      end
    end
  end
  function api:createRead(user_book_id, edition_id, page, started_at)
    rec("createRead", { user_book_id = user_book_id, page = page, started_at = started_at })
    for _, ub in pairs(self.shelf) do
      if ub.id == user_book_id then
        ub.user_book_reads = ub.user_book_reads or {}
        ub.user_book_reads[#ub.user_book_reads + 1] =
          { id = 9000 + #ub.user_book_reads, progress_pages = page, started_at = started_at }
        return ub
      end
    end
  end
  function api:count(op)
    local n = 0
    for _, c in ipairs(self.calls) do
      if c.op == op then n = n + 1 end
    end
    return n
  end
  return api
end

-- Loads the real main.lua (HardcoverApp) with KOReader's widget tree inert, and
-- returns the class plus a recorder of UIManager scheduling calls.
-- Build instances with KB.new_app{...}; init() is NOT run, the caller supplies
-- only the fields the method under test reads.
function KB.load_main()
  KB.stub_koreader()
  table.unpack = table.unpack or unpack -- KOReader provides this on LuaJIT

  local sched = { scheduled = {}, unscheduled = {} }
  package.preload["ui/uimanager"] = function()
    return {
      show = function() end, close = function() end, setDirty = function() end,
      forceRePaint = function() end, nextTick = function() end,
      scheduleIn = function(_, delay, fn) sched.scheduled[#sched.scheduled + 1] = { delay = delay, fn = fn } end,
      unschedule = function(_, fn) sched.unscheduled[#sched.unscheduled + 1] = fn end,
    }
  end
  package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, t) return t end }
  end
  package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o end } end
  package.preload["ui/widget/notification"] = function() return { new = function(_, o) return o end } end
  package.preload["version"] = function() return { getNormalizedCurrentVersion = function() return 999999999999 end } end

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
  local real_require = require
  _G.require = function(name)
    if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
      return real_require(name)
    end
    return make()
  end
  _G.G_reader_settings = { isTrue = function() return false end, readSetting = function() end }

  local App = assert(loadfile(KB.root .. "/main.lua"))()
  KB.App = App
  KB.sched = sched
  return App, sched
end

function KB.new_app(fields)
  return setmetatable(fields, { __index = KB.App })
end

-- The boundary stubs the real Api / Cache / menu modules need to load.
function KB.stub_koreader(opts)
  opts = opts or {}
  local support = KB.support
  support.preload_ui_stubs()
  support.preload_http_stubs()
  support.preload_json(KB.root)
  KB.network = { connected = opts.connected ~= false }
  package.preload["ui/network/manager"] = function()
    return {
      isOnline = function() return KB.network.connected end,
      isConnected = function() return KB.network.connected end,
      isWifiOn = function() return KB.network.connected end,
      runWhenOnline = function(_, fn) fn() end,
    }
  end
  package.preload["ffi/util"] = function()
    local util = {
      template = function(t, ...)
        local args = { ... }
        return (tostring(t):gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
      end,
    }
    setmetatable(util, { __call = function(_, s) return tostring(s) end })
    return util
  end
  package.preload["ffi"] = function() return {} end
  package.preload["ffi/pointer"] = function() return {} end
  package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
  package.preload["blitbuffer"] = function() return {} end
  package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
  package.preload["ui/trapper"] = function()
    return {
      wrap = function(_, fn) fn() end,
      -- no fork in a harness: run the task inline
      dismissableRunInSubprocess = function(_, fn) return true, fn() end,
      runInSubprocess = function(_, fn) return true, fn() end,
    }
  end
end

return KB
