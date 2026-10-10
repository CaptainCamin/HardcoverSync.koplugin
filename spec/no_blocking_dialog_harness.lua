-- No screen may wait on the network before it appears.
--
-- The plugin shipped this bug twice before: About used to call
-- Github:newestRelease() before showing anything, and every dialog in
-- dialog_manager.lua fetched its content before UIManager:show. With no route
-- to the API that is a 6-second dead tap -- the user presses, nothing happens,
-- and on e-ink the panel keeps whatever was last painted until they power-cycle.
-- That is indistinguishable from a crashed device.
--
-- spec/no_blocking_menu_harness.lua already pins two menu paths (About, sign-in).
-- This covers the dialog paths, which were the ones still broken.
--
-- The rule under test: for every dialog entry point, UIManager:show has been
-- called BEFORE the API returns. The stub API records the order, so a regression
-- that moves a fetch back above a show fails here rather than on a device.

local ROOT = arg[1] or "."
package.path = ROOT .. "/spec/?.lua;" .. package.path

local support = require("support")
local r = support.reporter()

-- The plugin's modules require the socket stack at load time even when no
-- request is made, and hardcover_api pulls in ffi/util and trapper besides.
support.preload_http_stubs()
support.preload_json(ROOT)

-- A catch-all for the KOReader widget modules this harness does not care about.
--
-- It is deliberately NOT a permissive "return {} for anything unknown" fallback:
-- that pattern produces false "no crash" results, because a real load error
-- inside a module gets swallowed and answered with a stub, and the test then
-- passes while the code is broken. Two things keep it honest:
--
--   * It only answers modules under ui/widget/ and ui/gesture -- the widget
--     layer, which this harness never asserts on. It asserts on the ORDER of
--     UIManager:show versus the API call.
--   * An explicit stub registered below always wins, so any module a test
--     inspects is served by the stub written for it.
--
-- Anything under ui/widget/ that raises while loading is still re-raised rather
-- than answered, because a module that fails to load is a plugin bug and hiding
-- it here would make every assertion below meaningless.
local function widget_stub()
  local M = {}
  -- KOReader's Widget:new runs _init then init. The plugin's dialogs set their
  -- fields in init -- JournalDialog builds self._input_widget there and
  -- dialog_manager.lua:238 scrolls it unguarded -- so a base class whose init is
  -- never called leaves those fields nil and the failure surfaces far from the
  -- cause. Running init on the way out of new gives subclasses the same
  -- lifecycle the device gives them.
  local function make_instance(o)
    o = o or {}
    -- Deliberately does NOT call o:init(). Running a dialog's init means
    -- building its widget tree, and every KOReader method that tree reaches
    -- that this harness has not stubbed then fails as a nil call -- which is
    -- indistinguishable from a plugin bug. That is the losing game
    -- spec/support.lua warns about at length.
    --
    -- What this harness asserts is the ORDER of UIManager:show versus the API
    -- call. Capturing the constructor spec answers that without a widget tree.
    --
    -- The null-object fallback covers the callers that immediately poke a field
    -- the skipped init would have built -- dialog_manager.lua:238 does
    -- dialog._input_widget:scrollToBottom() -- and returns a no-op for any
    -- method, so those calls succeed without pretending the widget exists.
    --
    -- The cost is real and worth stating: a row that really should have had
    -- _input_widget set is not caught here. The emulator scenarios are what
    -- cover that; this harness covers ordering only.
    return setmetatable(o, {
      __index = function(t, key)
        local missing = {}
        setmetatable(missing, {
          __index = function() return function() return nil end end,
          __call = function() return nil end,
        })
        rawset(t, key, missing)
        return missing
      end,
    })
  end
  M.new = make_instance

  -- A class built with Widget:extend must itself be extendable: the plugin's
  -- dialogs chain (JournalDialog extends InputDialog extends Widget), and a
  -- class whose extend() does not itself return something extendable fails on
  -- the next level up with "attempt to call a nil value (method 'extend')".
  local function make_class()
    local C = { new = make_instance }
    C.extend = function() return make_class() end
    return C
  end
  M.extend = make_class
  return M
end

-- Whether a module is the plugin's own. Those are NEVER stubbed: a stubbed
-- plugin module cannot fail, so it hides exactly the bug a harness opens to
-- find. They are dofile'd from real source, so a syntax error or a renamed
-- function surfaces as a failure instead of being answered by a stub.
local function is_plugin_module(name)
  return name:sub(1, 10) == "hardcover/" or name == "hardcover_version"
end

-- Modules that must come from real Lua or an explicit stub above, never from
-- the catch-all. Everything else is a KOReader frontend module this harness
-- never inspects, so a generic stub is safe and saves enumerating them.
local REAL_LUA = {
  -- exercised for real: the harness asserts on what the plugin persists
  luasettings = true,
  -- the plugin's own spec copy of a real decoder
  json = true,
  -- _meta is the real plugin manifest; hardcover_version parses its `version`
  -- field. Stubbing it would hand back a table with no version and fail deep
  -- inside an unrelated module with a misleading error.
  _meta = true,
}

-- Installed LAST, after every explicit stub, and only for names with no loader.
setmetatable(package.preload, {
  __index = function(t, name)
    if is_plugin_module(name) or REAL_LUA[name] then return nil end
    return widget_stub
  end,
})

-- ---------------------------------------------------------------- recording
-- One shared timeline. Both the stubbed API and the stubbed UIManager append to
-- it, so a single sequence answers "did the show happen first?" without either
-- side knowing about the other.
local events = {}
local function note(kind, what) events[#events + 1] = kind .. ":" .. tostring(what) end

local function index_of(kind)
  for i, e in ipairs(events) do
    if e:sub(1, #kind + 1) == kind .. ":" then return i end
  end
  return nil
end

local function reset() events = {} end

-- The API stub never resolves on its own: it records the call and returns nil,
-- forcing the caller to rely on the callback. A stub that returned data
-- synchronously would let a fetch-then-show implementation pass by accident.
-- Every stubbed method returns nil and never invokes a callback. That is
-- deliberate: the assertions are about what happens BEFORE the answer, so a stub
-- that resolved synchronously would let a fetch-then-show implementation pass by
-- accident. The Async variants are stubbed alongside the sync ones because
-- dialog_manager calls those, and a missing method would read as a product bug
-- rather than a gap in the stub.
local function stub_api(names)
  local Api = {}
  for _, name in ipairs(names) do
    local record = function()
      note("api", name)
      return nil
    end
    Api[name] = record
    Api[name .. "Async"] = record
  end
  return Api
end

-- ---------------------------------------------------------------- environment
local shown_widgets = {}

package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) shown_widgets[#shown_widgets + 1] = w note("show", w and w.name or "?") end,
    close = function() end,
    setDirty = function() end,
    scheduleIn = function() end,
    unschedule = function() end,
    isWidgetShown = function(_, w)
      for _, s in ipairs(shown_widgets) do if s == w then return true end end
      return false
    end,
    nextTick = function(_, f) f() end,
    repaint = function() end,
    getTopmostVisibleWidget = function() return shown_widgets[#shown_widgets] end,
  }
end

package.preload["hardcover/lib/ui/components/loading"] = function()
  return { show = function(text)
    local w = { text = text, close = function() end }
    require("ui/uimanager"):show(w)
    return w
  end }
end
package.preload["ui/widget/infomessage"] = function()
  local M = {}
  M.new = function(_, o) o = o or {} setmetatable(o, M) o.close = function() end return o end
  return M
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end,
           warn = function() end, err = function() end }
end
package.preload["json"] = function() return dofile(ROOT .. "/spec/json.lua") end
-- hardcover_api requires ffi/util for its template helper. KOReader ships it;
-- under plain Lua it is stood in for, and the template call is only used for the
-- User-Agent header, which no harness here inspects.
package.preload["ffi/util"] = function()
  return { template = function(fmt) return fmt end }
end
-- The vendored listmenu/covermenu require blitbuffer for its colour constants.
package.preload["ffi/blitbuffer"] = function()
  return { COLOR_WHITE = 0xFFFFFF, COLOR_BLACK = 0x000000,
           COLOR_GRAY = 0x808080, COLOR_LIGHT_GRAY = 0xC0C0C0,
           COLOR_DARK_GRAY = 0x404040 }
end
package.preload["ui/widget/confirmbox"] = function()
  local M = {}
  M.new = function(_, o) o = o or {} setmetatable(o, M) return o end
  return M
end
package.preload["ui/widget/menu"] = function() return { extend = function() return { new = function() end } end } end
package.preload["ui/widget/container/inputcontainer"] = function()
  return { extend = function() return { new = function(_, o) return o end } end }
end
package.preload["ui/widget/container/focusmanager"] = function()
  return { extend = function() return { new = function(_, o) return o end } end }
end
package.preload["ui/widget/focusmanager"] = function()
  return { extend = function() return { new = function(_, o) return o end } end }
end
package.preload["ui/widget/scrollablecontainer"] = function()
  return { extend = function() return { new = function(_, o) return o end } end }
end
package.preload["ui/widget/buttondialog"] = function()
  return { new = function(_, o) return o end }
end
package.preload["ui/widget/container/centercontainer"] = function()
  return { new = function(_, o) return o end }
end
package.preload["ui/widget/container/framecontainer"] = function()
  return { new = function(_, o) return o end }
end
package.preload["ui/widget/button"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/textwidget"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/textboxwidget"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/gesturerange"] = function() return { new = function(_, o) return o end } end
package.preload["ui/geometry"] = function() return { new = function(_, o) return o end } end
package.preload["ui/size"] = function() return { border = { window = 1, thin = 1 }, padding = { button = 2, small = 2 }, line = { medium = 2 } } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/widget/inputdialog"] = function() return widget_stub() end
package.preload["ui/widget/spinwidget"] = function() return { new = function(_, o) return o end } end
package.preload["ui/downloadmgr"] = function() return {} end
package.preload["ui/trapper"] = function()
  return {
    dismissableRunInSubprocess = function(_, f) return f() end,
    -- Background.run goes through this. Running the function inline keeps the
    -- order of calls observable, which is all these checks are about.
    wrap = function(_, f) f() end,
  }
end
-- Online: these checks are about the order of show and fetch, which only exists
-- when a fetch happens. The offline paths have their own harness
-- (offline_shelf_harness.lua).
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return "/tmp/hc" end } end
package.preload["device"] = function()
  return { screen = { getWidth = function() return 1200 end, getHeight = function() return 1600 end,
                      getSize = function() return { w = 1200, h = 1600 } end, scaleBySize = function(_, n) return n end },
           isTouchDevice = function() return false end }
end
package.preload["luasettings"] = function()
  local store = {}
  return { open = function() return true end, close = function() end, flush = function() end,
           readSetting = function(_, k) return store[k] end,
           writeSetting = function(_, k, v) store[k] = v return true end,
           deleteSetting = function(_, k) store[k] = nil return true end,
           hasKey = function(_, k) return store[k] ~= nil end, _store = store }
end

-- The dialogs under test, and the UI modules they need.
--
-- Order matters here: clear the plugin's cached modules FIRST, then install the
-- API stub. Clearing afterwards would delete the stub that was just installed,
-- and dialog_manager would require the real hardcover_api -- whose socket calls
-- then fail slowly, or worse, succeed against the live API.
local function build_manager()
  for name in pairs(package.loaded) do
    if name:sub(1, 10) == "hardcover/" then package.loaded[name] = nil end
  end
  local fake_api = stub_api{
    "getShelf", "getBookDetail", "findBooks", "findEditions",
    "findDefaultEdition", "findBookByIdentifiers",
  }
  package.loaded["hardcover/lib/hardcover_api"] = fake_api

  local DialogManager = dofile(ROOT .. "/hardcover/lib/ui/dialog_manager.lua")
  local manager = DialogManager:new{}

  -- Every plugin module that holds settings expects this shape. `User:getId`
  -- reads USER_ID through it, so without a real value it falls through to
  -- Api:me() and the harness would be asserting on the wrong call.
  local function fake_settings(store)
    store = store or {}
    return {
      readSetting = function(_, key) return store[key] end,
      writeSetting = function(_, key, value) store[key] = value return true end,
      updateSetting = function(self, key, value)
        store[key] = value
        return true
      end,
      isEnabled = function() return true end,
      syncEnabled = function() return true end,
      menuConfirm = function() return false end,
      compatibilityMode = function() return true end,
      bookLinked = function() return true end,
      bookStatusFromSnapshot = function() return nil end,
      getLinkedBookId = function() return 4242 end,
      getLinkedEditionId = function() return nil end,
      getLinkedEditionFormat = function() return "epub" end,
      pages = function() return 300 end,
      -- Takes a document path; the real signature is readBookSettings(file).
      readBookSettings = function(_, _file) return { book_id = 4242 } end,
    }
  end

  local settings = fake_settings({ user_id = 4242 })

  -- User:getId reads and writes through a module-level handle set by main.lua.
  local User = require("hardcover/lib/user")
  User.settings = settings

  manager.settings = settings
  manager.ui = {}
  -- journalEntryForm shows its dialog from inside wifiPrompt(callback), which
  -- takes the callback alone and receives the wifi state. The plugin awaits
  -- connectivity before showing here, so this harness must invoke the callback
  -- synchronously -- a stub that never calls it would prove nothing about the
  -- show ordering, which is the whole assertion.
  manager.wifi = {
    wifiPrompt = function(_, cb)
      if type(cb) == "function" then cb(false) end
    end,
  }
  manager.page_mapper = { getMappedPage = function() return 1 end }
  manager.hardcover = { changeBookVisibility = function() end }
  return manager, settings, fake_api
end

local function assert_shows_before_fetch(label, fn)
  reset()
  shown_widgets = {}
  local ok, err = pcall(fn)
  if not ok then
    r.check(label, false, "raised: " .. tostring(err))
    return
  end

  local api_i = index_of("api")
  local show_i = index_of("show")

  if not api_i then
    r.check(label, false, "no API call was made, so nothing was proven")
  elseif not show_i then
    r.check(label, false, "made an API call but never called UIManager:show")
  else
    r.check(label, show_i < api_i, string.format(
      "showed at %d but called the API at %d -- the user waits %ds with no screen",
      show_i, api_i, 6))
  end
end

-- ---------------------------------------------------------------- showShelf
assert_shows_before_fetch("showShelf shows its dialog before fetching the shelf", function()
  local manager = build_manager()
  manager:showShelf(1, "Want to Read")
end)

-- ---------------------------------------------------------------- showBookDetail
assert_shows_before_fetch("showBookDetail shows its dialog before fetching detail", function()
  local manager = build_manager()
  manager:showBookDetail(4242, nil, nil)
end)

-- ---------------------------------------------------------------- updateSearchResults
assert_shows_before_fetch("updateSearchResults reports through a message, not a silent no-op", function()
  local manager = build_manager()
  manager.search_dialog = { title = "Link book", active_item = nil, setItems = function() end }
  manager:updateSearchResults("dune")
end)

-- ---------------------------------------------------------------- journalEntryForm
assert_shows_before_fetch("journalEntryForm shows its dialog before resolving the edition", function()
  local manager = build_manager()
  local document = {
    file = "/books/dune.epub",
    getPageCount = function() return 10 end,
  }
  -- Colon, not dot-with-args: the method is defined as
  -- DialogManager:journalEntryForm(text, document, ...) and indexes self at :163.
  -- Calling it as manager.journalEntryForm(a, b, ...) shifts every argument and
  -- arrives with self = nil -- the same silent shape-shift the harness for
  -- sync_queue had to guard against.
  manager:journalEntryForm(nil, document, 1, nil, nil, "note")
end)

-- ---------------------------------------------------------------- buildLoadingSearchDialog
-- "Change edition", the journal's edition picker and the link-book dialog all
-- route through this. It used to be buildSearchDialog(fetch-then-show) at each
-- call site; the point of the test is that the dialog exists before fetch runs.
assert_shows_before_fetch("buildLoadingSearchDialog shows its dialog before fetching", function()
  local manager, _, Api = build_manager()
  manager:buildLoadingSearchDialog(
    "Select edition",
    function(callback) Api.findEditions(4242, 1, callback) end,
    { edition_id = 1 },
    function() end)
end)

r.finish()