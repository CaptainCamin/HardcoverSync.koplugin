--[[--
The changes waiting to be sent, each on its own row: a page, a status, a rating and a goal.
Tapping a row asks to cancel just that change; cancelling it leaves the others, and the
screen comes back without it. "Send them now" sends the rest.

Screens: pending_changes, pending_changes_confirm.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top() return UIManager:getTopmostVisibleWidget() end

return {
  name = "pending_changes",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
    local SyncQueue = require("hardcover/lib/sync_queue")
    local GoalQueue = require("hardcover/lib/goal_queue")
    local RatingQueue = require("hardcover/lib/rating_queue")
    local function settings()
      local store = {}
      return { readSetting = function(_, k) return store[k] end, saveSetting = function(_, k, v) store[k] = v end, flush = function() end }
    end
    local q = { sync_queue = SyncQueue:new { settings = settings() }, goal_queue = GoalQueue:new { settings = settings() },
      rating_queue = RatingQueue:new { settings = settings() } }
    q.sync_queue:enqueuePage("/b/dune.epub", { mapped_page = 120, book_id = 7, title = "Dune" })
    q.sync_queue:enqueueStatus("/b/kindred.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 8, title = "Kindred" })
    q.rating_queue:queue(55, 4.5, "Solaris")
    q.goal_queue:queueSave({ name = "Read more", metric = "book", target = 20, start_date = "2027-01-01", end_date = "2027-12-31" }, nil)

    local cancelled, sent = {}, 0
    local Dialog = require("hardcover/lib/ui/pending_changes_dialog")
    Dialog.show {
      queues = q,
      on_cancel = function(row) cancelled[#cancelled + 1] = row.kind end,
      on_send = function() sent = sent + 1 end,
    }
    emu:pump()
    for _, expected in ipairs({ "Pending changes", "Dune: page 120", "Kindred: mark as Read", "Solaris: rating 4.5",
      "New goal \"Read more\"", "Send them now" }) do
      emu:expectText(expected)
    end
    emu:shot("pending_changes")

    -- tap a row: asked first, and "Keep it" changes nothing
    local function tap(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
      emu:pump()
    end
    tap("Solaris: rating 4.5")
    emu:expectText("Cancel this change?")
    emu:shot("pending_changes_confirm")
    tap("Keep it")
    assert(q.rating_queue:get(55) == 4.5 and #cancelled == 0, "Keep it cancelled the change")

    -- cancel the rating: it goes, the others stay, the list comes back without it
    tap("Solaris: rating 4.5")
    tap("Cancel the change")
    assert(q.rating_queue:get(55) == nil, "the rating is still queued")
    assert(#cancelled == 1 and cancelled[1] == "rating", "on_cancel was not told")
    assert(q.sync_queue:get("/b/dune.epub").mapped_page == 120, "another change was cancelled too")
    assert(not q.goal_queue:isEmpty(), "the goal change was cancelled too")
    local screen = emu:screenText()
    assert(not screen:find("Solaris", 1, true), "the cancelled change is still listed")
    for _, expected in ipairs({ "Dune: page 120", "Kindred: mark as Read", "New goal \"Read more\"" }) do emu:expectText(expected) end

    -- the goal and the status
    tap("New goal \"Read more\"")
    tap("Cancel the change")
    assert(q.goal_queue:isEmpty())
    tap("Kindred: mark as Read")
    tap("Cancel the change")
    assert(q.sync_queue:get("/b/kindred.epub") == nil)
    assert(q.sync_queue:get("/b/dune.epub").mapped_page == 120)

    tap("Send them now")
    assert(sent == 1, "Send them now did not send")

    -- the last one: cancelling it leaves nothing, and says so
    emu:closeAll()
    Dialog.show { queues = q }
    emu:pump()
    tap("Dune: page 120")
    tap("Cancel the change")
    emu:expectText("Nothing is waiting to be sent.")
    assert(not q.sync_queue:hasPending())
    emu:closeAll()
  end,
}
