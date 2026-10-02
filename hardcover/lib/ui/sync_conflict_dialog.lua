-- Asks about each book whose offline progress disagrees with Hardcover, one
-- after another, with the plugin's Picker. Nothing is decided for the user:
-- "Decide later" (or backing out) leaves the change queued.

local UIManager = require("ui/uimanager")

local Picker = require("hardcover/lib/ui/picker")
local SyncConflicts = require("hardcover/lib/sync_conflicts")

local SyncConflictDialog = {}

--
-- opts: queue (a SyncQueue), only (a filepath: ask about that book alone),
-- on_done(resolved_count) when the questions run out.
--
function SyncConflictDialog.show(opts)
  local queue = opts.queue
  local resolved = 0
  local skipped = {}

  local function next_one()
    local pick
    for _i, c in ipairs(queue:conflicts()) do
      if not skipped[c.filepath] and (not opts.only or opts.only == c.filepath) then
        pick = c
        break
      end
    end

    if not pick then
      if opts.on_done then opts.on_done(resolved) end
      return
    end

    local d = SyncConflicts.describe(pick.filepath, pick.entry)
    local rows = {}
    local picker
    for _i, row in ipairs(d.rows) do
      rows[#rows + 1] = {
        text = row.text,
        callback = function()
          UIManager:close(picker)
          if row.id == "later" then
            skipped[pick.filepath] = true
          elseif queue:resolve(pick.filepath, row.id) then
            resolved = resolved + 1
          else
            skipped[pick.filepath] = true
          end
          next_one()
        end,
      }
    end
    picker = Picker.new {
      title = d.title,
      rows = rows,
      close_callback = function()
        -- backing out is the same as "Decide later" for this book
        skipped[pick.filepath] = true
        next_one()
      end,
    }
    UIManager:show(picker)
  end

  next_one()
end

return SyncConflictDialog
