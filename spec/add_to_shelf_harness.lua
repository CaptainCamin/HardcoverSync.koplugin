-- Adding a book to a shelf, changing its status and removing it, from the book
-- details screen.
--
-- Drives DialogManager:chooseShelf / saveShelf / removeFromShelf against a real
-- shelf cache, a switchable network, a fake ButtonDialog and fake dialog
-- classes, and checks the request that is sent (status ids), that nothing is
-- sent offline or before a confirmation, that the screen is told, and that the
-- saved shelves are not left stale. Also the cache's invalidate, the Api
-- mutations and the pure helpers.
--
-- Run with:  lua spec/add_to_shelf_harness.lua [plugin-root]

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
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local UIManager_close = function(w) require("ui/uimanager"):close(w) end
local Api = real_require("hardcover/lib/hardcover_api")
local User = real_require("hardcover/lib/user")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local ShelfCache = real_require("hardcover/lib/shelf_cache")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
-- waiting is the real thing's job (it yields to KOReader); here it is counted
local slept = 0
real_require("hardcover/lib/background").sleep = function(seconds) slept = slept + seconds end
User.getId = function() return 1 end


package.preload["ui/widget/buttondialog"] = function()
  return { new = function(_, o) o.is_picker = true; return o end }
end

local Api = real_require("hardcover/lib/hardcover_api")
local User = real_require("hardcover/lib/user")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local ShelfCache = real_require("hardcover/lib/shelf_cache")
local Shelf = real_require("hardcover/lib/shelf")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
User.getId = function() return 1 end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- ------------------------------------------------------------ pure helpers
print("\n== statuses ==")

check("the shelves offered map to Hardcover's status ids", function()
  local want = { { 1, "Want to Read" }, { 2, "Currently Reading" }, { 3, "Read" }, { 5, "Did Not Finish" } }
  local got = Shelf.statusChoices()
  assert(#got == 4, "choices: " .. #got)
  for i, w in ipairs(want) do
    assert(got[i].status_id == w[1] and got[i].label == w[2], "choice " .. i .. " is " .. tostring(got[i].status_id))
  end
end)

check("the shelf button says where the book is, or invites adding it", function()
  assert(Shelf.shelfButtonText(nil) == "Add to shelf")
  assert(Shelf.shelfButtonText(1) == "Change shelf")
  assert(Shelf.shelfButtonText(5) == "Change shelf")
end)

-- ------------------------------------------------------------ cache
print("\n== the shelf cache after a change ==")

local function newCache()
  local data = {}
  local store = {
    readSetting = function(_, k) return data[k] end,
    saveSetting = function(_, k, v) data[k] = v end,
    flush = function() end,
  }
  return ShelfCache:new { path = "/x", open = function() return store end }, data
end
local function row(id, status) return { book_id = id, title = "B" .. id, status_id = status } end

check("invalidate drops the old and new shelves, the counts and the reading list", function()
  local c = newCache()
  c:put(1, 1, { row(1, 1) }, true)
  c:put(1, 3, { row(2, 3) }, true)
  c:put(1, 5, { row(3, 5) }, true)
  c:put(1, nil, { row(1, 1) }, true)
  c:putCounts(1, { [1] = 1, [3] = 1, [5] = 1 })
  c:putReading(1, { row(9, 2) })
  assert(c:invalidate(1, { 1, 3 }))
  assert(c:get(1, 1) == nil, "old shelf kept")
  assert(c:get(1, 3) == nil, "new shelf kept")
  assert(c:get(1, nil) == nil, "the unfiltered list kept")
  assert(c:get(1, 5) ~= nil, "an unrelated shelf was dropped")
  assert(c:counts(1, { 1, 3 })[1] == nil and c:counts(1, { 1, 3 })[3] == nil, "stale counts kept")
  assert(c:reading(1) == nil, "stale reading list kept")
end)

check("invalidate leaves another user's data alone", function()
  local c = newCache()
  c:put(2, 1, { row(1, 1) }, true)
  c:putCounts(2, { [1] = 7 })
  c:putReading(2, { row(9, 2) })
  c:invalidate(1, { 1 })
  assert(c:get(2, 1) ~= nil and c:counts(2, { 1 })[1] == 7 and c:reading(2) ~= nil, "touched user 2")
end)

check("invalidate on an empty or unreadable cache is harmless", function()
  local c = newCache()
  assert(c:invalidate(1, { 1 }))
  assert(c:invalidate(1, nil))
  local broken = ShelfCache:new { path = "/x", open = function() error("no") end }
  assert(broken:invalidate(1, { 1 }) == false)
end)

-- ------------------------------------------------------------ api
print("\n== the mutations ==")

local sent
local function answer(result, err)
  Api.enabled = true
  Api.query = function(_, q, vars) sent = { q = q, vars = vars }; return result, err end
end

check("removeUserBook deletes by the library record's id", function()
  answer({ delete_user_book = { id = 55 } })
  local out = Api:removeUserBook(55)
  assert(out and out.id == 55)
  assert(sent.q:find("delete_user_book(id: $id)", 1, true), "wrong mutation")
  assert(sent.vars.id == 55)
end)

check("a failed delete returns nothing, with the error", function()
  answer(nil, { completed = false })
  local out, err = Api:removeUserBook(55)
  assert(out == nil and err and err.completed == false)
end)

check("updateUserBook sends the status and book, and returns the record", function()
  answer({ insert_user_book = { user_book = { id = 7, status_id = 3 } } })
  local out = Api:updateUserBook(100, 3, 1, nil)
  assert(out and out.id == 7)
  assert(sent.vars.object.book_id == 100 and sent.vars.object.status_id == 3, "wrong object")
end)

check("an insert refused by Hardcover returns its error text", function()
  answer({ insert_user_book = { error = "Book not found" } })
  local out, err = Api:updateUserBook(100, 3, 1, nil)
  assert(out == nil and err == "Book not found")
end)

check("the async wrappers run inside a coroutine and deliver the answer", function()
  local in_co
  Api.updateUserBook = function() in_co = coroutine.running() ~= nil; return { id = 3 }, nil end
  Api.removeUserBook = function() return { id = 4 } end
  local got
  Api:updateUserBookAsync(1, 2, 1, nil, function(ub) got = ub end)
  for _, fn in ipairs(ticks) do fn() end
  assert(in_co, "ran on the main thread (it would freeze the UI)")
  assert(got and got.id == 3)
  ticks = {}
  local removed
  Api:removeUserBookAsync(4, function(x) removed = x end)
  for _, fn in ipairs(ticks) do fn() end
  assert(removed and removed.id == 4)
  ticks = {}
end)

-- ------------------------------------------------------------ the flow
print("\n== choosing a shelf ==")

local update_calls, remove_calls, update_cb, remove_cb
Api.updateUserBookAsync = function(_, book_id, status_id, privacy, edition_id, cb)
  update_calls[#update_calls + 1] = { book_id = book_id, status_id = status_id, edition_id = edition_id }
  update_cb = cb
end
Api.removeUserBookAsync = function(_, id, cb)
  remove_calls[#remove_calls + 1] = id
  remove_cb = cb
end

local infos, retries, confirms
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.loading = function() return { __loading = true } end
StatusDialogs.close = function() end
StatusDialogs.retry = function(err, op, again) retries[#retries + 1] = { err = err, op = op, again = again } end
StatusDialogs.confirm = function(o) confirms[#confirms + 1] = o end

local shown
local UIM = real_require("ui/uimanager")
local function newManager()
  local data = {}
  local store = {
    readSetting = function(_, k) return data[k] end,
    saveSetting = function(_, k, v) data[k] = v end,
    flush = function() end,
  }
  update_calls, remove_calls, update_cb, remove_cb = {}, {}, nil, nil
  infos, retries, confirms = {}, {}, {}
  stack, ticks = {}, {}
  local m = setmetatable({
    settings = {},
    shelf_cache = ShelfCache:new { path = "/x", open = function() return store end },
  }, { __index = DialogManager })
  m.shelf_cache:put(1, 1, { row(1, 1) }, true)
  m.shelf_cache:put(1, 2, { row(2, 2) }, true)
  m.shelf_cache:put(1, 3, { row(3, 3) }, true)
  m.shelf_cache:putCounts(1, { [1] = 1, [2] = 1, [3] = 1 })
  return m
end

-- a details screen that records what it is told
local function detailScreen(detail)
  local d = { detail = detail, status_updates = {} }
  function d:setStatus(status_id, user_book_id)
    self.status_updates[#self.status_updates + 1] = { status_id, user_book_id }
    self.detail.status_id, self.detail.user_book_id = status_id, user_book_id
  end
  UIM:show(d)
  return d
end

local function picker(m, d)
  shown = nil
  local real_show = UIM.show
  UIM.show = function(self, w) if w.is_picker then shown = w end; return real_show(self, w) end
  m:chooseShelf(d)
  UIM.show = real_show
  return shown
end
local function labels(p)
  local out = {}
  for _, row_ in ipairs(p.buttons) do out[#out + 1] = row_[1].text end
  return out
end
local function press(p, label)
  for _, row_ in ipairs(p.buttons) do
    local text = row_[1].text
    if text == label or text == "\226\128\162 " .. label then
      row_[1].callback()
      return true
    end
  end
  error("no button " .. label)
end

local NEW = function() return { book = { book_id = 100, title = "Obelisk", edition_id = 10001 } } end
local SHELVED = function() return { book = { book_id = 100, title = "Obelisk" }, status_id = 1, user_book_id = 55 } end

check("a book not in the library gets the four shelves and no Remove", function()
  online = true
  local m = newManager()
  local p = picker(m, detailScreen(NEW()))
  assert(p, "no picker")
  local got = labels(p)
  assert(table.concat(got, "|") == "Want to Read|Currently Reading|Read|Did Not Finish|Cancel", table.concat(got, "|"))
end)

check("a shelved book also gets Remove from library, and its current shelf is marked", function()
  online = true
  local m = newManager()
  local p = picker(m, detailScreen(SHELVED()))
  local got = table.concat(labels(p), "|")
  assert(got:find("Remove from library", 1, true), got)
  assert(got:find("\226\128\162 Want to Read", 1, true), "current shelf not marked: " .. got)
end)

check("each choice sends the right status id", function()
  online = true
  for label, id in pairs({ ["Want to Read"] = 1, ["Currently Reading"] = 2, ["Read"] = 3, ["Did Not Finish"] = 5 }) do
    local m = newManager()
    local d = detailScreen(SHELVED())
    d.detail.status_id = (id == 1) and 2 or 1 -- so the choice is a change
    press(picker(m, d), label)
    assert(#update_calls == 1 and update_calls[1].status_id == id,
      label .. " sent " .. tostring(update_calls[1] and update_calls[1].status_id))
    assert(update_calls[1].book_id == 100)
  end
end)

check("the details are updated from the answer, with the library record's id", function()
  online = true
  local m = newManager()
  local d = detailScreen(NEW())
  press(picker(m, d), "Read")
  assert(#d.status_updates == 0, "updated before the server answered")
  update_cb({ id = 77, status_id = 3 })
  assert(#d.status_updates == 1 and d.status_updates[1][1] == 3 and d.status_updates[1][2] == 77,
    "setStatus got " .. tostring(d.status_updates[1] and d.status_updates[1][1]))
end)

check("the edition is sent for a new book only", function()
  online = true
  local m = newManager()
  press(picker(m, detailScreen(NEW())), "Read")
  assert(update_calls[1].edition_id == 10001, "a new book lost its edition")
  m = newManager()
  local d = detailScreen(SHELVED()); d.detail.book.edition_id = 10001
  press(picker(m, d), "Read")
  assert(update_calls[1].edition_id == nil, "switched the edition of a shelved book")
end)

check("the old and new shelves, the counts and the reading list are dropped", function()
  online = true
  local m = newManager()
  m.shelf_cache:putReading(1, { row(9, 2) })
  local d = detailScreen(SHELVED())      -- on Want to Read (1)
  press(picker(m, d), "Read")             -- to Read (3)
  update_cb({ id = 55, status_id = 3 })
  assert(m.shelf_cache:get(1, 1) == nil, "old shelf kept stale")
  assert(m.shelf_cache:get(1, 3) == nil, "new shelf kept stale")
  assert(m.shelf_cache:get(1, 2) ~= nil, "an unrelated shelf was dropped")
  assert(m.shelf_cache:counts(1, { 1, 3 })[1] == nil, "counts kept stale")
  assert(m.shelf_cache:reading(1) == nil, "reading list kept stale")
end)

check("a closed details screen is not touched, but the cache is still corrected", function()
  online = true
  local m = newManager()
  local d = detailScreen(SHELVED())
  press(picker(m, d), "Read")
  UIM:close(d)
  update_cb({ id = 55, status_id = 3 })
  assert(#d.status_updates == 0, "updated a closed screen")
  assert(m.shelf_cache:get(1, 3) == nil, "the cache was left stale")
end)

check("choosing the current shelf again sends nothing", function()
  online = true
  local m = newManager()
  press(picker(m, detailScreen(SHELVED())), "Want to Read")
  assert(#update_calls == 0, "sent a request for no change")
end)

check("a failed save offers a readable retry, leaves the screen and the cache alone", function()
  online = true
  local m = newManager()
  local d = detailScreen(NEW())
  press(picker(m, d), "Read")
  update_cb(nil, "Book not found")
  assert(#retries == 1 and retries[1].err == "Book not found", "no retry")
  assert(#d.status_updates == 0, "changed the screen anyway")
  assert(m.shelf_cache:get(1, 3) ~= nil, "dropped the cache for a change that did not happen")
  retries[1].again()
  assert(#update_calls == 2, "retry did not ask again")
end)

check("offline: says so, shows no picker and sends nothing", function()
  online = false
  local m = newManager()
  local p = picker(m, detailScreen(NEW()))
  online = true
  assert(p == nil, "a picker was shown offline")
  assert(#infos == 1 and infos[1]:lower():find("offline"), "no offline message")
  assert(#update_calls == 0 and #remove_calls == 0)
end)

print("\n== removing ==")

check("Remove asks first and sends nothing until confirmed", function()
  online = true
  local m = newManager()
  local d = detailScreen(SHELVED())
  press(picker(m, d), "Remove from library")
  assert(#remove_calls == 0, "removed without asking")
  assert(#confirms == 1 and confirms[1].text:find("Obelisk", 1, true), "no confirmation naming the book")
  confirms[1].ok_callback()
  assert(#remove_calls == 1 and remove_calls[1] == 55, "removed the wrong record")
end)

check("a confirmed removal clears the status, drops the shelf cache", function()
  online = true
  local m = newManager()
  local d = detailScreen(SHELVED())
  press(picker(m, d), "Remove from library")
  confirms[1].ok_callback()
  remove_cb({ id = 55 })
  assert(#d.status_updates == 1 and d.status_updates[1][1] == nil, "status line kept")
  assert(m.shelf_cache:get(1, 1) == nil, "the shelf it left was kept stale")
  assert(m.shelf_cache:counts(1, { 1 })[1] == nil)
end)

check("a failed removal offers a retry and changes nothing", function()
  online = true
  local m = newManager()
  local d = detailScreen(SHELVED())
  press(picker(m, d), "Remove from library")
  confirms[1].ok_callback()
  remove_cb(nil, { completed = false })
  assert(#retries == 1 and #d.status_updates == 0 and m.shelf_cache:get(1, 1) ~= nil)
end)

r.finish()
