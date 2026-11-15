-- How one queued read edit reaches Hardcover, for the progress queue (SyncQueue). The rules,
-- kept here once:
--
--   * re-read the library record first; a correction is never based on a stale prefetch;
--   * compare each field with what the form started from: a field already equal to the proposal
--     is dropped, a field changed on Hardcover since then parks a question, anything else is sent;
--   * send one sparse write (a broad payload would reset another device's progress);
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

-- Verify that the read now holds `proposal`. Returns true/false, and the read as found.
local function verified(api, entry, user_id, user_book, read_id, proposal, check)
  local fresh, err = api:findUserBook(entry.book_id, user_id or entry.user_id)
  if err ~= nil or type(fresh) ~= "table" or not fresh.id then return nil, nil, err end
  local found = findRead(fresh, read_id)
  if not found then return false, fresh end
  for field in pairs(check or proposal) do
    if not same(valueOf(found, field), proposal[field]) then return false, fresh, found end
  end
  return true, fresh, found
end

local function park(action, conflict)
  action.conflict = conflict
  action.checking, action.read_sent, action.read_attempt = nil, nil, nil
  return "parked", conflict
end

-- Send one action. `opts` is { user_id } (the account) and may carry `persist` (called after a
-- durable change to the action, so a crash cannot turn a sent write into a second one).
function ReadSender.send(api, entry, action, opts)
  opts = opts or {}
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
      local found = matchingRead(user_book, action.change)
      if found then
        rebindLocal(entry, action.local_id, found)
        return "sent", user_book
      end
      -- nothing matching: the add did not land. Its duplicate check makes a retry safe.
      action.checking, action.read_sent, action.read_attempt = nil, nil, nil
    elseif action.kind == "remove_read" then
      -- target is present, so the delete did not land; retry once, verified.
      action.checking, action.read_sent, action.read_attempt = nil, nil, nil
    else
      local attempt = action.read_attempt or {}
      local proposal, check = attempt.proposal or {}, attempt.check or {}
      local ok, fresh, found = verified(api, entry, opts.user_id, user_book, action.read_id, proposal, check)
      if ok then
        action.checking, action.read_sent, action.read_attempt = nil, nil, nil
        action.conflict = nil
        return "sent", fresh
      elseif found then
        local fields = conflictFields(action, found)
        if #fields > 0 then
          -- A third value: ask rather than overwrite it.
          return park(action, { kind = "read_changed", read_id = action.read_id, read = found, fields = fields })
        end
        -- Nothing is applied yet: the lost write did not land. Retrying from the unchanged
        -- read is safe; it is not a blind repeat.
        local unchanged = true
        for field in pairs(check) do
          if not same(valueOf(found, field), valueOf(action.base, field)) then unchanged = false end
        end
        if unchanged then
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
  else
    local fields = conflictFields(action, target)
    if #fields > 0 then
      return park(action, { kind = "read_changed", read_id = action.read_id, read = target, fields = fields })
    end
    if not hasFields(action) then
      -- every field already held the proposed value
      return "sent", user_book
    end
  end

  local fields = writeFields(action)
  local proposal, check = {}, {}
  for field in pairs(action.change or {}) do
    proposal[field] = valueOf(action.change, field)
    check[field] = true
  end
  for field, clear in pairs(action.clear or {}) do
    if clear then proposal[field], check[field] = nil, true end
  end
  action.read_attempt = { kind = action.kind, read_id = action.read_id, proposal = proposal, check = check }
  action.checking = true
  action.read_sent = nil
  if opts.persist then opts.persist() end

  local result, err
  if action.kind == "read_dates" or action.kind == "read_edition" then
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
    rebindLocal(entry, action.local_id, added)
  end

  -- Read again: Hardcover can answer a write with a slightly older read.
  local ok, fresh, found = verified(api, entry, opts.user_id, user_book, action.read_id, proposal, check)
  if ok then
    action.checking, action.read_sent, action.read_attempt = nil, nil, nil
    action.conflict = nil
    return "sent", fresh
  elseif action.kind == "add_read" then
    local fresh_read = fresh and added and findRead(fresh, added.id)
    if fresh_read then
      action.checking, action.read_sent, action.read_attempt = nil, nil, nil
      action.conflict = nil
      return "sent", fresh
    end
  end
  action.read_sent = true
  action.checking = true
  if opts.persist then opts.persist() end
  return "checking", fresh or user_book
end

return ReadSender
