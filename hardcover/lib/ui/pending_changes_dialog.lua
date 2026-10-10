-- The changes waiting to be sent, one row each. Tapping a row offers to cancel that one
-- change (Hardcover keeps what it has); "Send them now" sends the rest.
--
-- opts: queues ({ sync_queue, goal_queue, rating_queue }), on_cancel(row) after a change was
-- cancelled (so the screens that showed it can show Hardcover's version again), on_send().

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
      items[#items + 1] = { text = _("Send them now"), callback = opts.on_send }
    end
    screen = SettingsDialog.show { title = _("Pending changes"), items = items }
  end

  open()
end

return PendingChangesDialog
