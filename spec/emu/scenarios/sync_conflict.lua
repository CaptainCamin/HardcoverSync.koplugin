--[[--
The sync-conflict questions: a page this device and Hardcover disagree about, and a
Finished book with new progress here ("are you re-reading it?"). Answering moves the
entry on; "Decide later" leaves it queued.
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
    queue:get("/books/dune.epub").conflict = { kind = "page", local_page = 100, cloud_page = 240 }
    queue:get("/books/emma.epub").conflict = { kind = "reread", local_page = 12, cloud_status = HARDCOVER.STATUS.FINISHED }

    local done
    require("hardcover/lib/ui/sync_conflict_dialog").show { queue = queue, on_done = function(n) done = n end }
    emu:pump()
    emu:expectText("Dune")
    emu:expectText("page 240")
    emu:shot("sync_conflict_page")

    tapText(emu, "Use Hardcover")
    emu:expectText("Emma")
    emu:expectText("re-reading")
    emu:shot("sync_conflict_reread")
    tapText(emu, "Decide later")

    assert(done == 1, "one answer given, got " .. tostring(done))
    assert(queue:conflictCount() == 1, "the undecided book is still waiting")
    assert(queue:takeResumePage("/books/dune.epub") == 240, "Hardcover's page is remembered")
    emu:closeAll()
  end,
}
