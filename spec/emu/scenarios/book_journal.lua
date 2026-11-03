--[[--
The open book's journal, reached from the reader panel's Journal button: only this book's entries
(the request carries the book's id), a quote opening in full, and the offline message.

Screens: book_journal, book_journal_offline.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function atTime(at, fn)
  local real = os.time
  os.time = function(t) if t then return real(t) end return at end
  local ok, err = pcall(fn)
  os.time = real
  if not ok then error(err, 0) end
end

return {
  name = "book_journal",

  run = function(emu)
    local Journal = require("hardcover/lib/journal")
    local requests = {}
    local settings = fixtures.real_settings(emu)
    fixtures.install({
      settings = settings,
      overrides = {
        getJournal = function(_, opts)
          requests[#requests + 1] = opts
          return Journal.parse({
            reading_journals = { { id = 1, event = "quote", entry = "Fear is the mind-killer.", user_id = fixtures.USER_ID,
              action_at = "2026-10-20T10:00:00+00:00", metadata = { position = { type = "pages", value = 12 } },
              book = { id = 328491, title = "Dune" } } },
          }, opts.limit)
        end,
      },
    })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings }

    manager:showBookJournal(328491, "Dune", { user_book_id = 77, write = function() end })
    emu:pump()
    local screen = UIManager:getTopmostVisibleWidget()
    assert(screen and screen.name == "hardcover_journal_screen", "the journal did not open: " .. tostring(screen and screen.name))
    assert(#requests == 1 and requests[1].book_id == 328491 and requests[1].me_id == fixtures.USER_ID,
      "the journal should ask for this book's own entries only")
    emu:expectText("Journal")
    emu:expectText("Fear is the mind-killer")
    emu:expectText("p. 12")
    assert(not emu:screenText():find("Dune", 1, true), "book title is repeated in the book journal")
    emu:shot("book_journal")
    screen:onClose()
    emu:pump()

    -- A start followed by a few pages and a pause, all offline, kept across a restart.
    local SyncQueue = require("hardcover/lib/sync_queue")
    local LuaSettings = require("luasettings")
    local path = emu.DataStorage:getSettingsDir() .. "/offline_start_pause.lua"
    os.remove(path)
    local queue = SyncQueue:new { settings = LuaSettings:open(path) }
    atTime(os.time() - 180, function()
      queue:enqueueStatus("/dune.epub", { user_id = fixtures.USER_ID, book_id = 328491,
        title = "Dune", status_id = 2, from_status_id = 1 })
    end)
    atTime(os.time() - 60, function()
      queue:enqueuePage("/dune.epub", { user_id = fixtures.USER_ID, book_id = 328491, mapped_page = 7 })
    end)
    queue:enqueueStatus("/dune.epub", { user_id = fixtures.USER_ID, book_id = 328491, status_id = 4 })
    manager.sync_queue = SyncQueue:new { settings = LuaSettings:open(path) }
    local NetworkManager = require("ui/network/manager")
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local ok, err = pcall(function()
      manager:showBookJournal(328491, "Dune", { user_book_id = 77 })
      emu:pump()
      emu:shot("book_journal_start_pause")
      emu:expectText("Started reading")
      emu:expectText("Updated progress to page 7")
      emu:expectText("Marked as paused")
      emu:expectText(Journal.WAITING)
      emu:closeAll()
      manager:showJournal()
      emu:pump()
      emu:expectText("Started reading")
      emu:expectText("Updated progress to page 7")
      emu:expectText("Marked as paused")
      emu:shot("journal_tab_start_pause")
      local function tap(text)
        for i = #UIManager._window_stack, 1, -1 do
          local w = UIManager._window_stack[i].widget
          if w and (w.toast or w.snackbar) then UIManager:close(w) end
        end
        emu:pump()
        local node = emu:expectText(text)
        for _, candidate in ipairs(emu:screenNodes()) do
          if candidate.text == text then node = candidate break end
        end
        emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
        emu:pump()
      end
      tap("Marked as paused")
      emu:expectText("Cancel queued change")
      emu:shot("journal_cancel_pause")
      tap("Cancel queued change")
      emu:expectText("Cancel queued change?")
      emu:shot("journal_cancel_pause_confirm")
      tap("Keep it")
      assert(manager.sync_queue:statusOf(328491) == 4, "Keep it cancelled the pause")
      tap("Cancel queued change")
      tap("Cancel the change")
      assert(manager.sync_queue:statusOf(328491) == 2, "the cancelled pause still controls the shelf")
      assert(manager.sync_queue:get(328491).mapped_page == 7, "cancelling the pause erased progress")
      emu:closeAll()
      queue = manager.sync_queue
      manager:showBookJournal(328491, "Dune", { user_book_id = 77 })
      emu:pump()
      emu:expectText("Started reading")
      emu:expectText("Updated progress to page 7")
      assert(not emu:screenText():find("Marked as paused", 1, true), "cancelled pause remains in the journal")
      emu:shot("book_journal_pause_cancelled")
      emu:closeAll()
      queue:enqueueStatus("/dune.epub", { user_id = fixtures.USER_ID, book_id = 328491, status_id = 4 })
      queue:enqueueStatus("/dune.epub", { user_id = fixtures.USER_ID, book_id = 328491, status_id = 2 })
      queue:enqueuePage("/dune.epub", { user_id = fixtures.USER_ID, book_id = 328491, mapped_page = 43 })
      queue:enqueueStatus("/dune.epub", { user_id = fixtures.USER_ID, book_id = 328491, status_id = 3 })
      manager.sync_queue = SyncQueue:new { settings = LuaSettings:open(path) }
      manager:showBookJournal(328491, "Dune", { user_book_id = 77 })
      emu:pump()
      emu:expectText("Marked as read")
      emu:expectText("Resumed reading")
      emu:expectText("Marked as paused")
      emu:shot("book_journal_start_pause_resume_finish")
      if UIManager:getTopmostVisibleWidget().body.pages > 1 then
        emu:press("NextPage")
        emu:shot("book_journal_start_pause_resume_finish_page2")
      end
      emu:expectText("Started reading")
      emu:closeAll()
      require("hardcover/lib/ui/pending_changes_dialog").show { queues = { sync_queue = manager.sync_queue } }
      emu:pump()
      emu:expectText("4 status changes; ends at Read")
      emu:shot("pending_reading_history")
      assert(#requests == 1, "opening the offline journal must not make a request")
      emu:closeAll()

      -- A successful start followed by a failed date patch is no longer wholly unsent.
      queue = manager.sync_queue
      queue:clearAll()
      atTime(os.time() - 3 * 86400, function()
        queue:enqueueStatus("/dune.epub", { user_id = fixtures.USER_ID, book_id = 328491,
          title = "Dune", status_id = 2, from_status_id = 1 })
      end)
      local remote = { id = 77, book_id = 328491, status_id = 1, user_book_reads = {} }
      local api = {
        findUserBook = function() return remote end,
        updateUserBookStatus = function(_, _, status)
          remote.status_id = status
          remote.user_book_reads = { { id = 88, started_at = os.date("%Y-%m-%d") } }
          return remote
        end,
        updateReadDates = function() return nil, { status = 503 } end,
      }
      assert(not queue:flush(api, { user_id = fixtures.USER_ID }))
      manager.sync_queue = SyncQueue:new { settings = LuaSettings:open(path) }
      manager.show_pending = function()
        require("hardcover/lib/ui/pending_changes_dialog").show { queues = { sync_queue = manager.sync_queue } }
      end
      manager:showBookJournal(328491, "Dune", { user_book_id = 77 })
      emu:pump()
      emu:expectText("Finishing sync")
      emu:shot("book_journal_partial_start")
      tap("Started reading")
      emu:expectText("Review pending changes")
      assert(not emu:screenText():find("Cancel queued change", 1, true), "a sent start offers cancellation")
      emu:shot("journal_partial_start_review")
      tap("Review pending changes")
      tap("Discard 1 queued changes")
      emu:expectText("Anything already sent to Hardcover is kept")
      emu:shot("pending_partial_discard_confirm")
      tap("Keep them")
      assert(manager.sync_queue:hasPending(), "Keep them discarded remaining work")
      emu:closeAll()

      -- Another device finishes before retry. Do not replay a start or date a historical read.
      remote.status_id = 3
      remote.user_book_reads[1].finished_at = os.date("%Y-%m-%d")
      assert(not manager.sync_queue:flush(api, { user_id = fixtures.USER_ID }))
      assert(manager.sync_queue:heldCount() == 1, "changed reading was not held")
      manager:showBookJournal(328491, "Dune", { user_book_id = 77 })
      emu:pump()
      emu:expectText("Reading changed on Hardcover")
      emu:shot("book_journal_changed_reading")
    end)
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
    emu:closeAll()
    os.remove(path)
    if not ok then error(err, 0) end
  end,
}
