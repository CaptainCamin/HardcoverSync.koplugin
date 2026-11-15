--[[--
Pending changes with the persistent "Needs your decision" group first: a page
question, a removal question (with what a removal would take), and ordinary
waiting work below. Tapping a question opens one answer sheet; "Decide later"
leaves it and opens nothing else.

Screens: pending_decisions, pending_decision_later, pending_decision_remove.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SyncQueue = require("hardcover/lib/sync_queue")
local RatingQueue = require("hardcover/lib/rating_queue")

local function settings()
  local store = {}
  return { readSetting = function(_, k) return store[k] end, saveSetting = function(_, k, v) store[k] = v end,
    flush = function() end }
end

return {
  name = "pending_decisions",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local q = { sync_queue = SyncQueue:new { settings = settings() },
      rating_queue = RatingQueue:new { settings = settings() } }

    q.sync_queue:enqueuePage("/b/dune.epub", { mapped_page = 100, book_id = 7, title = "Dune" })
    q.sync_queue:get("/b/dune.epub").conflict = { kind = "page", local_page = 100, cloud_page = 240, seq = 1 }
    q.sync_queue:queueRemove(1, 8, 80, "Kindred", HARDCOVER.STATUS.READING, {
      status_known = true, status_id = HARDCOVER.STATUS.READING,
      rating_known = true, rating = 4, reads_known = true, reads = "1:40:3::", review_known = false,
    })
    q.sync_queue:get(8).conflict = { kind = "remove", changes = { "a rating", "reading progress" }, online = { id = 80 } }
    q.sync_queue:enqueuePage("/b/emma.epub", { mapped_page = 12, book_id = 9, title = "Emma" })
    q.rating_queue:queue(907, 4.5, "Solaris", 101, 1)

    local resolved
    local Dialog = require("hardcover/lib/ui/pending_changes_dialog")
    Dialog.show {
      queues = q,
      on_resolved = function(decision) resolved = decision end,
    }
    emu:pump()
    emu:expectText("NEEDS YOUR DECISION")
    emu:expectText("Dune: page 100 here, page 240 on Hardcover")
    emu:expectText("Kindred: remove anyway?")
    emu:expectText("Emma: page 12")
    emu:expectText("Solaris: rating 4.5")
    emu:shot("pending_decisions")

    local function tap(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
      emu:pump()
    end

    -- Decide later: the picker closes; the question stays and no other one opens.
    tap("Dune: page 100 here, page 240 on Hardcover")
    emu:expectText("Use Hardcover (page 240)")
    tap("Decide later")
    assert(q.sync_queue:conflictCount() == 2, "a question was dropped")
    assert(resolved == nil, "later called on_resolved")
    assert(UIManager:getTopmostVisibleWidget(), "the list was closed")
    emu:shot("pending_decision_later")

    -- Keep the book: the removal question is answered and the list closes for the send.
    tap("Kindred: remove anyway?")
    emu:expectText("Keep the book")
    emu:shot("pending_decision_remove")
    tap("Keep the book")
    assert(resolved ~= nil, "the answer was not reported")
    assert(q.sync_queue:get(8) == nil, "the removal was not cancelled")
    assert(q.sync_queue:conflictCount() == 1, "the other question was answered too")
    emu:closeAll()
  end,
}
