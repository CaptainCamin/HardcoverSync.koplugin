-- How one queued read edit reaches Hardcover, for the progress queue (SyncQueue). The rules,
-- kept here once:
--
--   * re-read the library record first; a correction is never based on a stale prefetch;
--   * compare each field with what the form started from: a field already equal to the proposal
--     is dropped, a field changed on Hardcover since then parks a question, anything else is sent;
--   * send one sparse write (a broad payload would reset another device's progress); a current
--     read's edition change then moves the library record too, as Hardcover:moveEdition does;
--   * read again to verify. A lost response leaves the action in "checking", never a blind retry.
--
-- Returns a status and the library record (or the conflict/reason):
--   "sent"      the read is as proposed; `info` is the updated library record
--   "parked"    `info` is a conflict to ask about; nothing was written
--   "held"      the library record is gone (reason "library_gone"); stop the book
--   "checking"  the request may have landed; verify on the next pass, do not send again
--   "waiting"   the reader chose to wait for the newer read to finish
--   "failed"    Hardcover refused it; `info` is the reason
--   "transient" could not ask; try later
--
-- Plain data over the injected `api`, no KOReader requires, so it runs under stock Lua.

local Book = require("hardcover/lib/book")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Actions = require("hardcover/lib/reading_actions")
local OfflineQueue = require("hardcover/lib/offline_queue")
local ReadHistory = require("hardcover/lib/read_history")

local ReadSender = {}

local FIELDS = { "started_at", "finished_at", "finished_at_precision", "edition_id", "progress_pages" }
local DATE_FIELDS = { started_at = true, finished_at = true }

local function valueOf(row, field)
  if type(row) ~= "table" then return nil end
  local value = row[field]
  if value == nil then return nil end
  if DATE_FIELDS[field] then return tostring(value):match("^(%d%d%d%d%-%d%d%-%d%d)") or tostring(value) end
  return tonumber(value) or value
end

local function same(a, b)
  if a == nil or b == nil then return a == nil and b == nil end
  return tostring(a) == tostring(b)
end

local function copyFields(fields)
  local out = {}
  for key, value in pairs(fields or {}) do out[key] = value end
  return out
end

local function findRead(user_book, read_id)
  if read_id == nil then return nil end
  for index, read in ipairs(user_book and user_book.user_book_reads or {}) do
    if tostring(read.id) == tostring(read_id) then return read, index end
  end
end

local function mergeRead(user_book, read)
  if type(user_book) ~= "table" or type(read) ~= "table" then return user_book end
  local found = findRead(user_book, read.id)
  if found then
    for key, value in pairs(read) do found[key] = value end
  else
    user_book.user_book_reads = user_book.user_book_reads or {}
    table.insert(user_book.user_book_reads, read)
  end
  return user_book
end

local function dropRead(user_book, read_id)
  local reads = type(user_book) == "table" and user_book.user_book_reads
  if type(reads) ~= "table" then return user_book end
  for index = #reads, 1, -1 do
    if tostring(reads[index].id) == tostring(read_id) then table.remove(reads, index) end
  end
  return user_book
end

-- The read a newly added local read became, for the edits queued behind it.
local function rebindLocal(entry, local_id, read)
  if not (local_id and read and read.id) then return end
  for _, action in ipairs(Actions.list(entry)) do
    if action.local_id and tostring(action.local_id) == tostring(local_id) then
      action.read_id = read.id
      action.local_id = nil
    elseif action.read_id and tostring(action.read_id) == tostring(local_id) then
      action.read_id = read.id
    end
  end
  if entry.read_id and tostring(entry.read_id) == tostring(local_id) then entry.read_id = read.id end
end

local function matchingRead(user_book, fields)
  for _, read in ipairs(user_book and user_book.user_book_reads or {}) do
    if same(valueOf(read, "started_at"), valueOf(fields, "started_at"))
      and same(valueOf(read, "finished_at"), valueOf(fields, "finished_at"))
      and same(valueOf(read, "finished_at_precision"), valueOf(fields, "finished_at_precision"))
      and same(valueOf(read, "edition_id"), valueOf(fields, "edition_id")) then
      return read
    end
  end
end

local function olderThanCurrent(user_book, read_id)
  local current = Book:currentRead(user_book and user_book.user_book_reads or {})
  if not current or tostring(current.id) == tostring(read_id) or current.finished_at then return nil end
  return current
end

local function conflictFields(action, target)
  local conflicts = {}
  for _, field in ipairs(FIELDS) do
    local has_change = action.change and action.change[field] ~= nil
    local has_clear = action.clear and action.clear[field] == true
    if has_change or has_clear then
      local proposed = has_clear and nil or action.change[field]
      local online = valueOf(target, field)
      local baseline = valueOf(action.base, field)
      if same(online, proposed) then
        -- Hardcover already has what the reader wanted: nothing to send for this field
        if action.change then action.change[field] = nil end
        if action.clear then action.clear[field] = nil end
      elseif not same(online, baseline) then
        conflicts[#conflicts + 1] = {
          field = field, online = online, base = baseline, proposed = proposed, clear = has_clear and true or nil,
          label = ReadHistory.fieldLabel and ReadHistory.fieldLabel(field) or field,
        }
      end
    end
  end
  return conflicts
end

local function hasFields(action)
  return next(action.change or {}) ~= nil or next(action.clear or {}) ~= nil
end

local function nullValue()
  local json = require("json")
  return json.util and json.util.null or {}
end

local function writeFields(action)
  local fields = copyFields(action.change)
  local null = nullValue()
  for field, clear in pairs(action.clear or {}) do
    if clear then fields[field] = null end
  end
  return fields
end

-- The library record after the write, merged with the read the answer carries.
local function mergeAnswer(user_book, answer)
  if type(answer) ~= "table" then return user_book end
  for _, read in ipairs(answer.user_book_reads or {}) do mergeRead(user_book, read) end
  for key, value in pairs(answer) do
    if key ~= "user_book_reads" then user_book[key] = value end
  end
  return user_book
end

-- Whether one read holds every field the attempt asked to write. The lookup's answer and the
-- attempt's own answer both go through this, so finding a read is not enough to acknowledge it.
local function holds(read, proposal, check)
  if type(read) ~= "table" then return false end
  for field in pairs(check or proposal or {}) do
    if not same(valueOf(read, field), (proposal or {})[field]) then return false end
  end
  return true
end

-- Verify that the read now holds `proposal`. Returns true/false, the read as found, and on a
-- failed lookup nil plus the error, so the caller never mistakes an error table for a read.
local function verified(api, entry, user_id, user_book, read_id, proposal, check)
  local fresh, err = api:findUserBook(entry.book_id, user_id or entry.user_id)
  if err ~= nil or type(fresh) ~= "table" or not fresh.id then return nil, nil, nil, err end
  local found = findRead(fresh, read_id)
  if not found then return false, fresh end
  if not holds(found, proposal, check) then return false, fresh, found end
  return true, fresh, found
end

local function park(action, conflict)
  action.conflict = conflict
  action.checking, action.read_sent, action.read_attempt = nil, nil, nil
  return "parked", conflict
end

local function sameRead(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  for _, field in ipairs({ "id", "started_at", "finished_at", "finished_at_precision",
    "edition_id", "progress_pages" }) do
    if not same(valueOf(left, field), valueOf(right, field)) then return false end
  end
  return true
end

local function previousRead(user_book, action)
  if type(action.previous_read) ~= "table" or action.previous_read.id == nil then return nil end
  return findRead(user_book, action.previous_read.id)
end

-- The unfinished reads that matter for this abandon: the predecessor (when it is a DNF) and the
-- target. An older DNF is not a competing active read, and a newer active read would already have
-- failed the latestUnfinished check.
local function unfinishedFrom(user_book, previous, target, target_id)
  local reads = user_book and user_book.user_book_reads or {}
  local previous_index
  for index, read in ipairs(reads) do
    if sameRead(read, previous) then previous_index = index; break end
  end
  local target_order = target_id and Book.readIdOrder(target_id) or nil
  local out, seen = {}, {}
  local function add(read)
    if read and not read.finished_at and not seen[tostring(read.id)] then
      seen[tostring(read.id)] = true
      out[#out + 1] = read
    end
  end
  for index, read in ipairs(reads) do
    if previous then
      local include = sameRead(read, previous)
        or (target_order and Book.readIdOrder(read.id) > target_order)
      if previous.started_at and read.started_at then
        include = include or read.started_at > previous.started_at
          or (read.started_at == previous.started_at
            and Book.readIdOrder(read.id) >= Book.readIdOrder(previous.id))
      else
        include = include or index > (previous_index or 0)
      end
      if include then add(read) end
    else
      add(read)
    end
  end
  -- A target with a later session may sit earlier in the array after a backfill.
  add(target)
  return out
end

local function abandonConflict(action, reason, target, previous, user_book)
  return park(action, {
    kind = "abandon_changed", reason = reason, read_id = action.read_id,
    target = target, previous = previous,
    deleted = action.deleted or nil,
    status_id = user_book and tonumber(user_book.status_id),
    updated_at = user_book and user_book.updated_at,
  })
end

local function abandonShelfConflict(action, status_id, updated_at)
  action.restore_approval = nil
  return park(action, { kind = "abandon_shelf", read_id = action.read_id,
    status_id = status_id, updated_at = updated_at, deleted = action.deleted or nil })
end

local function approvalMatches(action, status, user_book)
  local approval = action.restore_approval
  if not approval or tonumber(approval.status_id) ~= tonumber(status) then return false end
  if approval.previous and (not action.previous_read
      or not sameRead(previousRead(user_book, action), approval.previous)) then
    return false
  end
  if not approval.updated_at or not user_book.updated_at then return false end
  if tostring(approval.updated_at) ~= tostring(user_book.updated_at) then return false end
  return true
end

local function postDeleteConflict(user_book, action, restore)
  local target = findRead(user_book, action.read_id)
  if target then return "target_reappeared", target end
  local previous = previousRead(user_book, action)
  if action.previous_read and (not previous or not sameRead(previous, action.previous_read)) then
    return "previous_changed", previous
  end
  for id, snapshot in pairs(action.previous_unfinished or {}) do
    local read = findRead(user_book, id)
    if read and not read.finished_at
        and (not previous or tostring(previous.id) ~= tostring(id))
        and (tostring(read.progress_pages or "") ~= tostring(snapshot.progress_pages or "")
          or tostring(read.started_at or "") ~= tostring(snapshot.started_at or "")) then
      return "another_read", read
    end
  end
  local active = unfinishedFrom(user_book, previous, target, action.read_id)
  local allowed = #active == 0
  if not allowed and restore == HARDCOVER.STATUS.DNF and action.previous_read
      and previous and not previous.finished_at and #active == 1
      and tostring(active[1].id) == tostring(previous.id) then
    allowed = true
  end
  if not allowed then return "another_read", previous end
  return nil, previous
end

local function freshBook(api, entry, opts)
  local fresh, err = api:findUserBook(entry.book_id, opts.user_id)
  if err ~= nil then return nil, err end
  if type(fresh) ~= "table" or not fresh.id then return nil, "library_gone" end
  return fresh
end

-- Hardcover can show a just-deleted read for a moment. Keep checking an unchanged readback
-- instead of parking it as a permanent conflict; a changed read is a real conflict.
local function staleReadback(user_book, action)
  local target = findRead(user_book, action.read_id)
  return target and sameRead(target, action.base) and (action.verify_attempts or 0) < 3
end

-- Delete the reread, then restore the library shelf without sending a finish date. Every path
-- that reaches a status write re-reads and validates the post-delete record first, including a
-- lost delete response and a retry after restart.
local function sendAbandon(api, entry, action, opts)
  local user_book, lookup_err = api:findUserBook(entry.book_id, opts.user_id)
  if lookup_err ~= nil then return "transient", lookup_err end
  if type(user_book) ~= "table" or not user_book.id then return "held", "library_gone" end
  if action.user_book_id and tostring(action.user_book_id) ~= tostring(user_book.id) then
    return abandonConflict(action, "library_changed", nil, nil, user_book)
  end

  local target = findRead(user_book, action.read_id)
  local previous = previousRead(user_book, action)
  local restore = tonumber(action.restore_status_id) or HARDCOVER.STATUS.FINISHED
  local status = tonumber(user_book.status_id)

  if not action.deleted then
    if not target then
      if not action.checking then
        -- Park both facts in the same flush; a restart between two saves must not skip the
        -- Restore/Leave decision.
        action.deleted = true
        return abandonConflict(action, "target_gone", nil, previous, user_book)
      end
      -- A lost delete response is checked: the target is gone, so continue to the restore.
      action.deleted, action.checking = true, nil
      if opts.persist then opts.persist() end
    else
      -- A delete whose response was lost may still be visible for a moment. Do not send it
      -- again; keep checking the unchanged read, then park for a decision if it stays.
      if action.checking then
        if sameRead(target, action.base) then
          if (action.verify_attempts or 0) < 3 then
            action.verify_attempts = (action.verify_attempts or 0) + 1
            if opts.persist then opts.persist() end
            return "checking", user_book
          end
          return abandonConflict(action, "target_reappeared", target, previous, user_book)
        end
        return abandonConflict(action, "target_changed", target, previous, user_book)
      end
      if target.finished_at then
        return abandonConflict(action, "target_finished", target, previous, user_book)
      end
      if not sameRead(target, action.base) then
        return abandonConflict(action, "target_changed", target, previous, user_book)
      end
      -- Only the newest read may be abandoned. An earlier DNF is unfinished too, but it is not
      -- the reread, and a DNF shelf is not a reading session.
      local latest = ReadHistory.latestUnfinished(user_book.user_book_reads)
      if not latest or tostring(latest.id) ~= tostring(target.id) or status == HARDCOVER.STATUS.DNF then
        return abandonConflict(action, "target_not_active", target, previous, user_book)
      end
      local immediate = ReadHistory.previous(user_book.user_book_reads, target)
      if action.previous_read and (not immediate or not sameRead(immediate, action.previous_read)) then
        return abandonConflict(action, "previous_changed", target, immediate or previous, user_book)
      end
      previous = immediate or previous
      if action.restore_approval then
        if not approvalMatches(action, status, user_book) then
          return abandonShelfConflict(action, status, user_book.updated_at)
        end
      elseif status ~= HARDCOVER.STATUS.READING then
        return abandonShelfConflict(action, status, user_book.updated_at)
      end
      local active = unfinishedFrom(user_book, previous, target, action.read_id)
      local allowed = #active == 1
      if not allowed and restore == HARDCOVER.STATUS.DNF and action.previous_read
          and previous and not previous.finished_at and #active == 2 then
        for _, read in ipairs(active) do
          if tostring(read.id) ~= tostring(target.id) and tostring(read.id) ~= tostring(previous.id) then
            allowed = false
            break
          end
          allowed = true
        end
      end
      if not allowed then
        return abandonConflict(action, "another_read", target, previous, user_book)
      end

      if opts.guard and opts.guard() then return "checking", user_book end
      action.previous_unfinished = {}
      for _, read in ipairs(user_book.user_book_reads or {}) do
        if not read.finished_at and read.id ~= nil then
          action.previous_unfinished[tostring(read.id)] = {
            progress_pages = read.progress_pages, started_at = read.started_at,
          }
        end
      end
      if opts.persist then opts.persist() end
      -- Persist the in-flight marker before the request. A restart after a lost response
      -- must know this delete may already have landed.
      action.checking = true
      if opts.persist then opts.persist() end
      local result, err = api:deleteRead(action.read_id)
      if not result then
        if err ~= nil and not OfflineQueue.transient(err) then
          action.checking = nil
          if opts.persist then opts.persist() end
          return "failed", err
        end
        return "checking", user_book
      end
      action.checking, action.deleted = nil, true
      if opts.persist then opts.persist() end
    end
  end

  -- Reload after the delete, including a lost delete response and a restarted retry. Never
  -- restore from the pre-delete snapshot: the shelf, predecessor, active reads and privacy may
  -- all have changed while the delete was out.
  local fresh, fresh_err = freshBook(api, entry, opts)
  if not fresh then
    if fresh_err == "library_gone" then return "held", fresh_err end
    action.checking = true
    if opts.persist then opts.persist() end
    return "checking", user_book
  end
  local post_reason, post_previous = postDeleteConflict(fresh, action, restore)
  if post_reason == "target_reappeared" and staleReadback(fresh, action) then
    action.verify_attempts = (action.verify_attempts or 0) + 1
    action.checking = true
    if opts.persist then opts.persist() end
    return "checking", fresh
  end
  if post_reason then
    return abandonConflict(action, post_reason, findRead(fresh, action.read_id), post_previous, fresh)
  end
  action.verify_attempts = nil
  status = tonumber(fresh.status_id)
  previous = post_previous

  if status ~= restore then
    if action.restore_approval then
      if not approvalMatches(action, status, fresh) then
        return abandonShelfConflict(action, status, fresh.updated_at)
      end
    elseif status ~= HARDCOVER.STATUS.READING then
      return abandonShelfConflict(action, status, fresh.updated_at)
    end

    if opts.guard and opts.guard() then return "checking", fresh end
    -- Status only: never write back the privacy value from the earlier lookup.
    local result, err = api:updateUserBookStatus(fresh.id, restore, nil, nil)
    if not result then
      if err ~= nil and not OfflineQueue.transient(err) then return "failed", err end
      action.checking = true
      if opts.persist then opts.persist() end
      return "checking", fresh
    end
  end

  -- The final readback is the verification, not just a success check. Reapply the full
  -- post-delete invariant before acknowledging and releasing the durable barrier.
  local final, verify_err = freshBook(api, entry, opts)
  if not final then
    action.checking = true
    if opts.persist then opts.persist() end
    return "checking", fresh
  end
  local final_reason, final_previous = postDeleteConflict(final, action, restore)
  if final_reason == "target_reappeared" and staleReadback(final, action) then
    action.verify_attempts = (action.verify_attempts or 0) + 1
    action.checking = true
    if opts.persist then opts.persist() end
    return "checking", final
  end
  if final_reason then
    return abandonConflict(action, final_reason, findRead(final, action.read_id), final_previous, final)
  end
  action.verify_attempts = nil
  if tonumber(final.status_id) == restore then
    action.checking, action.status_restored = nil, true
    if opts.persist then opts.persist() end
    return "sent", final
  end
  action.checking = true
  if opts.persist then opts.persist() end
  return "checking", final
end

-- The one edition move: the read first (its page converted to the new edition), then the library
-- record. `opts` is { read_id, book_id, edition_id, fields, status_id, privacy_setting_id,
-- optional settings, filename, edition_format, pages, state }. Returns the library record (with
-- the moved read), or nil and the reason. Used by the read queue and by Hardcover:moveEdition.
function ReadSender.moveEdition(api, opts)
  opts = opts or {}
  local fields = copyFields(opts.fields)
  fields.edition_id = opts.edition_id
  if opts.page ~= nil then fields.progress_pages = opts.page end

  local moved, read_err = api:updateRead(opts.read_id, fields)
  if not moved then return nil, read_err end
  local moved_read = moved.user_book_reads and moved.user_book_reads[1]
  if not (moved_read and moved_read.id) then return nil, "read" end

  local user_book, book_err = api:updateUserBook(opts.book_id, opts.status_id,
    opts.privacy_setting_id, opts.edition_id)
  if not (user_book and user_book.id) then return nil, book_err or { completed = false } end

  -- updateRead's answer and the library record both carry the moved read; keep the library
  -- record's full list, with the moved one in it.
  local found = false
  for i, read in ipairs(user_book.user_book_reads or {}) do
    if tostring(read.id) == tostring(moved_read.id) then
      user_book.user_book_reads[i] = moved_read
      found = true
      break
    end
  end
  if not found then
    user_book.user_book_reads = user_book.user_book_reads or {}
    table.insert(user_book.user_book_reads, moved_read)
  end

  if opts.settings and opts.settings.updateBookSetting and opts.filename then
    local update = { edition_id = opts.edition_id, pages = opts.pages,
      edition_format = opts.edition_format }
    local delete = {}
    for _, key in ipairs({ "edition_id", "pages", "edition_format" }) do
      if update[key] == nil then delete[#delete + 1] = key end
    end
    if #delete > 0 then update._delete = delete end
    opts.settings:updateBookSetting(opts.filename, update)
  end
  if opts.filename then
    if opts.cache and opts.cache.saveSnapshot then
      opts.cache:saveSnapshot(opts.filename, user_book)
    elseif opts.settings and opts.settings.saveBookSnapshot then
      opts.settings:saveBookSnapshot(opts.filename, user_book)
    end
  end
  if opts.state and opts.state.book_status and user_book.id
    and tonumber(opts.state.book_status.id) == tonumber(user_book.id) then
    for key, value in pairs(user_book) do opts.state.book_status[key] = value end
  end

  return user_book, nil, moved_read
end

-- Send one action. `opts` is { user_id } (the account) and may carry `persist` (called after a
-- durable change to the action, so a crash cannot turn a sent write into a second one).
function ReadSender.send(api, entry, action, opts)
  opts = opts or {}
  if action.kind == "abandon_reread" then return sendAbandon(api, entry, action, opts) end
  local user_book, lookup_err = api:findUserBook(entry.book_id, opts.user_id)
  if lookup_err ~= nil then return "transient", lookup_err end
  if type(user_book) ~= "table" or not user_book.id then return "held", "library_gone" end

  local target = action.kind ~= "add_read" and findRead(user_book, action.read_id) or nil
  if action.kind ~= "add_read" and not target then
    if action.kind == "remove_read" then
      -- Already gone: the removal is done, whatever removed it.
      return "sent", user_book
    end
    return park(action, { kind = "read_gone", read_id = action.read_id, base = action.base,
      change = action.change, clear = action.clear, read = action.base })
  end

  -- A request whose answer was lost is checked, not repeated.
  if action.checking then
    if action.kind == "add_read" then
      -- A successful answer names the read it created. While the verification lookup is still
      -- catching up, keep checking that id rather than inserting a second read.
      if action.added_id then
        local added = findRead(user_book, action.added_id)
        if added then
          -- The insert landed. If another device changed a field before this lookup, the read
          -- exists and later local edits must target it; keeping the action checking would block
          -- every later page for the book forever.
          rebindLocal(entry, action.local_id, added)
          action.checking, action.read_sent, action.read_attempt = nil, nil, nil
          action.conflict, action.added_id = nil, nil
          return "sent", user_book
        end
        return "checking", user_book
      end
      local found = matchingRead(user_book, action.change)
      if found then
        rebindLocal(entry, action.local_id, found)
        return "sent", user_book
      end
      -- nothing matching and no id: the add did not land. Its duplicate check makes a retry safe.
      action.checking, action.read_sent, action.read_attempt = nil, nil, nil
    elseif action.kind == "remove_read" then
      -- target is present, so the delete did not land; retry once, verified.
      action.checking, action.read_sent, action.read_attempt = nil, nil, nil
    else
      local attempt = action.read_attempt or {}
      local proposal, check = attempt.proposal or {}, attempt.check or {}
      local ok, fresh, found, verify_err = verified(api, entry, opts.user_id, user_book,
        action.read_id, proposal, check)
      if ok == nil then
        -- The verification lookup failed. The write may still have landed; keep checking rather
        -- than passing the error to conflictFields as if it were a read.
        return "checking", user_book, verify_err
      elseif ok then
        local library_pending = action.kind == "read_edition" and action.current
          and action.target_edition_id and fresh
          and tonumber(fresh.edition_id) ~= tonumber(action.target_edition_id)
        if not library_pending then
          action.checking, action.read_sent, action.read_attempt = nil, nil, nil
          action.conflict = nil
          return "sent", fresh
        end
        -- The read reached Hardcover, the library record did not. Send the record on this pass.
        user_book, target = fresh, found or target
        action.checking, action.read_sent, action.read_attempt = nil, nil, nil
      elseif found then
        local fields = conflictFields(action, found)
        if #fields > 0 then
          -- A third value: ask rather than overwrite it.
          return park(action, { kind = "read_changed", read_id = action.read_id, read = found, fields = fields })
        end
        -- Only the fields still waiting after conflictFields matter here. A field that already
        -- holds the proposal was removed from the change; counting it again as a change from the
        -- baseline would leave a partially applied attempt checking forever.
        local unchanged = true
        for field in pairs(check) do
          local requested = (action.change and action.change[field] ~= nil)
            or (action.clear and action.clear[field] == true)
          if requested and not same(valueOf(found, field), valueOf(action.base, field)) then
            unchanged = false
          end
        end
        if unchanged then
          -- Continue preflight from this one snapshot. The first lookup may have seen a different
          -- partial write; combining its target with these fields can acknowledge a value it
          -- never had.
          user_book, target = fresh, found
          action.checking, action.read_sent, action.read_attempt = nil, nil, nil
        else
          return "checking", fresh
        end
      elseif fresh then
        return park(action, { kind = "read_gone", read_id = action.read_id, base = action.base,
          change = action.change, clear = action.clear, read = action.base })
      else
        return "checking", user_book
      end
    end
  end

  if action.kind ~= "add_read" then
    if action.kind ~= "remove_read" and not action.force and not action.wait then
      local newer = olderThanCurrent(user_book, action.read_id)
      if newer and tonumber(user_book.status_id) == 2 then
        return park(action, { kind = "read_reading", read_id = action.read_id, read = target,
          current = newer, status_id = user_book.status_id })
      end
    end
    if action.wait then
      local newer = olderThanCurrent(user_book, action.read_id)
      if newer and tonumber(user_book.status_id) == 2 then
        return "waiting", { read = target, current = newer }
      end
      -- the newer read has finished: the reason for waiting is gone
      action.wait = nil
    end
  end

  if action.kind == "add_read" then
    local found = matchingRead(user_book, action.change)
    if found then
      rebindLocal(entry, action.local_id, found)
      return "sent", user_book
    end
  elseif action.kind ~= "remove_read" then
    local fields = conflictFields(action, target)
    if #fields > 0 then
      return park(action, { kind = "read_changed", read_id = action.read_id, read = target, fields = fields })
    end
    local target_edition = action.kind == "read_edition" and action.target_edition_id or nil
    local needs_library = target_edition and action.current
      and tonumber(user_book.edition_id) ~= tonumber(target_edition)
    if not hasFields(action) and not needs_library then
      -- every field already held the proposed value
      return "sent", user_book
    end
  end

  local target_edition = action.kind == "read_edition" and action.target_edition_id or nil
  local needs_library = target_edition and action.current
    and tonumber(user_book.edition_id) ~= tonumber(target_edition)
  local fields = writeFields(action)
  if needs_library then
    fields.edition_id = target_edition
    if action.target_page ~= nil then fields.progress_pages = action.target_page end
  end
  local proposal, check = {}, {}
  for field in pairs(action.change or {}) do
    proposal[field] = valueOf(action.change, field)
    check[field] = true
  end
  for field, clear in pairs(action.clear or {}) do
    if clear then proposal[field], check[field] = nil, true end
  end
  if needs_library then
    proposal.edition_id, check.edition_id = target_edition, true
    if action.target_page ~= nil then proposal.progress_pages, check.progress_pages = action.target_page, true end
  end
  action.read_attempt = { kind = action.kind, read_id = action.read_id, proposal = proposal, check = check }
  action.checking = true
  action.read_sent = nil
  if opts.persist then opts.persist() end

  local result, err
  if action.kind == "read_edition" and needs_library then
    result, err = ReadSender.moveEdition(api, {
      read_id = action.read_id, book_id = entry.book_id, edition_id = target_edition,
      fields = fields, page = fields.progress_pages,
      status_id = user_book.status_id, privacy_setting_id = user_book.privacy_setting_id,
      settings = opts.settings, filename = action.file or entry.file, cache = opts.cache,
      edition_format = action.edition_format, pages = action.new_pages, state = opts.state,
    })
  elseif action.kind == "read_dates" or action.kind == "read_edition" then
    result, err = api:updateRead(action.read_id, fields)
  elseif action.kind == "add_read" then
    result, err = api:addRead(user_book.id, fields)
  elseif action.kind == "remove_read" then
    result, err = api:deleteRead(action.read_id)
  else
    action.checking, action.read_attempt = nil, nil
    return "failed", "unknown read action"
  end

  if not result then
    if err ~= nil and not OfflineQueue.transient(err) then
      -- a definite refusal is not an ambiguous outcome: let the queue hold it
      action.checking, action.read_attempt = nil, nil
      return "failed", err
    end
    -- no answer: the write may or may not have landed
    action.read_attempt.lost = true
    if opts.persist then opts.persist() end
    return "checking", user_book
  end

  if action.kind == "remove_read" then
    dropRead(user_book, action.read_id)
    local fresh, err = api:findUserBook(entry.book_id, opts.user_id or entry.user_id)
    if err ~= nil then
      action.read_sent, action.checking = true, true
      if opts.persist then opts.persist() end
      return "checking", user_book
    end
    if fresh and not findRead(fresh, action.read_id) then
      action.checking, action.read_sent, action.read_attempt = nil, nil, nil
      action.conflict = nil
      return "sent", fresh
    end
    action.read_sent, action.checking = true, true
    if opts.persist then opts.persist() end
    return "checking", fresh or user_book
  end

  mergeAnswer(user_book, result)
  local added
  if action.kind == "add_read" then
    added = (result.user_book_reads or {})[1] or matchingRead(user_book, action.change)
    action.added_id = added and added.id or nil
    rebindLocal(entry, action.local_id, added)
  end

  -- Read again: Hardcover can answer a write with a slightly older read. An add is verified by
  -- the id its answer returned, not by a read id it did not have yet.
  local verify_id = action.kind == "add_read" and added and added.id or action.read_id
  local ok, fresh, found, verify_err = verified(api, entry, opts.user_id, user_book,
    verify_id, proposal, check)
  if ok == nil then
    action.read_sent = true
    action.checking = true
    if opts.persist then opts.persist() end
    return "checking", user_book, verify_err
  elseif ok then
    action.checking, action.read_sent, action.read_attempt = nil, nil, nil
    action.conflict, action.added_id = nil, nil
    return "sent", fresh
  elseif action.kind == "add_read" then
    local fresh_read = fresh and added and findRead(fresh, added.id)
    if fresh_read then
      -- The id exists, so the insert landed; a field changed elsewhere before this lookup. The
      -- read is real, so bind the local addition to it and let the history show what Hardcover
      -- has rather than blocking the book's later pages on a value this device cannot win.
      rebindLocal(entry, action.local_id, fresh_read)
      action.checking, action.read_sent, action.read_attempt = nil, nil, nil
      action.conflict, action.added_id = nil, nil
      return "sent", fresh
    end
  end
  action.read_sent = true
  action.checking = true
  if opts.persist then opts.persist() end
  return "checking", fresh or user_book
end

return ReadSender
