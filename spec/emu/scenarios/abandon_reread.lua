--[[--
Reading history's Abandon reread flow with real KOReader widgets: a pending reread, the active
reread form, the confirmation, a decision state, and the partial-failure row in Pending changes.

Screens: abandon_history, abandon_form, abandon_confirm, abandon_pending_confirm,
abandon_checking_history, abandon_decision, abandon_decision_question, abandon_partial.
]]--

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local ReadHistoryDialog = require("hardcover/lib/ui/read_history_dialog")
local ReadEditDialog = require("hardcover/lib/ui/read_edit_dialog")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local SyncQueue = require("hardcover/lib/sync_queue")

local function top()
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    if w and not (w.toast or w.snackbar or w.name == "VirtualKeyboard") then return w end
  end
end

local function tap_widget(emu, widget, label)
  emu:screenNodes()
  assert(widget and widget.dimen and widget.dimen.w > 0, "no painted widget for " .. label)
  emu:tapExpecting(widget.dimen.x + math.floor(widget.dimen.w / 2),
    widget.dimen.y + math.floor(widget.dimen.h / 2))
  emu:pump()
end

local function tap_text(emu, text)
  local node = emu:expectText(text)
  emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
  emu:pump()
end

local function settings()
  local store = {}
  return { readSetting = function(_, key) return store[key] end,
    saveSetting = function(_, key, value) store[key] = value end,
    flush = function() end }
end

return {
  name = "abandon_reread",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })

    local book = { title = "The Dispossessed", pages = 341, edition_format = "Paperback" }
    local original = { id = 1, started_at = "2020-01-01", finished_at = "2020-01-10",
      finished_at_precision = 1, progress_pages = 341, edition_id = 11,
      edition = { id = 11, pages = 341, edition_format = "Paperback", reading_format_id = 1 } }
    local active = { id = 2, started_at = "2026-11-16", progress_pages = 12, edition_id = 11,
      edition = { id = 11, pages = 341, edition_format = "Paperback", reading_format_id = 1 } }
    local pending = { id = "pending:3", started_at = "2026-11-16", progress_pages = 0,
      pending_reread = true }

    local function open_confirmation(read, pending_read)
      StatusDialogs.confirm {
        title = "Abandon this reread?",
        text = pending_read
          and "This reread has not been sent to Hardcover yet. It will be discarded from this device. Your previous read and its dates stay."
          or "The reread and its progress will be removed. Your previous read, its dates, rating and review stay, and the book returns to its previous shelf. Journal entries from the reread may remain.",
        ok_text = "Abandon reread",
        cancel_text = "Keep reading",
        ok_callback = function() end,
      }
      emu:pump()
    end

    local history
    history = ReadHistoryDialog:new {
      book = book,
      reads = { original, active, pending },
      states = {
        [2] = { text = "Needs your decision", kind = "decision" },
        ["pending:3"] = { text = "Waiting to send", kind = "waiting" },
      },
      today = "2026-11-16",
      on_abandon = function(read) open_confirmation(read, true) end,
      on_open_read = function(read)
        local form = ReadEditDialog:new {
          book = book, read = read, today = "2026-11-16",
          on_remove = function() end,
          on_abandon = function() open_confirmation(read, false) end,
        }
        UIManager:show(form, "full")
        emu:pump()
      end,
      on_add = function() end,
    }
    UIManager:show(history, "full")
    emu:pump()

    emu:expectText("Reading history")
    emu:expectText("Started 16 Nov 2026")
    emu:expectText("Needs your decision")
    emu:expectText("Waiting to send")
    emu:expectNoButtonOverlap()
    emu:shot("abandon_history")

    local active_item, pending_item
    for _, item in ipairs(history.items) do
      if item.read.id == 2 then active_item = item end
      if item.read.pending_reread then pending_item = item end
    end
    assert(active_item and pending_item, "the history rows are missing")

    tap_widget(emu, active_item.row, "the active reread")
    local form = top()
    assert(form and form.name == "hardcover_read_edit", "the active reread opened no form")
    emu:expectText("Abandon reread")
    emu:expectText("Still reading")
    emu:expectNoButtonOverlap()
    emu:shot("abandon_form")

    tap_widget(emu, form.row_taps.abandon, "Abandon reread")
    emu:expectText("Abandon this reread?")
    emu:expectText("Journal entries from the reread may remain.")
    emu:expectNoButtonOverlap()
    emu:shot("abandon_confirm")
    tap_text(emu, "Keep reading")
    UIManager:close(form)
    emu:pump()

    tap_widget(emu, pending_item.row, "the pending reread")
    emu:expectText("This reread has not been sent to Hardcover yet.")
    emu:expectNoButtonOverlap()
    emu:shot("abandon_pending_confirm")
    tap_text(emu, "Keep reading")
    UIManager:close(history)
    emu:pump()

    local decision = ReadHistoryDialog:new {
      book = book, reads = { original, active }, today = "2026-11-16",
      states = { [2] = { text = "Checking what synced", kind = "checking" } },
      on_open_read = function() end, on_add = function() end,
    }
    UIManager:show(decision, "full")
    emu:pump()
    emu:expectText("Checking what synced")
    emu:shot("abandon_checking_history")
    UIManager:close(decision)
    emu:pump()

    local PendingChangesDialog = require("hardcover/lib/ui/pending_changes_dialog")
    local q_decision = SyncQueue:new { settings = settings() }
    q_decision:startReread("/b/dune.epub", { book_id = 7, user_book_id = 507, title = "Dune",
      from_status_id = 3, mapped_page = 12 })
    local _, decision_action = q_decision:abandonReread("/b/dune.epub", {
      book_id = 7, read_id = 11, base = active, previous_read = original, restore_status_id = 3,
    })
    decision_action.conflict = { kind = "abandon_changed", reason = "previous_changed",
      target = active, previous = original }
    PendingChangesDialog.show { queues = { sync_queue = q_decision, user_id = 1 } }
    emu:pump()
    emu:expectText("Dune: abandon reread changed on Hardcover")
    emu:shot("abandon_decision")
    tap_text(emu, "Dune: abandon reread changed on Hardcover")
    emu:expectText("The reread could not be abandoned safely")
    emu:expectText("Abandon the reread anyway")
    emu:shot("abandon_decision_question")
    tap_text(emu, "Decide later")
    emu:closeAll()

    local q = SyncQueue:new { settings = settings() }
    q:startReread("/b/dune.epub", { book_id = 7, user_book_id = 507, title = "Dune",
      from_status_id = 3, mapped_page = 12 })
    local _, action = q:abandonReread("/b/dune.epub", {
      book_id = 7, read_id = 11, base = active, previous_read = original, restore_status_id = 3,
    })
    action.checking = true
    PendingChangesDialog.show { queues = { sync_queue = q, user_id = 1 } }
    emu:pump()
    emu:expectText("Abandoning reread")
    emu:expectText("Checking what synced")
    emu:shot("abandon_partial")
    emu:closeAll()
  end,
}