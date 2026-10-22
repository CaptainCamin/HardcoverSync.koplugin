-- The changes waiting to be sent, one row each. Tapping a row offers to cancel that one
-- change (Hardcover keeps what it has); "Send them now" sends the rest, and "Discard" throws
-- away the queued progress and status changes without sending them.
--
-- opts: queues ({ sync_queue, goal_queue, rating_queue, shelf_queue, list_queue, journal_queue, review_queue }),
-- on_cancel(row) after a change was cancelled (so the screens that showed it can show
-- Hardcover's version again), on_send() after the list is closed, on_discard() after the
-- queued changes were discarded.

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local PendingChanges = require("hardcover/lib/pending_changes")
local SettingsDialog = require("hardcover/lib/ui/settings_dialog")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local PendingChangesDialog = {}

function PendingChangesDialog.show(opts)
  local screen

  local function open()
    local rows = PendingChanges.list(opts.queues)
    if #rows == 0 then
      StatusDialogs.info(_("Nothing is waiting to be sent."))
      return
    end

    local items = {}
    for _i, row in ipairs(rows) do
      items[#items + 1] = {
        text = PendingChanges.line(row),
        callback = function()
          StatusDialogs.confirm {
            title = _("Cancel this change?"),
            text = T(_("%1\n\nHardcover keeps what it has now."), row.text),
            ok_text = _("Cancel the change"),
            cancel_text = _("Keep it"),
            ok_callback = function()
              row.cancel()
              if opts.on_cancel then opts.on_cancel(row) end
              if screen then UIManager:close(screen) end
              open() -- the list again, without it
            end,
          }
        end,
      }
    end
    if opts.on_send then
      -- the list closes first: what it shows is about to be sent, so it is no longer waiting
      items[#items + 1] = {
        text = _("Send them now"),
        callback = function()
          if screen then UIManager:close(screen) end
          opts.on_send()
        end,
      }
    end
    -- Discard was a long press on Sync; it is a row here, and asks first like Cancel does.
    -- It throws away only the progress and status changes, as it always has.
    local sync_queue = opts.queues.sync_queue
    local queued = sync_queue and sync_queue:pendingCount() or 0
    if queued > 0 then
      items[#items + 1] = {
        text = T(_("Discard %1 queued changes"), queued),
        callback = function()
          StatusDialogs.confirm {
            title = T(_("Discard %1 queued changes?"), queued),
            text = _("They are deleted from this device and never sent to Hardcover."),
            ok_text = _("Discard"),
            cancel_text = _("Keep them"),
            ok_callback = function()
              sync_queue:clearAll()
              if opts.on_discard then opts.on_discard() end
              if screen then UIManager:close(screen) end
              open() -- what is left, if anything
            end,
          }
        end,
      }
    end
    screen = SettingsDialog.show { title = _("Pending changes"), items = items }
  end

  open()
end

return PendingChangesDialog
