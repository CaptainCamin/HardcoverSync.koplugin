--[[--
The one-question sync review: a page this device and Hardcover disagree about, a
Finished book with new progress here ("are you re-reading it?"), and a removal
that would delete work added elsewhere. Each question is asked on its own;
"Decide later" leaves it queued and opens nothing else.

Screens: sync_conflict_page, sync_conflict_reread, sync_conflict_remove.
]]

local fixtures = require("fixtures")
local SyncQueue = require("hardcover/lib/sync_queue")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local function newQueue()
  local store = {}
  return SyncQueue:new { settings = {
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end,
    flush = function() end,
  } }
end

local function tapText(emu, text)
  local n = emu:expectText(text)
  emu:tap(n.x + 5, n.y + 5)
  emu:pump()
end

return {
  name = "sync_conflict",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local queue = newQueue()
    queue:enqueuePage("/books/dune.epub", { title = "Dune", mapped_page = 100, book_id = 1, edition_id = 3 })
    queue:enqueuePage("/books/emma.epub", { title = "Emma", mapped_page = 12, book_id = 2, edition_id = 3 })
    queue:get("/books/dune.epub").conflict = { kind = "page", local_page = 100, cloud_page = 240, seq = 1 }
    queue:get("/books/emma.epub").conflict = { kind = "reread", local_page = 12,
      cloud_status = HARDCOVER.STATUS.FINISHED, seq = 1 }

    local done
    require("hardcover/lib/ui/sync_conflict_dialog").show {
      queue = queue, only = "/books/dune.epub", on_done = function(n) done = n end,
    }
    emu:pump()
    emu:expectText("Dune")
    emu:expectText("page 240")
    emu:shot("sync_conflict_page")

    tapText(emu, "Use Hardcover")
    assert(done == 1, "one answer given, got " .. tostring(done))
    assert(queue:conflictCount() == 1, "the other book is still waiting, not opened by a chain")
    assert(queue:takeResumePage("/books/dune.epub") == 240, "Hardcover's page is remembered")

    done = nil
    require("hardcover/lib/ui/sync_conflict_dialog").show {
      queue = queue, only = "/books/emma.epub", on_done = function(n) done = n end,
    }
    emu:pump()
    emu:expectText("Emma")
    emu:expectText("re-reading")
    emu:shot("sync_conflict_reread")
    tapText(emu, "Decide later")
    assert(done == 0, "later is not an answer, got " .. tostring(done))
    assert(queue:conflictCount() == 1 and queue:get("/books/emma.epub").conflict, "the question was dropped")

    -- A removal that would delete a new rating and progress: keep the book first.
    queue:queueRemove(1, 9, 90, "Kindred", HARDCOVER.STATUS.READING, {
      status_known = true, status_id = HARDCOVER.STATUS.READING,
      rating_known = true, rating = 4,
      reads_known = true, reads = "1:40:3::", review_known = false,
    })
    queue:get(9).conflict = { kind = "remove", changes = { "a rating", "reading progress" }, online = { id = 90 } }
    done = nil
    require("hardcover/lib/ui/sync_conflict_dialog").show {
      decision = queue:decisionForBook(9, 1), on_done = function(n) done = n end,
    }
    emu:pump()
    emu:expectText("remove this book")
    emu:expectText("a rating and reading progress")
    emu:expectText("status, rating and reading history")
    emu:shot("sync_conflict_remove")
    tapText(emu, "Keep the book")
    assert(done == 1, "keep was not an answer")
    assert(queue:get(9) == nil, "the removal was not cancelled")
    emu:closeAll()
  end,
}
