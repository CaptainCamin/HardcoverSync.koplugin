-- Adding a book to your lists from the book details screen.
--
-- Pure data first (which lists a book is on, the picker's labels, the request
-- bodies, how a refusal for a missing scope is told), then the Api calls against a
-- stubbed Api:query (what is sent, tolerant of junk answers), then
-- DialogManager:chooseLists against a fake picker: nothing is sent offline or by a
-- sign-in known to lack the scope, a tap sends one request and shows it in the row,
-- a failure puts the tick back, the lists screen and the details follow.
--
-- Run with:  lua spec/add_to_list_harness.lua [plugin-root]

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
local stack, ticks = {}, {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) stack[#stack + 1] = w end,
    close = function(_, w) for i = #stack, 1, -1 do if stack[i] == w then table.remove(stack, i) end end end,
    isWidgetShown = function(_, w) for _, x in ipairs(stack) do if x == w then return true end end return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    forceRePaint = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
end
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn)
      local co = coroutine.create(fn)
      local ok, err = coroutine.resume(co)
      if not ok then error("wrapped function raised: " .. tostring(err), 0) end
    end,
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
-- a ButtonDialog whose buttons can be read, changed and tapped like the real ones
package.preload["ui/widget/buttondialog"] = function()
  return { new = function(_, o)
    o.is_picker = true
    for _, row in ipairs(o.buttons) do
      local b = row[1]
      b.width, b.enabled = 100, true
      b.setText = function(self, text) self.text = text end
      b.enableDisable = function(self, on) self.enabled = on end
    end
    o.getButtonById = function(self, id)
      for _, row in ipairs(self.buttons) do if row[1].id == id then return row[1] end end
    end
    return o
  end }
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
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local Lists = real_require("hardcover/lib/lists")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
User.getId = function() return 1 end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- ------------------------------------------------------------ pure data
print("\n== which lists a book is on ==")

local me = { {
  lists = {
    { id = 1, name = "To Read - SciFi", books_count = 7, ranked = true, privacy_setting_id = 1,
      list_books = { { id = 501 } } },
    { id = 2, name = "Grin", books_count = 4, ranked = false, privacy_setting_id = 1, list_books = {} },
    { id = 3, name = "Research", books_count = 1, ranked = false, privacy_setting_id = 3, list_books = { { id = 502 } } },
    { name = "no id" },
  },
  followed_lists = { { list = { id = 106, name = "Not yours", books_count = 3 } } },
} }

check("your lists come out in order, each with the book's list_books id when it is on it", function()
  local rows = Lists.membership(me)
  assert(#rows == 3, "rows: " .. #rows)
  assert(rows[1].id == 1 and rows[1].on and rows[1].list_book_id == 501 and rows[1].ranked and rows[1].count == 7)
  assert(rows[2].id == 2 and not rows[2].on and rows[2].list_book_id == nil)
  assert(rows[3].private == true and rows[3].list_book_id == 502)
end)

check("followed lists are left out: they cannot be added to", function()
  for _, row in ipairs(Lists.membership(me)) do assert(row.id ~= 106) end
end)

check("junk never raises: nil, strings, empty tables, the bare object, odd list_books", function()
  for _, junk in ipairs({ "x", 5, {}, { {} }, { { lists = "no" } }, { { lists = { "x", 5 } } } }) do
    assert(#Lists.membership(junk) == 0)
  end
  assert(#Lists.membership(nil) == 0)
  assert(#Lists.membership(me[1]) == 3, "the bare object is accepted too")
  local odd = Lists.membership({ lists = { { id = 9, name = "a", list_books = "x" },
                                           { id = 8, name = "b", list_books = { {} } } } })
  assert(not odd[1].on and odd[2].on and odd[2].list_book_id == nil, "an answer without an id is still 'on'")
end)

check("the names under the status: only the lists it is on, none when none", function()
  local rows = Lists.membership(me)
  assert(Lists.onNames(rows) == "To Read - SciFi, Research", tostring(Lists.onNames(rows)))
  rows[1].on, rows[3].on = false, false
  assert(Lists.onNames(rows) == nil)
  assert(Lists.onNames(nil) == nil and Lists.onNames("x") == nil)
end)

check("a picker row shows the tick, the name, the size, ranked, and ... while saving", function()
  local rows = Lists.membership(me)
  assert(Lists.pickerLabel(rows[1]) == "\226\152\145  To Read - SciFi (7) \194\183 ranked", Lists.pickerLabel(rows[1]))
  assert(Lists.pickerLabel(rows[2]) == "\226\152\144  Grin (4)", Lists.pickerLabel(rows[2]))
  rows[2].busy = true
  assert(Lists.pickerLabel(rows[2]) == "\226\152\144  Grin (4) \226\128\166")
end)

check("adding and removing move the tick, the id and the count (never below 0)", function()
  local row = { id = 1, name = "x", count = 0, on = false }
  Lists.markAdded(row, "77")
  assert(row.on and row.list_book_id == 77 and row.count == 1)
  Lists.markRemoved(row)
  assert(not row.on and row.list_book_id == nil and row.count == 0)
  Lists.markRemoved(row)
  assert(row.count == 0)
end)

check("the request body puts the book at the end of the list, with no edition", function()
  local o = Lists.insertObject(100, 1, 7)
  assert(o.book_id == 100 and o.list_id == 1 and o.position == 7 and o.edition_id == nil)
  assert(Lists.insertObject(100, 1, nil).position == 0)
end)

check("the new row's id is found whichever way the payload carries it", function()
  assert(Lists.listBookId({ id = 5 }) == 5 and Lists.listBookId({ list_book = { id = "6" } }) == 6)
  assert(Lists.listBookId({}) == nil and Lists.listBookId("x") == nil and Lists.listBookId(nil) == nil)
end)

check("a refusal for the scope is told from any other failure", function()
  assert(Lists.isScopeError({ errors = { { message = "insufficient_scope" } }, status = 200 }))
  assert(Lists.isScopeError({ errors = { "insufficient_scope" } }))
  assert(Lists.isScopeError({ errors = { { extensions = { code = "forbidden" } } }, status = 403 }))
  assert(Lists.isScopeError("Missing scope write:lists"))
  assert(not Lists.isScopeError({ completed = false }))
  assert(not Lists.isScopeError({ errors = { { message = "Book not found" } }, status = 200 }))
  assert(not Lists.isScopeError(nil) and not Lists.isScopeError(5) and not Lists.isScopeError({}))
end)

check("the scope is asked for at sign-in, spelled the same everywhere", function()
  for _, file in ipairs({ "hardcover/lib/auth.lua", "hardcover/lib/default_config.lua" }) do
    local f = assert(io.open(PLUGIN .. "/" .. file, "rb"))
    local src = f:read("*a")
    f:close()
    local scope = src:match('scope = "([^"]+)"') or src:match('DEFAULT_SCOPE = "([^"]+)"')
    assert(scope and (" " .. scope .. " "):find(" " .. Lists.WRITE_SCOPE .. " ", 1, true),
      file .. " does not request " .. Lists.WRITE_SCOPE)
  end
  assert(Lists.WRITE_SCOPE == "write:lists")
end)

-- ------------------------------------------------------------ api
print("\n== the requests ==")

local sent
local function answer(result, err)
  Api.enabled = true
  Api.query = function(_, q, vars) sent = { q = q, vars = vars }; return result, err end
end

check("getBookLists asks for your lists with this book's rows, nothing for followed ones", function()
  answer({ me = me })
  local rows = Api:getBookLists(100)
  assert(rows and #rows == 3 and rows[1].list_book_id == 501)
  assert(sent.vars.bookId == 100 and sent.q:find("list_books(where: { book_id: { _eq: $bookId } })", 1, true), "wrong query")
  assert(not sent.q:find("followed_lists", 1, true), "asked for followed lists")
end)

check("getBookLists: a failed or junk answer is nil with an error, never a crash", function()
  answer(nil, { completed = false })
  local rows, err = Api:getBookLists(100)
  assert(rows == nil and err and err.completed == false)
  for _, junk in ipairs({ {}, { me = "x" }, { me = false } }) do
    answer(junk)
    rows, err = Api:getBookLists(100)
    assert(rows == nil and err, "a junk answer gave rows")
  end
end)

check("addToList sends one insert_list_book with the list, the book and the end position", function()
  answer({ insert_list_book = { id = 900 } })
  local out = Api:addToList(100, 1, 7)
  assert(out and out.id == 900)
  assert(sent.q:find("insert_list_book(object: $object)", 1, true), "wrong mutation")
  local o = sent.vars.object
  assert(o.book_id == 100 and o.list_id == 1 and o.position == 7 and o.edition_id == nil)
end)

-- The API's ListBookIdType is { id, list_book }. insert_user_book has an `error`
-- field, so it was easy to copy it here; selecting a field the type lacks fails the
-- whole request on validation, which no stub would ever show.
check("addToList asks only for fields the API's ListBookIdType has", function()
  answer({ insert_list_book = { id = 1 } })
  Api:addToList(100, 1, 7)
  local selection = sent.q:match("insert_list_book%(object: %$object%)%s*(%b{})")
  assert(selection, "could not read the selection")
  for word in selection:gmatch("[%a_]+") do
    assert(word == "id" or word == "list_book", "selects a field ListBookIdType does not have: " .. word)
  end
end)

check("addToList: a nested list_book id, or no id at all, still counts as added", function()
  answer({ insert_list_book = { list_book = { id = 12 } } })
  assert(Api:addToList(100, 1, 7).id == 12)
  answer({ insert_list_book = {} })
  local out = Api:addToList(100, 1, 7)
  assert(out and out.id == nil)
end)

check("addToList: Hardcover's own refusal comes back as its text", function()
  answer({ insert_list_book = { error = "List not found" } })
  local out, err = Api:addToList(100, 1, 7)
  assert(out == nil and err == "List not found")
end)

check("addToList: failures and junk answers are nil with an error", function()
  answer(nil, { errors = { "insufficient_scope" }, status = 403 })
  local out, err = Api:addToList(100, 1, 7)
  assert(out == nil and Lists.isScopeError(err), "the scope refusal was lost")
  for _, junk in ipairs({ {}, { insert_list_book = "x" }, { insert_list_book = false }, { other = 1 } }) do
    answer(junk)
    out, err = Api:addToList(100, 1, 7)
    assert(out == nil and err, "a junk answer counted as added")
  end
end)

check("removeFromList deletes by the list_books row's id", function()
  answer({ delete_list_book = { id = 501 } })
  local out = Api:removeFromList(501)
  assert(out and out.id == 501)
  assert(sent.q:find("delete_list_book(id: $id)", 1, true), "wrong mutation")
  assert(sent.vars.id == 501)
  answer(nil, { completed = false })
  local none, err = Api:removeFromList(501)
  assert(none == nil and err.completed == false)
  answer({ delete_list_book = "x" })
  assert(Api:removeFromList(501) == nil)
end)

check("the async wrappers run inside a coroutine and deliver the answer", function()
  local in_co = {}
  Api.getBookLists = function() in_co[1] = coroutine.running() ~= nil; return { { id = 1 } } end
  Api.addToList = function() in_co[2] = coroutine.running() ~= nil; return { id = 3 } end
  Api.removeFromList = function() in_co[3] = coroutine.running() ~= nil; return { id = 4 } end
  local got = {}
  Api:getBookListsAsync(1, function(x) got[1] = x end)
  Api:addToListAsync(1, 2, 3, function(x) got[2] = x end)
  Api:removeFromListAsync(4, function(x) got[3] = x end)
  for _, fn in ipairs(ticks) do fn() end
  ticks = {}
  assert(in_co[1] and in_co[2] and in_co[3], "ran on the main thread (it would freeze the UI)")
  assert(got[1][1].id == 1 and got[2].id == 3 and got[3].id == 4)
end)

-- ------------------------------------------------------------ the flow
print("\n== the picker ==")

local calls, cbs
local function queue(name)
  return function(_, ...)
    local args = { ... }
    local cb = table.remove(args)
    calls[#calls + 1] = { name = name, args = args }
    cbs[#cbs + 1] = cb
  end
end
Api.getBookListsAsync = queue("getBookLists")
Api.addToListAsync = queue("addToList")
Api.removeFromListAsync = queue("removeFromList")

local infos, errors, retries, loads
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.error = function(text) errors[#errors + 1] = text end
StatusDialogs.loading = function() loads = loads + 1; return { __loading = true } end
StatusDialogs.close = function() end
StatusDialogs.retry = function(err, op, again) retries[#retries + 1] = { err = err, op = op, again = again } end

local scope = nil -- what auth:hasScope says
Api.auth = { hasScope = function(_, s) assert(s == "write:lists"); return scope end }

local UIM = real_require("ui/uimanager")
local lists_screen
local function newManager()
  calls, cbs, infos, errors, retries, loads = {}, {}, {}, {}, {}, 0
  stack, ticks = {}, {}
  scope = nil
  lists_screen = { mine = { { id = 1, count = 7 }, { id = 2, count = 4 } }, rebuilt = 0 }
  function lists_screen:rebuild() self.rebuilt = self.rebuilt + 1 end
  UIM:show(lists_screen)
  return setmetatable({ settings = {}, lists_dialog = lists_screen }, { __index = DialogManager })
end

local function detailScreen(lists)
  local d = { detail = { book = { book_id = 100, title = "Obelisk" }, lists = lists }, synced = {} }
  function d:setLists(rows) self.synced[#self.synced + 1] = rows end
  UIM:show(d)
  return d
end
local function rowsFor() return Lists.membership(me) end

-- run `fn` and hand back the picker it showed, if any
local function showing(fn)
  local shown
  local real_show = UIM.show
  UIM.show = function(self, w) if w.is_picker then shown = w end; return real_show(self, w) end
  fn()
  UIM.show = real_show
  return shown
end
local function open(m, d)
  return showing(function() m:chooseLists(d) end)
end
local function button(p, needle)
  for _, row in ipairs(p.buttons) do
    if row[1].text:find(needle, 1, true) then return row[1] end
  end
  error("no button " .. needle)
end
local function tap(p, needle)
  local b = button(p, needle)
  if b.enabled then b.callback() end
  return b
end
local function answerLast(...)
  local cb = table.remove(cbs)
  cb(...)
  for _, fn in ipairs(ticks) do fn() end
  ticks = {}
end

check("offline: says so, loads nothing, shows no picker", function()
  online = false
  local m = newManager()
  local p = open(m, detailScreen(nil))
  online = true
  assert(p == nil and #calls == 0 and loads == 0, "did something offline")
  assert(#infos == 1 and infos[1]:lower():find("offline"), "no offline message")
end)

check("a sign-in known to lack the scope gets the sign-out-and-in message and no request", function()
  local m = newManager()
  scope = false
  local p = open(m, detailScreen(rowsFor()))
  assert(p == nil and #calls == 0 and loads == 0, "sent something")
  assert(#infos == 1 and infos[1] == "Sign out and back in (Settings > Account) to add books to lists.", infos[1])
end)

check("an unknown scope (a personal token) just tries", function()
  local m = newManager()
  scope = nil
  assert(open(m, detailScreen(rowsFor())), "no picker")
  local keep = Api.auth
  Api.auth = nil
  m = newManager()
  assert(open(m, detailScreen(rowsFor())), "no picker without auth")
  Api.auth = keep
end)

check("the first open loads the lists once, the second asks nothing", function()
  local m = newManager()
  local d = detailScreen(nil)
  assert(open(m, d) == nil and #calls == 1 and calls[1].name == "getBookLists" and calls[1].args[1] == 100)
  assert(loads == 1)
  local p = showing(function() answerLast(rowsFor()) end)
  assert(p, "the picker did not open when the lists arrived")
  assert(d.detail.lists and #d.detail.lists == 3)
  calls = {}
  assert(open(m, d), "no picker the second time")
  assert(#calls == 0, "asked again")
end)

check("a failed load offers a retry and shows nothing; a closed screen is not opened on", function()
  local m = newManager()
  local d = detailScreen(nil)
  open(m, d)
  answerLast(nil, { completed = false })
  assert(#retries == 1 and retries[1].err.completed == false and not d.detail.lists)
  retries[1].again()
  assert(#calls == 2, "retry did not ask again")
  UIM:close(d)
  local p = showing(function() answerLast(rowsFor()) end)
  assert(p == nil, "opened a picker over a closed screen")
end)

check("no lists at all says so instead of an empty picker", function()
  local m = newManager()
  local p = open(m, detailScreen({}))
  assert(p == nil and #infos == 1 and infos[1]:find("no lists yet", 1, true))
end)

check("the picker shows each list ticked or not, then Done", function()
  local m = newManager()
  local p = open(m, detailScreen(rowsFor()))
  assert(#p.buttons == 4, "rows: " .. #p.buttons)
  assert(p.buttons[1][1].text:find("\226\152\145  To Read - SciFi", 1, true))
  assert(p.buttons[2][1].text:find("\226\152\144  Grin", 1, true))
  assert(p.buttons[4][1].text == "Done")
end)

check("ticking sends one add at the end of the list and shows it saving", function()
  local m = newManager()
  local p = open(m, detailScreen(rowsFor()))
  local b = tap(p, "Grin")
  assert(#calls == 1 and calls[1].name == "addToList", "no add")
  local a = calls[1].args
  assert(a[1] == 100 and a[2] == 2 and a[3] == 4, "args: " .. table.concat(a, ","))
  assert(b.text:find("\226\128\166", 1, true) and not b.enabled, "not shown saving: " .. b.text)
  tap(p, "Grin")
  assert(#calls == 1, "a second tap while saving sent another request")
end)

check("the answer ticks the row, counts it, keeps the id, and updates the lists screen", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "Grin")
  answerLast({ id = 900 })
  local b = button(p, "Grin")
  assert(b.text == "\226\152\145  Grin (5)" and b.enabled, "label: " .. b.text)
  assert(d.detail.lists[2].on and d.detail.lists[2].list_book_id == 900 and d.detail.lists[2].count == 5)
  assert(lists_screen.mine[2].count == 5 and lists_screen.rebuilt == 1, "lists screen not refreshed")
  assert(#d.synced == 0, "rebuilt the details behind the open picker")
end)

check("unticking sends the delete with the list_books id and the tick goes", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "To Read")
  assert(#calls == 1 and calls[1].name == "removeFromList" and calls[1].args[1] == 501, "no delete of 501")
  answerLast({ id = 501 })
  assert(button(p, "To Read").text == "\226\152\144  To Read - SciFi (6) \194\183 ranked", button(p, "To Read").text)
  assert(not d.detail.lists[1].on and d.detail.lists[1].list_book_id == nil)
  assert(lists_screen.mine[1].count == 6)
end)

check("a failed add puts the tick back, says why, and allows another try", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "Grin")
  answerLast(nil, "List not found")
  local b = button(p, "Grin")
  assert(b.text == "\226\152\144  Grin (4)" and b.enabled, "label: " .. b.text)
  assert(not d.detail.lists[2].on and d.detail.lists[2].count == 4)
  assert(#errors == 1 and errors[1]:find("Grin", 1, true) and errors[1]:find("List not found", 1, true), tostring(errors[1]))
  assert(lists_screen.rebuilt == 0, "the lists screen changed for a change that did not happen")
  tap(p, "Grin")
  assert(#calls == 2, "could not try again")
end)

check("a failed remove keeps the tick", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "Research")
  answerLast(nil, { completed = false })
  assert(button(p, "Research").text:find("\226\152\145", 1, true), "tick lost")
  assert(d.detail.lists[3].on and d.detail.lists[3].list_book_id == 502 and d.detail.lists[3].count == 1)
  assert(#errors == 1)
end)

check("an insufficient_scope answer gives the sign-in message, not a failure report", function()
  local m = newManager()
  local p = open(m, detailScreen(rowsFor()))
  tap(p, "Grin")
  answerLast(nil, { errors = { "insufficient_scope" }, status = 403 })
  assert(#errors == 0 and #infos == 1 and infos[1]:find("Sign out and back in", 1, true), "wrong message")
  assert(button(p, "Grin").text == "\226\152\144  Grin (4)", "tick not restored")
end)

check("offline at the tap sends nothing and leaves the row alone", function()
  local m = newManager()
  local p = open(m, detailScreen(rowsFor()))
  online = false
  tap(p, "Grin")
  online = true
  assert(#calls == 0 and #infos == 1 and infos[1]:lower():find("offline"))
  assert(button(p, "Grin").enabled and button(p, "Grin").text == "\226\152\144  Grin (4)")
end)

check("Done closes the picker and the details name the lists once", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "Grin")
  answerLast({ id = 900 })
  tap(p, "Done")
  assert(not UIM:isWidgetShown(p), "still open")
  assert(#d.synced == 1 and d.synced[1] == d.detail.lists and d.synced[1][2].on)
end)

check("dismissing the picker by a tap outside also updates the details, once", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  p.tap_close_callback()
  assert(#d.synced == 1)
end)

check("an answer after the picker closed still updates the details", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "Grin")
  tap(p, "Done")
  answerLast({ id = 900 })
  assert(#d.synced == 2 and d.synced[2][2].on, "synced: " .. #d.synced)
end)

check("a closed details screen is not touched by a late answer", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "Grin")
  UIM:close(d)
  tap(p, "Done")
  answerLast({ id = 900 })
  assert(#d.synced == 0)
end)

check("unticking a list added without an id looks the id up first", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "Grin")
  answerLast({}) -- added, but the answer carried no id
  assert(d.detail.lists[2].on and d.detail.lists[2].list_book_id == nil)
  calls = {}
  tap(p, "Grin")
  assert(#calls == 1 and calls[1].name == "getBookLists", "did not look it up")
  local fresh = rowsFor()
  fresh[2].on, fresh[2].list_book_id = true, 777
  answerLast(fresh)
  assert(#calls == 2 and calls[2].name == "removeFromList" and calls[2].args[1] == 777, "did not delete 777")
  answerLast({ id = 777 })
  assert(not d.detail.lists[2].on)
end)

check("the lookup failing restores the tick", function()
  local m = newManager()
  local d = detailScreen(rowsFor())
  local p = open(m, d)
  tap(p, "Grin")
  answerLast({})
  tap(p, "Grin")
  answerLast(nil, { completed = false })
  assert(d.detail.lists[2].on and button(p, "Grin").text:find("\226\152\145", 1, true) and #errors == 1)
end)

check("the Lists button is offered only to an OAuth sign-in that is still good", function()
  local m = newManager()
  local keep = Api.auth
  Api.auth = nil
  assert(not m:canChooseLists())
  Api.auth = { usingOAuth = function() return false end, needsReauth = function() return false end }
  assert(not m:canChooseLists(), "offered to a personal token")
  Api.auth = { usingOAuth = function() return true end, needsReauth = function() return true end }
  assert(not m:canChooseLists(), "offered when signed out")
  Api.auth = { usingOAuth = function() return true end, needsReauth = function() return false end }
  assert(m:canChooseLists())
  Api.auth = keep
end)

r.finish()
