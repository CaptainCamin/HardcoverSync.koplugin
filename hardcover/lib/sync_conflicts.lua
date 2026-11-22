-- The words for the "your progress differs from Hardcover" questions, kept
-- apart from the dialog so they can be tested without a screen.
--
-- The questions that come out of the offline queue (see SyncQueue):
--   page    this device read to one page, Hardcover already holds a page well
--           past it (read on another device)
--   reread  Hardcover has the book as Read / Did Not Finish, but this device has
--           new progress: is the book being read again?
--   remove  this device asked to take the book out of the library, but
--           Hardcover's record gained work since then (or cannot be checked):
--           keep it, or remove it anyway?

local _ = require("gettext")
local T = require("ffi/util").template

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local ReadHistory = require("hardcover/lib/read_history")

local SyncConflicts = {}

-- The book's name for a dialog: its title, else the file's name.
function SyncConflicts.title(filepath, entry)
  if type(entry) == "table" and type(entry.title) == "string" and entry.title ~= "" then
    return entry.title
  end
  local name = tostring(filepath or ""):match("([^/]+)$") or tostring(filepath or "")
  return (name:gsub("%.[%w]+$", ""))
end

function SyncConflicts.statusName(status_id)
  if status_id == HARDCOVER.STATUS.FINISHED then
    return _("Read")
  elseif status_id == HARDCOVER.STATUS.PAUSED then
    return _("Paused")
  elseif status_id == HARDCOVER.STATUS.DNF then
    return _("Did not finish")
  end
  return _("not being read")
end

-- "a rating", "a rating and reading progress", ...
function SyncConflicts.changesText(changes)
  if type(changes) ~= "table" or #changes == 0 then return nil end
  if #changes == 1 then return changes[1] end
  return table.concat(changes, ", ", 1, #changes - 1) .. " and " .. changes[#changes]
end

-- A rating as words for a comparison: "4.5 stars", "1 star" or "No rating".
function SyncConflicts.ratingText(rating)
  rating = tonumber(rating) or 0
  if rating <= 0 then return _("No rating") end
  return rating == 1 and _("1 star") or T(_("%1 stars"), tostring(rating))
end

-- A review's text for a comparison, or the words for no review.
function SyncConflicts.reviewText(value)
  local text = type(value) == "table" and value.text or ""
  if type(text) ~= "string" or text == "" then return _("No review") end
  return text
end

-- The one-line description of a decision in the review list.
function SyncConflicts.decisionText(title, decision)
  local conflict = decision and (decision.conflict or (decision.entry and decision.entry.conflict))
  if not conflict then return T(_("%1: needs your decision"), title) end
  if conflict.kind == "rating" then
    return T(_("%1: rating changed on Hardcover"), title)
  elseif conflict.kind == "review" then
    return conflict.delete and T(_("%1: remove your review?"), title)
      or T(_("%1: review changed on Hardcover"), title)
  elseif conflict.kind == "remove" then
    return T(_("%1: remove anyway?"), title)
  elseif conflict.kind == "abandon_remove" then
    return T(_("%1: abandon reread or remove the book?"), title)
  elseif conflict.kind == "abandon_changed" then
    return T(_("%1: abandon reread changed on Hardcover"), title)
  elseif conflict.kind == "abandon_shelf" then
    return T(_("%1: shelf changed on Hardcover"), title)
  elseif conflict.kind == "reread" then
    return T(_("%1: read again?"), title)
  elseif conflict.kind == "read_changed" then
    local first = conflict.fields and conflict.fields[1]
    return first and T(_("%1: %2 changed on Hardcover"), title, SyncConflicts.fieldName(first.field, true))
      or T(_("%1: read changed on Hardcover"), title)
  elseif conflict.kind == "read_gone" then
    return T(_("%1: this read is no longer on Hardcover"), title)
  elseif conflict.kind == "read_reading" then
    return T(_("%1: change an older read?"), title)
  end
  if conflict.edition_mismatch then
    return T(_("%1: page is in a different edition"), title)
  end
  return T(_("%1: page %2 here, page %3 on Hardcover"), title, conflict.local_page, conflict.cloud_page)
end

-- Why a removal is being asked about, under its line. The full detail is in the question.
function SyncConflicts.decisionNote(decision)
  local conflict = decision and (decision.conflict or (decision.entry and decision.entry.conflict))
  if not conflict then return nil end
  if conflict.kind == "rating" then return _("Both ratings are kept until you answer.") end
  if conflict.kind == "review" then return _("Both versions are kept until you answer.") end
  if conflict.kind == "remove" then return _("Changed on Hardcover since you asked.") end
  if conflict.kind == "abandon_remove" then return _("Removing the book would also delete the earlier read.") end
  if conflict.kind == "abandon_changed" then return _("The reread or the earlier read changed on Hardcover.") end
  if conflict.kind == "abandon_shelf" then return _("The book's shelf changed while abandoning the reread.") end
  if conflict.kind == "reread" then
    return T(_("Hardcover has it as %1."), SyncConflicts.statusName(conflict.cloud_status))
  elseif conflict.kind == "read_changed" then
    return _("The read changed on another device since you started.")
  elseif conflict.kind == "read_gone" then
    return _("It was removed on another device.")
  elseif conflict.kind == "read_reading" then
    return _("The book is still being read on Hardcover.")
  elseif conflict.edition_mismatch then
    return _("The read's edition changed on Hardcover; this device's page is in another edition.")
  end
end

local FIELD_NAMES = {
  started_at = _("start date"), finished_at = _("finish date"),
  finished_at_precision = _("finish precision"), edition_id = _("edition"),
  progress_pages = _("page"),
}

-- "start date" (lowercase for a sentence) or "Start date" for a label.
function SyncConflicts.fieldName(field, lower)
  local name = FIELD_NAMES[field] or tostring(field)
  if lower then return name:sub(1, 1):lower() .. name:sub(2) end
  return name
end

local function precisionName(value)
  value = tonumber(value) or 1
  if value == 2 then return _("month") end
  if value == 3 then return _("year") end
  return _("day")
end

local function fieldValue(field, value, read)
  if value == nil then return _("not set") end
  if field == "started_at" or field == "finished_at" then
    local precision = field == "finished_at" and read and read.finished_at_precision or 1
    local text = ReadHistory.dateText(value, precision)
    return text ~= "" and text or tostring(value)
  elseif field == "finished_at_precision" then
    return precisionName(value)
  elseif field == "edition_id" then
    return T(_("edition %1"), tostring(value))
  end
  return tostring(value)
end

-- The choices for an abandon that could not finish. A deleted action has no reread left to keep;
-- it still needs a way to finish or leave the shelf alone, so it never becomes a dead end.
local function abandonRows(conflict)
  local reason = conflict.reason
  if conflict.deleted then
    local rows = {}
    if (reason == "target_gone" or reason == "previous_changed") and conflict.previous then
      rows[#rows + 1] = { id = "restore", text = _("Restore the previous shelf") }
    elseif reason == "target_reappeared" or reason == "target_changed"
        or reason == "target_not_active" then
      rows[#rows + 1] = { id = "check", text = _("Check again") }
    end
    rows[#rows + 1] = { id = "leave", text = _("Leave the shelf as it is") }
    rows[#rows + 1] = { id = "later", text = _("Decide later") }
    return rows
  end
  if reason == "target_gone" then
    return {
      { id = "restore", text = _("Restore the previous shelf") },
      { id = "later", text = _("Decide later") },
    }
  end
  local rows = {
    { id = "keep", text = _("Keep the reread") },
    { id = "later", text = _("Decide later") },
  }
  if conflict.target and conflict.previous and reason ~= "another_read"
      and reason ~= "target_finished" and reason ~= "target_not_active" then
    table.insert(rows, 2, { id = "abandon", text = _("Abandon the reread anyway") })
  end
  return rows
end

-- One read edit's question: a field changed on Hardcover, the read is gone, or an older read is
-- being changed while a newer one is in progress.
function SyncConflicts.describeRead(entry, conflict)
  local name = SyncConflicts.title(type(entry) == "table" and entry.file, entry)
  if conflict.kind == "abandon_changed" then
    return {
      title = T(_("%1\n\nThe reread could not be abandoned safely because it changed on Hardcover.\n\nWhat should happen?"), name),
      rows = abandonRows(conflict),
    }
  end
  if conflict.kind == "abandon_shelf" then
    local rows = { { id = "restore", text = _("Restore the previous shelf") } }
    if conflict.deleted then
      rows[#rows + 1] = { id = "leave", text = _("Leave the shelf as it is") }
    else
      rows[#rows + 1] = { id = "keep", text = _("Keep the reread") }
    end
    rows[#rows + 1] = { id = "later", text = _("Decide later") }
    return {
      title = T(_("%1\n\nThe book's shelf changed on Hardcover while abandoning the reread. Restore the previous shelf without changing any read dates?"), name),
      rows = rows,
    }
  end
  if conflict.kind == "read_gone" then
    local read = conflict.read or conflict.base
    local range = read and ReadHistory.rangeText(read) or _("this read")
    return {
      title = T(_("%1\n\nThis read (%2) is no longer on Hardcover.\n\nAdd it again, or discard this change?"),
        name, range),
      rows = {
        { id = "add_again", text = _("Add it again") },
        { id = "discard", text = _("Discard this change") },
        { id = "later", text = _("Decide later") },
      },
    }
  end
  if conflict.kind == "read_reading" then
    local current = conflict.current and ReadHistory.rangeText(conflict.current) or _("a newer read")
    return {
      title = T(_("%1\n\nYou changed an older read while %2 is still in progress on Hardcover. Changing it can move the book's shelf.\n\nWhat should happen?"),
        name, current),
      rows = {
        { id = "send_anyway", text = _("Send it anyway") },
        { id = "wait", text = _("Wait until the newer read finishes") },
        { id = "discard", text = _("Discard this change") },
        { id = "later", text = _("Decide later") },
      },
    }
  end

  local lines = {}
  for _i, field in ipairs(conflict.fields or {}) do
    lines[#lines + 1] = T(_("%1: Hardcover has %2; you started from %3."),
      SyncConflicts.fieldName(field.field), fieldValue(field.field, field.online, conflict.read),
      fieldValue(field.field, field.base, conflict.read))
  end
  return {
    title = T(_("%1\n\nThis read changed on Hardcover since you started:\n\n%2\n\nWhich should be kept?"),
      name, table.concat(lines, "\n")),
    rows = {
      { id = "keep_hardcover", text = _("Use Hardcover's") },
      { id = "use_device", text = _("Use this device's") },
      { id = "later", text = _("Decide later") },
    },
  }
end

-- { title, rows = { { id, text }... } } for one conflict. The ids are what
-- SyncQueue:resolve takes, plus "later".
function SyncConflicts.describe(filepath, entry)
  local conflict = type(entry) == "table" and entry.conflict
  if not conflict then
    return nil
  end
  local name = SyncConflicts.title(filepath, entry)

  if conflict.kind == "rating" then
    return {
      title = T(_("%1\n\nYour rating changed on Hardcover since this device last checked.\n\nHardcover: %2\nThis device: %3\n\nWhich should be kept?"),
        name, SyncConflicts.ratingText(conflict.online), SyncConflicts.ratingText(conflict.proposed)),
      rows = {
        { id = "keep_hardcover", text = _("Keep Hardcover's") },
        { id = "use_device", text = _("Use this device's") },
        { id = "later", text = _("Decide later") },
      },
    }
  end

  if conflict.kind == "review" then
    local lines = {
      T(_("Hardcover:\n%1"), SyncConflicts.reviewText(conflict.online)),
      T(_("This device:\n%1"), SyncConflicts.reviewText(conflict.proposed)),
    }
    if conflict.online.spoilers ~= conflict.proposed.spoilers then
      lines[#lines + 1] = T(_("Hardcover spoilers: %1\nThis device spoilers: %2"),
        conflict.online.spoilers and _("yes") or _("no"),
        conflict.proposed.spoilers and _("yes") or _("no"))
    end
    local rows = {
      { id = "keep_hardcover", text = _("Keep Hardcover's") },
      { id = "use_device", text = conflict.delete and _("Remove my review anyway") or _("Use this device's") },
    }
    if not conflict.delete then
      rows[#rows + 1] = { id = "combine", text = _("Combine in the editor") }
    end
    rows[#rows + 1] = { id = "later", text = _("Decide later") }
    return {
      title = T(_("%1\n\nYour review changed on Hardcover since this device last checked.\n\n%2\n\nWhich should be kept?"),
        name, table.concat(lines, "\n\n")),
      rows = rows,
    }
  end

  if conflict.kind == "abandon_remove" then
    return {
      title = T(_("%1\n\nYou asked to remove this book from your library while an abandon reread is waiting. Removing the book would also delete the earlier read and its dates.\n\nWhat should happen?"), name),
      rows = {
        { id = "abandon", text = _("Keep the book and abandon the reread") },
        { id = "remove", text = _("Remove the whole book") },
        { id = "later", text = _("Decide later") },
      },
    }
  end

  if conflict.kind == "abandon_changed" then
    return {
      title = T(_("%1\n\nThe reread could not be abandoned safely because it changed on Hardcover.\n\nWhat should happen?"), name),
      rows = abandonRows(conflict),
    }
  end

  if conflict.kind == "abandon_shelf" then
    local rows = { { id = "restore", text = _("Restore the previous shelf") } }
    if conflict.deleted then
      rows[#rows + 1] = { id = "leave", text = _("Leave the shelf as it is") }
    else
      rows[#rows + 1] = { id = "keep", text = _("Keep the reread") }
    end
    rows[#rows + 1] = { id = "later", text = _("Decide later") }
    return {
      title = T(_("%1\n\nThe book's shelf changed on Hardcover while abandoning the reread. Restore the previous shelf without changing any read dates?"), name),
      rows = rows,
    }
  end

  if conflict.kind == "remove" then
    local why
    if conflict.replaced then
      why = _("Hardcover now has a different library entry for this book.")
    else
      local changes = SyncConflicts.changesText(conflict.changes)
      why = changes and T(_("Hardcover has %1 that this device did not have when you asked to remove it."), changes)
        or _("This device could not check what changed on Hardcover.")
    end
    return {
      title = T(_("%1\n\nYou asked to remove this book from your library while offline. %2\n\nRemoving it deletes its status, rating and review. Its journal entries stay on Hardcover: notes, quotes, reading history and the review record, which may keep the review text. Public entries stay public.\n\nWhat should happen?"),
        name, why),
      rows = {
        { id = "keep", text = _("Keep the book") },
        { id = "remove", text = _("Remove the book anyway") },
        { id = "later", text = _("Decide later") },
      },
    }
  end

  if conflict.kind == "reread" then
    return {
      title = T(_("%1\n\nHardcover has this as \"%2\", but you have read on to page %3 here.\n\nAre you re-reading it?"),
        name, SyncConflicts.statusName(conflict.cloud_status), conflict.local_page),
      rows = {
        { id = "yes", text = _("Yes, I'm re-reading it") },
        { id = "no", text = _("No, ignore this progress") },
        { id = "later", text = _("Decide later") },
      },
    }
  end

  if conflict.edition_mismatch then
    return {
      title = T(_("%1\n\nThis device's page is in edition %2, but Hardcover's read is in edition %3. The page numbers are not interchangeable.\n\nWhat should happen?"),
        name, tostring(conflict.local_edition_id or "?"), tostring(conflict.cloud_edition_id or "?")),
      rows = {
        { id = "cloud", text = _("Use Hardcover's progress") },
        { id = "later", text = _("Decide later") },
      },
    }
  end

  return {
    title = T(_("%1\n\nThis device is at page %2, but Hardcover is at page %3.\n\nWhich should be kept?"),
      name, conflict.local_page, conflict.cloud_page),
    rows = {
      { id = "cloud", text = T(_("Use Hardcover (page %1)"), conflict.cloud_page) },
      { id = "local", text = T(_("Use this device (page %1)"), conflict.local_page) },
      { id = "later", text = _("Decide later") },
    },
  }
end

-- The menu row's words.
function SyncConflicts.menuText(count)
  return T(_("Needs your decision (%1)"), count)
end

-- Questions are counted one per change, not one per book: two questions about one
-- title are still two changes waiting for an answer.
function SyncConflicts.decisionCountText(count)
  if count == 1 then return _("1 change needs your decision") end
  return T(_("%1 changes need your decision"), count)
end

-- What to say after a sync that left questions unanswered.
function SyncConflicts.notice(count)
  if count == 1 then
    return _("1 change needs your decision. Open Sync to review it.")
  end
  return T(_("%1 changes need your decision. Open Sync to review them."), count)
end

-- What a sync pass should say: what was sent, what still needs the reader, what
-- is waiting, and whether anything failed. `result` is from flushSyncQueue.
function SyncConflicts.outcomeText(result)
  result = type(result) == "table" and result or { failed = not result }
  local decisions = tonumber(result.decisions) or 0
  local waiting = tonumber(result.waiting) or 0
  local failed = result.failed == true
  local sent = result.sent == true

  local need = SyncConflicts.decisionCountText(decisions)

  if failed and decisions > 0 then
    if sent then
      return T(_("Some changes were sent. %1; the rest will retry."), need), "error"
    end
    return T(_("%1. Other changes will retry."), need), "error"
  elseif failed then
    return _("Sync failed. Changes are saved and will retry."), "error"
  elseif decisions > 0 then
    if sent then
      return T(_("Ready changes sent. %1."), need), "info"
    end
    return T(_("%1. Other changes are saved."), need), "info"
  elseif waiting > 0 then
    return sent and _("Ready changes sent. Some changes are waiting for an earlier one.")
      or _("Some changes are waiting for an earlier one."), "info"
  end
  return _("Progress synced"), "info"
end

-- A page a conversion from an edition page to a position in this file. `unmap` (optional) is
-- the page mapper's way from an edition page to this file's: it knows the book's page labels,
-- which a plain proportion does not.
function SyncConflicts.documentPage(edition_page, edition_pages, document_pages, unmap)
  if not (edition_page and edition_pages and edition_pages > 0 and document_pages) then
    return nil
  end
  local page = unmap and unmap(edition_page, document_pages, edition_pages)
    or math.floor(edition_page / edition_pages * document_pages + 0.5)
  return math.max(1, math.min(document_pages, page))
end

-- On opening a book online: is Hardcover's page far enough ahead of ours to
-- offer a jump? Same distance as the sync conflict question, and a "Stay here"
-- is remembered for that Hardcover page so it is not asked again until
-- Hardcover moves on.
function SyncConflicts.shouldOfferJump(cloud_page, local_page, declined_page, min_ahead)
  cloud_page, local_page = tonumber(cloud_page), tonumber(local_page)
  if not (cloud_page and local_page) then return false end
  if declined_page and tonumber(declined_page) == cloud_page then return false end
  return cloud_page - local_page >= min_ahead
end

return SyncConflicts
