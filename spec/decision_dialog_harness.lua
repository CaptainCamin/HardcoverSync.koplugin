-- The one-question conflict dialog: it asks about one book, and a "Decide later",
-- Back or the X leaves that question waiting without opening another one.
--
-- Run with:  lua spec/decision_dialog_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["ffi/util"] = function()
  return { template = function(t, ...)
    local args = { ... }
    return (tostring(t):gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
  end }
end

local shown, closed = {}, 0
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function() closed = closed + 1 end,
  }
end
package.preload["hardcover/lib/ui/picker"] = function()
  return { new = function(opts) return opts end }
end

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SyncQueue = require("hardcover/lib/sync_queue")
local SyncConflictDialog = require("hardcover/lib/ui/sync_conflict_dialog")

local function newQueue()
  local store = {}
  local q = SyncQueue:new { settings = {
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end,
    flush = function() end,
  } }
  q:enqueuePage("/books/dune.epub", { title = "Dune", mapped_page = 100, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/emma.epub", { title = "Emma", mapped_page = 12, book_id = 2, edition_id = 3 })
  q:get("/books/dune.epub").conflict = { kind = "page", local_page = 100, cloud_page = 240, seq = 1 }
  q:get("/books/emma.epub").conflict = { kind = "reread", local_page = 12,
    cloud_status = HARDCOVER.STATUS.FINISHED, seq = 1 }
  return q
end

local function rowTexts(picker)
  local out = {}
  for _, row in ipairs(picker.rows) do out[#out + 1] = row.text end
  return table.concat(out, " | ")
end

print("\n== one question, no chain ==")

check("asking about one book leaves the other book alone", function()
  shown, closed = {}, 0
  local q, done = newQueue(), nil
  SyncConflictDialog.show { queue = q, only = "/books/dune.epub", on_done = function(n) done = n end }
  assert(#shown == 1, "no question shown")
  assert(shown[1].title:find("Dune", 1, true) and shown[1].title:find("240", 1, true), shown[1].title)
  shown[1].rows[1].callback()
  assert(done == 1, "answer not reported: " .. tostring(done))
  assert(closed == 1, "picker not closed")
  assert(q:conflictCount() == 1 and q:get("/books/emma.epub").conflict, "a second question opened")
  assert(q:takeResumePage("/books/dune.epub") == 240, "the answer did not take effect")
end)

check("Decide later keeps the question and opens nothing else", function()
  shown = {}
  local q, done = newQueue(), nil
  SyncConflictDialog.show { queue = q, only = "/books/emma.epub", on_done = function(n) done = n end }
  assert(rowTexts(shown[1]):find("Decide later", 1, true), rowTexts(shown[1]))
  shown[1].rows[3].callback()
  assert(done == 0, "later counted as an answer: " .. tostring(done))
  assert(q:conflictCount() == 2, "a question was dropped")
end)

check("Back, X or a tap outside keeps the question and opens nothing else", function()
  shown = {}
  local q, done = newQueue(), nil
  SyncConflictDialog.show { queue = q, only = "/books/emma.epub", on_done = function(n) done = n end }
  shown[1].close_callback()
  assert(done == 0, "dismissal counted as an answer: " .. tostring(done))
  assert(q:conflictCount() == 2, "a question was dropped")
end)

check("a removal question can be answered through the same dialog", function()
  shown = {}
  local q = newQueue()
  q:queueRemove(1, 7, 70, "Dune", HARDCOVER.STATUS.READING, { status_known = true, status_id = 2 })
  q:get(7).conflict = { kind = "remove", changes = { "a rating" }, online = { id = 70 } }
  local decision = q:decisionForBook(7, 1)
  assert(decision, "no removal decision")
  local done
  SyncConflictDialog.show { decision = decision, on_done = function(n) done = n end }
  assert(shown[1].title:find("remove this book", 1, true), shown[1].title)
  assert(shown[1].rows[1].text == "Keep the book", shown[1].rows[1].text)
  shown[1].rows[1].callback()
  assert(done == 1, "not answered")
  assert(q:get(7) == nil, "the removal was not cancelled")
  assert(q:decisionForBook(7, 1) == nil, "a question remains")
end)

check("nothing waiting closes without a question", function()
  shown = {}
  local q = newQueue()
  q:clearAll()
  local done
  SyncConflictDialog.show { queue = q, only = "/books/dune.epub", on_done = function(n) done = n end }
  assert(#shown == 0, "asked about nothing")
  assert(done == 0, "reported an answer")
end)

r.finish()
