-- Asks one book's question with the plugin's Picker. Nothing is decided for the
-- reader: "Decide later", Back, the X or a tap outside leaves the change queued,
-- and closing the question never opens another one.

local UIManager = require("ui/uimanager")

local Picker = require("hardcover/lib/ui/picker")
local SyncConflicts = require("hardcover/lib/sync_conflicts")

local SyncConflictDialog = {}

-- One decision, described, or nil when its answer is no longer waiting.
local function decisionAt(opts)
  if opts.decision then return opts.decision end
  local queue = opts.queue
  if not queue or not queue.conflicts then return nil end
  for _, conflict in ipairs(queue:conflicts()) do
    local entry = conflict.entry
    local matches = (not opts.only or opts.only == conflict.filepath
        or (type(entry.files) == "table" and entry.files[opts.only]))
      and (not opts.key or opts.key == conflict.key)
    if matches then
      return {
        kind = entry.conflict.kind, key = conflict.key, filepath = conflict.filepath,
        book_id = tonumber(entry.book_id), title = entry.title, entry = entry,
        describe = function() return SyncConflicts.describe(conflict.filepath, entry) end,
        resolve = function(choice) return queue:resolve(conflict.filepath, choice) end,
      }
    end
  end
end

--
-- opts: decision (from Decisions.list), or queue plus only (a filepath) or key;
-- on_done(resolved) when the question closes, 1 when an answer was saved.
--
function SyncConflictDialog.show(opts)
  local decision = decisionAt(opts)
  if not decision then
    if opts.on_done then opts.on_done(0) end
    return
  end

  local described = decision.describe and decision.describe()
    or (decision.conflict and SyncConflicts.describeRead(decision.entry, decision.conflict))
    or SyncConflicts.describe(decision.filepath or decision.key, decision.entry)
  if not described then
    if opts.on_done then opts.on_done(0) end
    return
  end

  local picker
  local resolved = 0
  local rows = {}
  for _i, row in ipairs(described.rows) do
    rows[#rows + 1] = {
      text = row.text,
      callback = function()
        UIManager:close(picker)
        -- "Decide later" is not an answer: it keeps both the conflict and the offline data.
        local outcome
        if row.id ~= "later" then
          local saved
          saved, outcome = decision.resolve(row.id)
          if saved then resolved = 1 end
        end
        if opts.on_done then opts.on_done(resolved, row.id, outcome) end
      end,
    }
  end

  picker = Picker.new {
    title = described.title,
    rows = rows,
    close_callback = function()
      -- Back, X or a tap outside leaves the question open for later; no next question.
      if opts.on_done then opts.on_done(0) end
    end,
  }
  UIManager:show(picker)
end

return SyncConflictDialog
