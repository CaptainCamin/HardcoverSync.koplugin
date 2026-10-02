-- Searching for books from the Home screen.
--
-- Drives BookSearch and DialogManager:showSearchInput / searchBooks /
-- showSearchResults with fake dialogs and a switchable network, and checks what
-- the reader would see: no request for an empty query or while offline, one
-- request per submit, results capped, an empty answer shown as "No results", a
-- failure shown as a retry, a tap on a result opening that book's details.
--
-- Run with:  lua spec/book_search_harness.lua [plugin-root]

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

local online = true
local stack = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) stack[#stack + 1] = w end,
    close = function(_, w) for i = #stack, 1, -1 do if stack[i] == w then table.remove(stack, i) end end end,
    isWidgetShown = function(_, w) for _, x in ipairs(stack) do if x == w then return true end end return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    forceRePaint = function() end, nextTick = function(_, fn) fn() end,
  }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) fn() end }
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

-- the input dialog: records what it was built with and what is typed into it
local inputs = {}
package.preload["ui/widget/inputdialog"] = function()
  return {
    new = function(_, o)
      o.typed = o.input or ""
      o.getInputText = function(self) return self.typed end
      o.onShowKeyboard = function() end
      inputs[#inputs + 1] = o
      return o
    end,
  }
end

local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local UIManager = real_require("ui/uimanager")
local Api = real_require("hardcover/lib/hardcover_api")
local User = real_require("hardcover/lib/user")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local BookSearch = real_require("hardcover/lib/book_search")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
User.getId = function() return 1 end

local searches, answer
Api.findBooksAsync = function(_, title, author, user_id, cb)
  searches[#searches + 1] = title
  cb(answer.books, answer.err)
end

local errors, retries, loadings, closed_loadings
StatusDialogs.error = function(text) errors[#errors + 1] = text end
StatusDialogs.loading = function() loadings = loadings + 1; return { __loading = true } end
StatusDialogs.close = function() closed_loadings = closed_loadings + 1 end
StatusDialogs.retry = function(err, op, retry_cb) retries[#retries + 1] = { err = err, op = op, retry = retry_cb } end

local shelf_class = real_require("hardcover/lib/ui/shelf_dialog")
local results_dialogs
shelf_class.new = function(_, o)
  o.setEmptyState = function(self, m) self.empty = m end
  o.free = function() end
  results_dialogs[#results_dialogs + 1] = o
  return o
end

local details
local function manager()
  searches, errors, retries, loadings, closed_loadings = {}, {}, {}, 0, 0
  results_dialogs, details, stack, inputs = {}, {}, {}, {}
  answer = { books = {} }
  online = true
  local m = setmetatable({
    settings = { compatibilityMode = function() return false end, readSetting = function() return nil end, updateSetting = function() end },
  }, { __index = DialogManager })
  m.showBookDetail = function(_, id) details[#details + 1] = id end
  return m
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end
local function books(n)
  local out = {}
  for i = 1, n do out[i] = { book_id = i, title = "B" .. i } end
  return out
end
local function submit(m, text)
  local input = m:showSearchInput()
  input.typed = text
  input.buttons[1][2].callback()
  return input
end

print("\n== the text to search for ==")
check("surrounding spaces are dropped", function()
  assert(BookSearch.normalize("  dune  ") == "dune")
end)
check("nothing, spaces and non-text are not a query", function()
  assert(BookSearch.normalize("") == nil and BookSearch.normalize("   \t") == nil
    and BookSearch.normalize(nil) == nil and BookSearch.normalize(5) == nil)
end)
check("inner spaces are kept", function()
  assert(BookSearch.normalize(" the left hand ") == "the left hand")
end)
check("results are capped at 25, in order", function()
  local capped = BookSearch.cap(books(40))
  assert(#capped == 25 and capped[1].book_id == 1 and capped[25].book_id == 25, #capped)
  assert(#BookSearch.cap(books(3)) == 3 and #BookSearch.cap(nil) == 0)
end)

print("\n== the input ==")
check("the input has a Cancel and a Search button, Search on Enter", function()
  local m = manager()
  local input = m:showSearchInput()
  assert(UIManager:isWidgetShown(input))
  assert(input.buttons[1][2].is_enter_default == true)
  assert(input.buttons[1][1].text == "Cancel" and input.buttons[1][2].text == "Search")
end)
check("an empty submit makes no request and leaves the input open", function()
  local m = manager()
  local input = submit(m, "   ")
  assert(#searches == 0, "searched for nothing")
  assert(UIManager:isWidgetShown(input), "closed the input")
  assert(loadings == 0)
end)
check("Cancel closes the input without searching", function()
  local m = manager()
  local input = m:showSearchInput()
  input.buttons[1][1].callback()
  assert(not UIManager:isWidgetShown(input) and #searches == 0)
end)
check("nothing is searched while typing: only submitting searches", function()
  local m = manager()
  local input = m:showSearchInput()
  input.typed = "earth"
  input.typed = "earthsea"
  assert(#searches == 0)
end)

print("\n== searching ==")
check("a submit closes the input, searches once with the trimmed text and shows the results", function()
  local m = manager()
  answer = { books = books(3) }
  local input = submit(m, "  earthsea ")
  assert(not UIManager:isWidgetShown(input), "input left open")
  assert(#searches == 1 and searches[1] == "earthsea", table.concat(searches, "|"))
  assert(loadings == 1 and closed_loadings == 1, "loading message not shown and closed")
  local d = results_dialogs[1]
  assert(d and #d.entries == 3 and d.title == "\"earthsea\"")
  assert(d.has_more == false)
  assert(UIManager:isWidgetShown(d))
end)
check("results are capped at 25", function()
  local m = manager()
  answer = { books = books(60) }
  submit(m, "x")
  assert(#results_dialogs[1].entries == 25)
end)
check("tapping a result opens that book's details", function()
  local m = manager()
  answer = { books = books(3) }
  submit(m, "x")
  results_dialogs[1].select_entry_cb({ book_id = 2 })
  assert(details[1] == 2, tostring(details[1]))
end)
check("no matches is shown as 'No results', not a blank list", function()
  local m = manager()
  answer = { books = {} }
  submit(m, "zzz")
  assert(results_dialogs[1].empty == "No results", tostring(results_dialogs[1].empty))
end)
check("a failure offers a retry that searches again, and shows no results", function()
  local m = manager()
  answer = { books = nil, err = { completed = false } }
  submit(m, "dune")
  assert(#results_dialogs == 0, "showed results for a failure")
  assert(#retries == 1 and retries[1].op == "Searching for books")
  answer = { books = books(2) }
  retries[1].retry()
  assert(#searches == 2 and searches[2] == "dune" and #results_dialogs == 1)
end)
check("a second search replaces the first results", function()
  local m = manager()
  answer = { books = books(2) }
  submit(m, "a")
  submit(m, "b")
  assert(#results_dialogs == 2 and not UIManager:isWidgetShown(results_dialogs[1])
    and UIManager:isWidgetShown(results_dialogs[2]))
end)
check("offline: a clear message and no request", function()
  local m = manager()
  online = false
  m:searchBooks("dune")
  assert(#searches == 0, "requested while offline")
  assert(#errors == 1 and errors[1]:find("internet", 1, true), tostring(errors[1]))
  assert(loadings == 0 and #results_dialogs == 0)
end)

print("\n== the home screen's button ==")
check("showHome gives the home screen a search callback that opens the input", function()
  local m = manager()
  m.shelf_cache = nil
  online = false
  local home_class = real_require("hardcover/lib/ui/home_dialog")
  local built
  home_class.new = function(_, o) built = o; return o end
  m:showHome()
  assert(type(built.search_cb) == "function", "no search callback")
  built.search_cb()
  assert(#inputs == 1, "the callback did not open the input")
end)

r.finish()
