-- Everything waiting to be sent, one line each, and how to cancel each line.
--
-- The offline queues keep progress (a page, a status per book), goal changes and ratings
-- apart; this reads all three into one list for a screen to show. Plain data plus the
-- queues' own cancel calls, no KOReader requires beyond gettext, so it runs under stock
-- Lua in the spec suite.
--
-- A row is { kind, title, text, note (nil or a few words on why it is stuck), cancel }:
-- `cancel()` removes just that change and returns true.

local _ = require("gettext")
local T = require("ffi/util").template

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SyncConflicts = require("hardcover/lib/sync_conflicts")

local PendingChanges = {}

local function statusText(status_id)
  if status_id == HARDCOVER.STATUS.TO_READ then return _("Want to Read") end
  if status_id == HARDCOVER.STATUS.READING then return _("Currently Reading") end
  if status_id == HARDCOVER.STATUS.FINISHED then return _("Read") end
  if status_id == HARDCOVER.STATUS.DNF then return _("Did Not Finish") end
  return _("a new status")
end

-- why a change that is waiting is not simply on its way
local function stuck(entry)
  if type(entry) ~= "table" then return nil end
  if entry.conflict then return _("waiting for your answer") end
  if (entry.failures or 0) >= 3 then return _("Hardcover refused it") end
  return nil
end

function PendingChanges.list(queues)
  queues = queues or {}
  local rows = {}

  local sync = queues.sync_queue
  if sync then
    for _i, filepath in ipairs(sync:filepaths()) do
      local entry = sync:get(filepath)
      local title = SyncConflicts.title(filepath, entry)
      local note = stuck(entry)
      if entry.status_id ~= nil then
        rows[#rows + 1] = {
          kind = "status", title = title, note = note,
          text = T(_("%1: mark as %2"), title, statusText(entry.status_id)),
          cancel = function() return sync:cancelStatus(filepath) end,
        }
      end
      if entry.mapped_page ~= nil then
        rows[#rows + 1] = {
          kind = "page", title = title, note = note,
          text = T(_("%1: page %2"), title, entry.mapped_page),
          cancel = function() return sync:cancelPage(filepath) end,
        }
      end
    end
  end

  local ratings = queues.rating_queue
  if ratings then
    for _i, r in ipairs(ratings:list()) do
      local title = (type(r.title) == "string" and r.title ~= "") and r.title or T(_("Book %1"), r.user_book_id)
      rows[#rows + 1] = {
        kind = "rating", title = title,
        text = (r.rating or 0) > 0 and T(_("%1: rating %2"), title, tostring(r.rating))
          or T(_("%1: clear the rating"), title),
        cancel = function() return ratings:cancel(r.user_book_id) end,
      }
    end
  end

  local goals = queues.goal_queue
  if goals then
    for _i, op in ipairs(goals:ops()) do
      if type(op) == "table" and op.key ~= nil and (op.kind == "save" or op.kind == "archive") then
        local name = op.form and op.form.name
        if type(name) ~= "string" or name == "" then name = _("a goal") end
        local text
        if op.kind == "archive" then
          text = T(_("Archive the goal \"%1\""), name)
        elseif type(op.key) == "string" and op.key:find("^local:") then
          text = T(_("New goal \"%1\""), name)
        else
          text = T(_("Change the goal \"%1\""), name)
        end
        local key = op.key
        rows[#rows + 1] = {
          kind = "goal", title = name, text = text,
          note = op.held and (op.reason == "scope" and _("sign in again to send it") or _("Hardcover refused it")) or nil,
          cancel = function() return goals:cancel(key) end,
        }
      end
    end
  end

  return rows
end

-- the line a screen shows: the change, and why it is stuck when it is
function PendingChanges.line(row)
  if row.note then return T(_("%1 (%2)"), row.text, row.note) end
  return row.text
end

return PendingChanges
