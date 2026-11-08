local HARDCOVER = require("hardcover/lib/constants/hardcover")

local Book = require("hardcover/lib/book")
local OfflineQueue = require("hardcover/lib/offline_queue")
local StatusSender = require("hardcover/lib/status_sender")
local Actions = require("hardcover/lib/reading_actions")

local SyncQueue = OfflineQueue.extend({})
SyncQueue.store_key = "pending"

-- Entries older than this were kept by file path (one per file); they are moved to the book's key
-- the first time the queue is read.
local function isBookKey(key)
  return type(key) == "string" and key:match("^%d+$") ~= nil
end

local STATUS_FIELDS = { "status_id", "status_updated_at", "finished_date", "passed_reading", "passed_reading_at", "from_status_id" }
local PAGE_FIELDS = { "mapped_page", "page_updated_at", "page_days", "first_page_date", "force_page", "reread", "conflict" }

-- Two entries for one book (it was read from two files): the one touched last is the base, and the
-- other adds its status or its page when that is newer, so neither a page nor a status is lost to the
-- other file's older one.
local function mergeEntries(a, b)
  local base, other = a, b
  if (tonumber(b.updated_at) or 0) > (tonumber(a.updated_at) or 0) then base, other = b, a end
  if other.status_id ~= nil and (base.status_id == nil
      or (tonumber(other.status_updated_at) or 0) > (tonumber(base.status_updated_at) or 0)) then
    for _, field in ipairs(STATUS_FIELDS) do base[field] = other[field] end
  end
  if other.mapped_page ~= nil and (base.mapped_page == nil
      or (tonumber(other.page_updated_at) or 0) > (tonumber(base.page_updated_at) or 0)) then
    for _, field in ipairs(PAGE_FIELDS) do base[field] = other[field] end
  end
  base.files = base.files or {}
  for file in pairs(other.files or {}) do base.files[file] = true end
  return base
end

local function migrate(pending)
  local old = {}
  for key, entry in pairs(pending) do
    if not isBookKey(key) then old[#old + 1] = { key = key, entry = entry } end
  end
  if #old == 0 then return false end
  table.sort(old, function(x, y) return tostring(x.key) < tostring(y.key) end)
  for _, item in ipairs(old) do
    pending[item.key] = nil
    local entry = item.entry
    local book_id = type(entry) == "table" and tonumber(entry.book_id)
    -- no book to send it to: it could not be sent before either
    if book_id and type(item.key) == "string" then
      entry.file, entry.files = item.key, { [item.key] = true }
      local key = tostring(book_id)
      pending[key] = pending[key] and mergeEntries(pending[key], entry) or entry
      if pending[key].file ~= item.key and (tonumber(pending[key].updated_at) or 0) <= (tonumber(entry.updated_at) or 0) then
        pending[key].file = item.key
      end
    end
  end
  return true
end

-- One entry per book, by Hardcover book id (as text): its queued page and status, and the file or
-- files it was read from (`file`: the last, `files`: all).
function SyncQueue:store()
  local pending = OfflineQueue.store(self)
  if not self.migrated then
    self.migrated = true
    local by_file = migrate(pending)
    local from_shelf = self:_takeShelfOps(pending)
    local actions_changed = false
    for _, entry in pairs(pending) do
      if type(entry) == "table" and not entry.actions then
        Actions.list(entry)
        actions_changed = true
      end
    end
    if by_file or from_shelf or actions_changed then self:persist() end
  end
  return pending
end

function SyncQueue:pending()
  return self:store()
end

-- Shelf changes were kept apart (ShelfQueue, "shelf_ops", by book id) until they moved in here: a status
-- or a removal is a change to one book, like its page. Each becomes the book's status (or removal) unless
-- the book already waits with a newer change; on a tie the one already here stands.
function SyncQueue:_takeShelfOps(pending)
  local ops = self.settings:readSetting("shelf_ops")
  if type(ops) ~= "table" then return false end
  local list = {}
  for _, op in pairs(ops) do
    local kind_ok = type(op) == "table" and tonumber(op.book_id)
      and (op.kind == "remove" or (op.kind == "status" and tonumber(op.status_id)))
    if kind_ok then list[#list + 1] = op end
  end
  table.sort(list, function(a, b) return tonumber(a.book_id) < tonumber(b.book_id) end)
  for _, op in ipairs(list) do
    local key = tostring(tonumber(op.book_id))
    local entry = type(pending[key]) == "table" and pending[key] or nil
    local have = entry and (tonumber(entry.remove_at) or tonumber(entry.status_updated_at))
    if not (entry and (entry.remove or entry.status_id ~= nil) and (tonumber(op.at) or 0) <= (have or 0)) then
      local from = tonumber(op.from_status_id) or 0
      if op.kind == "remove" then
        pending[key] = {
          book_id = tonumber(op.book_id), user_id = op.user_id, user_book_id = op.user_book_id, title = op.title,
          from_status_id = from, remove = true, remove_at = tonumber(op.at) or os.time(),
          file = entry and entry.file, files = entry and entry.files, updated_at = tonumber(op.at) or os.time(),
          held = op.held, reason = op.reason, failures = op.failures,
        }
      else
        entry = entry or { book_id = tonumber(op.book_id), user_id = op.user_id }
        entry.remove, entry.remove_at = nil, nil
        entry.title = op.title or entry.title
        entry.user_book_id = op.user_book_id or entry.user_book_id
        entry.edition_id = op.edition_id or entry.edition_id
        entry.status_id, entry.status_updated_at = tonumber(op.status_id), tonumber(op.at) or os.time()
        entry.from_status_id, entry.passed_reading, entry.finished_date = from, op.passed_reading, op.finished_date
        entry.passed_reading_at = op.passed_reading_at
        entry.held, entry.reason, entry.failures = op.held, op.reason, op.failures
        entry.updated_at = math.max(tonumber(entry.updated_at) or 0, tonumber(op.at) or 0)
        pending[key] = entry
      end
    end
  end
  self.settings:saveSetting("shelf_ops", nil)
  return true
end

-- The key of the entry for `ref`: a book id, an entry's key, or a file it was read from; nil when
-- there is none.
function SyncQueue:keyOf(ref)
  if ref == nil then return nil end
  if type(ref) == "number" then return tostring(ref) end
  local pending = self:pending()
  if pending[ref] ~= nil then return ref end
  for key, entry in pairs(pending) do
    if type(entry) == "table" and type(entry.files) == "table" and entry.files[ref] then return key end
  end
  return nil
end

-- Take the entry for `ref` out of the queue (not persisted).
function SyncQueue:_drop(ref)
  local key = self:keyOf(ref)
  if key then self:pending()[key] = nil end
end

-- a malformed entry (a hand edit, a merged settings file) is not something to send
function SyncQueue:valid(entry)
  return not self:isEmpty(entry)
end

-- `ref`: the book id, an entry's key, or a file the book was read from.
function SyncQueue:get(ref)
  local key = self:keyOf(ref)
  return key and self:pending()[key] or nil
end

-- A malformed entry (a hand edit, a merged settings file) counts as empty so
-- one bad value cannot make every queue check throw.
function SyncQueue:isEmpty(entry)
  return type(entry) ~= "table" or (entry.mapped_page == nil and entry.status_id == nil and not entry.remove)
end

function SyncQueue:hasPending(filepath)
  if filepath then
    return not self:isEmpty(self:get(filepath))
  end

  for _, entry in pairs(self:pending()) do
    if not self:isEmpty(entry) then
      return true
    end
  end
  return false
end

-- How many books are waiting to be sent as finished. A reading goal counts these
-- on top of what the server has counted, so finishing a book offline moves the
-- number straight away.
function SyncQueue:finishedCount()
  local count = 0
  for _, entry in pairs(self:pending()) do
    if type(entry) == "table" and entry.status_id == HARDCOVER.STATUS.FINISHED then
      count = count + 1
    end
  end
  return count
end

-- The keys of the entries with something to send, in a stable order.
function SyncQueue:keys()
  local keys = {}
  for key, entry in pairs(self:pending()) do
    if not self:isEmpty(entry) then
      table.insert(keys, key)
    end
  end
  -- pairs() order is arbitrary; a stable order keeps flushes reproducible
  table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  return keys
end

-- The status waiting for the book (by Hardcover book id, whichever file it was set from),
-- or nil.
function SyncQueue:statusFor(book_id)
  book_id = tonumber(book_id)
  if not book_id then return nil end
  for _, entry in pairs(self:pending()) do
    if type(entry) == "table" and entry.status_id ~= nil and tonumber(entry.book_id) == book_id then
      return entry.status_id
    end
  end
end

function SyncQueue:pendingCount()
  return #self:keys()
end

-- How many changes are waiting, counting a page and a status separately when
-- both are queued for the same book. pendingCount() remains the number of files.
function SyncQueue:changeCount()
  local count = 0
  for _, filepath in ipairs(self:keys()) do
    local entry = self:get(filepath)
    if entry.mapped_page ~= nil then count = count + 1 end
    -- Pending changes groups a book's statuses under one cancellation control.
    if Actions.statusCount(entry) > 0 or entry.remove then count = count + 1 end
  end
  return count
end

function SyncQueue:clearAll()
  local pending = self:pending()
  local cleared = 0

  for filepath, entry in pairs(pending) do
    if not self:isEmpty(entry) then
      cleared = cleared + 1
    end
    pending[filepath] = nil
  end

  self:persist()

  return cleared
end

-- Does not persist: callers set their own fields first and write once. Offline
-- every page turn lands here, and each write is a flash write on the device.
-- `file` is where the change was made from; `meta.book_id` says which book it is for. Returns nil for
-- a change with no book: there is nothing to send it to.
function SyncQueue:_ensure(file, meta)
  local book_id = meta and tonumber(meta.book_id)
  if not book_id then return nil end
  local key = tostring(book_id)
  local pending = self:pending()
  local entry = pending[key] or {}
  -- what another account left for this file is not carried over to this one
  if type(entry) ~= "table" or (meta and meta.user_id ~= nil and not SyncQueue.ownedBy(entry, meta.user_id)) then
    entry = {}
  end
  Actions.list(entry)
  if meta then
    for key, value in pairs(meta) do
      if value ~= nil and key ~= "status_id" and key ~= "mapped_page" then
        entry[key] = value
      end
    end
  end
  if type(file) == "string" then
    entry.file = file
    entry.files = type(entry.files) == "table" and entry.files or {}
    entry.files[file] = true
  end
  entry.updated_at = os.time()
  pending[key] = entry
  return entry
end

function SyncQueue:enqueuePage(filepath, payload)
  -- No page to record: keep whatever is already queued rather than erase it
  if payload.mapped_page == nil then
    return self:get(filepath)
  end
  local entry = self:_ensure(filepath, payload)
  if not entry then return nil end
  local at = os.time()
  Actions.page(entry, payload.mapped_page, at, entry.reread, payload.force_page)
  entry.first_page_date = entry.first_page_date or os.date("%Y-%m-%d", at)
  entry.failures = nil
  -- reading on changes the question being asked (and the user's earlier answer)
  entry.conflict = nil
  self:persist()
  return entry
end

-- A page that starts the book again. The flush changes status and writes the read Hardcover creates.
function SyncQueue:startReread(filepath, payload)
  local entry = self:_ensure(filepath, payload)
  if not entry then return nil end
  entry.from_status_id = entry.from_status_id or payload.from_status_id or 0
  local at = os.time()
  local start = Actions.status(entry, HARDCOVER.STATUS.READING, at, nil, true)
  start.from_page = true
  entry.read_id, entry.started_at = nil, nil
  entry.first_page_date = os.date("%Y-%m-%d", at)
  Actions.page(entry, payload.mapped_page or 0, at, true)
  entry.conflict, entry.failures = nil, nil
  self:persist()
  return entry
end

-- The final shelf on this device, irrespective of earlier unsent transitions.
function SyncQueue:statusOf(filepath)
  local entry = self:get(filepath)
  if type(entry) ~= "table" then return nil end
  return entry.status_id or (entry.reread and HARDCOVER.STATUS.READING or nil)
end

-- Is a change of the book's shelf (a status, or a re-read) waiting for this file?
function SyncQueue:shelfChangeWaiting(filepath)
  local entry = self:get(filepath)
  return type(entry) == "table" and (entry.status_id ~= nil or entry.reread == true or entry.remove == true)
end

-- `payload.from_status_id` is the shelf the book was on before the change (nil: on none), kept
-- as `from_status_id` (0 for none) so that cancelling the change can put the saved shelves back.
-- When a change is already waiting, the shelf it started from is kept.
function SyncQueue:enqueueStatus(filepath, payload)
  local held = self:shelfChangeWaiting(filepath)
  local before = held and self:get(filepath)
  local origin = before and before.from_status_id
  local previous = before and before.status_id or payload.from_status_id
  local reread = payload.status_id == HARDCOVER.STATUS.READING
    and (previous == HARDCOVER.STATUS.FINISHED or previous == HARDCOVER.STATUS.DNF) or nil
  local entry = self:_ensure(filepath, payload)
  if not entry then return nil end
  -- back from a waiting removal: the record is still there, so this is not a book new to the library
  if before and before.remove then entry.remove, entry.remove_at, entry.edition_id = nil, nil, nil end
  entry.held, entry.reason = nil, nil
  entry.from_status_id = origin or payload.from_status_id or 0
  -- The day the book was finished, kept so a sync on a later day does not become the finish date
  local at = os.time()
  local finished_date = payload.status_id == HARDCOVER.STATUS.FINISHED and os.date("%Y-%m-%d", at) or nil
  Actions.status(entry, payload.status_id, at, finished_date, reread)
  if reread then
    entry.read_id, entry.started_at = nil, nil
    entry.first_page_date = os.date("%Y-%m-%d", at)
  end
  entry.failures = nil
  self:persist()
  return entry
end

function SyncQueue:save(ref, entry)
  local pending = self:pending()
  local key = self:keyOf(ref) or (type(entry) == "table" and tonumber(entry.book_id) and tostring(tonumber(entry.book_id)))
  if not key then return end
  if self:isEmpty(entry) then
    pending[key] = nil
  else
    pending[key] = entry
  end
  self:persist()
end

--
-- The book leaves the library. `user_book_id` is its record, `from_status_id` the shelf it is on.
-- Returns "queued", or "dropped" when the book only ever went on a shelf offline: there is nothing on
-- Hardcover to remove, so what waits for it (a status, a page) is thrown away. The pages of a removed
-- book belonged to the record that goes, so a queued removal keeps none. (A change already on its way
-- is not dropped: the book will exist, so the removal follows it and looks the record up.)
--
function SyncQueue:queueRemove(user_id, book_id, user_book_id, title, from_status_id)
  local key = tostring(tonumber(book_id) or book_id)
  local pending = self:pending()
  local before = pending[key]
  if type(before) ~= "table" or not SyncQueue.ownedBy(before, user_id) then before = nil end
  user_book_id = tonumber(user_book_id) or (before and tonumber(before.user_book_id)) or nil
  if not user_book_id and not (before and self.sending_key == key) then
    pending[key] = nil
    self:persist()
    return "dropped"
  end
  local now = os.time()
  pending[key] = {
    book_id = tonumber(book_id), user_id = user_id, user_book_id = user_book_id,
    title = title or (before and before.title),
    from_status_id = before and before.from_status_id or from_status_id or 0,
    remove = true, remove_at = now, updated_at = now,
    file = before and before.file, files = before and before.files,
  }
  self:persist()
  return "queued"
end

-- A change of shelf waiting for a book, as the details screens and Pending changes know it:
-- { kind ("status" or "remove"), user_id, book_id, status_id, user_book_id, edition_id, title,
-- from_status_id (nil: on none), finished_date, at, held, reason, failures }; nil
-- when the entry has none.
function SyncQueue.opOf(entry)
  if type(entry) ~= "table" or not (entry.remove or entry.status_id ~= nil) then return nil end
  local from = tonumber(entry.from_status_id)
  return {
    kind = entry.remove and "remove" or "status", user_id = entry.user_id, book_id = tonumber(entry.book_id),
    status_id = (not entry.remove) and entry.status_id or nil, user_book_id = entry.user_book_id,
    edition_id = entry.edition_id, title = entry.title, from_status_id = (from and from ~= 0) and from or nil,
    finished_date = entry.finished_date,
    at = entry.remove and entry.remove_at or entry.status_updated_at,
    held = entry.held, reason = entry.reason, failures = entry.failures,
  }
end

-- The shelf change waiting for this book, or nil. With a user_id, one made by another account is not
-- returned (an entry with no user_id, from an older version, is).
function SyncQueue:shelfOp(book_id, user_id)
  local entry = self:get(tonumber(book_id) or book_id)
  if user_id ~= nil and not SyncQueue.ownedBy(entry, user_id) then return nil end
  return SyncQueue.opOf(entry)
end

--
-- Cancel one waiting change of one book, leaving the others. The entry goes when nothing
-- is left in it. (A page that was waiting for the reader's answer to a question is no
-- longer asked about once it is cancelled.)
--
function SyncQueue:cancelPage(filepath)
  local entry = self:get(filepath)
  if type(entry) ~= "table" then return false end
  if self.sending_key == self:keyOf(filepath) or not Actions.cancel(entry, "page") then return false end
  entry.force_page, entry.first_page_date, entry.reread = nil, nil, nil
  if entry.status_id == nil then entry.from_status_id = nil end
  entry.conflict, entry.failures = nil, nil
  self:save(filepath, entry)
  return true
end

-- (A question about the book's page, and the answer given to it, belong to the page: they
-- stay when only the status is cancelled.)
function SyncQueue:cancelStatus(filepath)
  local entry = self:get(filepath)
  if type(entry) ~= "table" then return false end
  if self.sending_key == self:keyOf(filepath) then return false end
  if not entry.remove and not Actions.cancel(entry, "status") then return false end
  entry.privacy_setting_id, entry.failures = nil, nil
  entry.remove, entry.remove_at, entry.held, entry.reason = nil, nil, nil, nil
  if not entry.reread then entry.from_status_id = nil end
  self:save(filepath, entry)
  return true
end

-- Cancel the exact journal row, not a newer action with the same value. A start needed by
-- later progress (or a finish needed by a reread) must be cancelled after its dependants.
function SyncQueue:cancelAction(book_id, seq, user_id, expected_entry)
  local entry = self:get(book_id)
  if not entry or entry ~= expected_entry or not SyncQueue.ownedBy(entry, user_id) then return false, "missing" end
  if self.sending_key == self:keyOf(book_id) then return false, "sending" end
  local before, origin = self:statusOf(book_id), tonumber(entry.from_status_id)
  local removed
  if entry.remove and seq == nil then
    removed = true
    entry.remove, entry.remove_at = nil, nil
  else
    local reason
    removed, reason = Actions.cancel(entry, nil, seq)
    if not removed then return false, reason end
  end
  if not removed then return false, "missing" end
  Actions.refresh(entry)
  local after = self:statusOf(book_id) or (origin and origin ~= 0 and origin or nil)
  entry.failures, entry.held, entry.reason = nil, nil, nil
  if entry.conflict and entry.conflict.seq == seq then entry.conflict = nil end
  self:save(book_id, entry)
  return true, { kind = "status", shelf_op = {
    kind = "status", book_id = tonumber(entry.book_id), user_book_id = entry.user_book_id,
    status_id = before, from_status_id = after, known = origin ~= nil,
  } }
end

function SyncQueue:clear(ref)
  self:_drop(ref)
  self:persist()
end

function SyncQueue:shouldFlushPage(entry)
  if not entry or entry.mapped_page == nil then
    return false
  end
  if entry.status_id == nil then
    return true
  end
  return entry.status_id == HARDCOVER.STATUS.READING
end

function SyncQueue:applyPending(filepath, book_status)
  local entry = self:get(filepath)
  if self:isEmpty(entry) or not book_status then
    return book_status
  end

  if self:statusOf(filepath) then
    book_status.status_id = self:statusOf(filepath)
  end
  if entry.privacy_setting_id then
    book_status.privacy_setting_id = entry.privacy_setting_id
  end
  if entry.mapped_page ~= nil then
    local reads = book_status.user_book_reads
    -- A finished reread still has its own progress, even though it is no longer an active
    -- reading session. Do not lay its lower page over the earlier read's higher page.
    local reread = entry.reread
    local actions = Actions.list(entry)
    for i = #actions, 1, -1 do
      if actions[i].kind == "page" then reread = actions[i].reread; break end
    end
    local read = not reread and Book:currentRead(reads)
    if read then
      -- The server may already be ahead (read on another device): never show
      -- the book as further back than the cloud says.
      local shown = tonumber(read.progress_pages)
      -- (unless the reader set this page by hand: that is theirs to move backwards)
      if not shown or shown < entry.mapped_page or entry.force_page then
        read.progress_pages = entry.mapped_page
      end
      if entry.edition_id then
        read.edition_id = entry.edition_id
      end
    else
      book_status.user_book_reads = { {
        id = entry.read_id,
        progress_pages = entry.mapped_page,
        edition_id = entry.edition_id,
        started_at = entry.started_at,
      } }
    end
  end

  return book_status
end

--
-- The Currently Reading cards with what is queued laid over them, so Home shows the
-- reading done offline: a queued page further on than the card's, a book moved off
-- Currently Reading (finished, dropped, put back to want-to-read) gone, and a book set
-- to Currently Reading offline first in the list. `entries` are the saved or fetched
-- cards (not changed: copies come back); `lookup(book_id, queued)` may return the saved
-- shelf row for a book that is not among them (for its cover and page count).
--
function SyncQueue:applyToReading(entries, lookup)
  entries = type(entries) == "table" and entries or {}

  local queued = {}
  for _, filepath in ipairs(self:keys()) do
    local entry = self:get(filepath)
    local book_id = type(entry) == "table" and tonumber(entry.book_id)
    if book_id then queued[book_id] = entry end
  end
  if next(queued) == nil then return entries end

  local out, have = {}, {}
  for _, entry in ipairs(entries) do
    local id = tonumber(entry.book_id)
    local q = id and queued[id]
    if id then have[id] = true end
    local queued_status = q and self:statusOf(id)
    if not (queued_status and queued_status ~= HARDCOVER.STATUS.READING) then
      local card = {}
      for k, v in pairs(entry) do card[k] = v end
      if q and q.mapped_page ~= nil then
        local shown = tonumber(card.progress_pages)
        if not shown or shown < q.mapped_page or q.force_page or q.reread then card.progress_pages = q.mapped_page end
      end
      out[#out + 1] = card
    end
  end

  -- books started (or put back to Currently Reading) offline, the newest first
  local fresh = {}
  for id, q in pairs(queued) do
    if self:statusOf(id) == HARDCOVER.STATUS.READING and not have[id] then fresh[#fresh + 1] = { id = id, q = q } end
  end
  table.sort(fresh, function(a, b)
    return (a.q.status_updated_at or 0) > (b.q.status_updated_at or 0)
  end)
  for i = #fresh, 1, -1 do
    local id, q = fresh[i].id, fresh[i].q
    local row = lookup and lookup(id, q)
    local card = {}
    for k, v in pairs(type(row) == "table" and row or {}) do card[k] = v end
    card.book_id = id
    card.title = card.title or q.title
    if q.mapped_page ~= nil then card.progress_pages = q.mapped_page end
    table.insert(out, 1, card)
  end
  return out
end

local function hasUserBook(user_book)
  return type(user_book) == "table" and user_book.id ~= nil
end

-- An entry the server answered for but refused this many flushes in a row is
-- held: it stays queued (the user can retry or discard it) but no longer
-- takes a turn, so one dead book cannot starve the rest.
SyncQueue.MAX_REJECTIONS = 3

function SyncQueue:isHeld(entry)
  return type(entry) == "table"
    and ((entry.failures or 0) >= SyncQueue.MAX_REJECTIONS or entry.conflict ~= nil or entry.held == true)
end

-- When the cloud is ahead of a queued page by this many pages or more the user
-- is asked which to keep; by less, the cloud quietly wins (a few pages is a
-- re-read of the same stretch, not a different place in the book).
SyncQueue.CONFLICT_PAGES = 5

-- Entries waiting for the user's answer: a list of { filepath, entry }, ordered.
function SyncQueue:conflicts()
  local list = {}
  for _, key in ipairs(self:keys()) do
    local entry = self:get(key)
    if type(entry) == "table" and entry.conflict then
      list[#list + 1] = { filepath = entry.file or key, key = key, entry = entry }
    end
  end
  return list
end

function SyncQueue:conflictCount()
  return #self:conflicts()
end

-- Apply the user's answer to one entry's conflict.
--   page:   "cloud" keeps Hardcover's page and drops ours (remembering it as the
--           place to resume); "local" sends ours.
--   reread: "yes" sends a NEW read (the old one is never touched); "no" drops
--           the queued progress.
-- "later" is not an answer: it leaves everything as it is. Returns true when
-- something changed.
function SyncQueue:resolve(filepath, choice)
  local entry = self:get(filepath)
  if type(entry) ~= "table" or not entry.conflict then
    return false
  end
  local kind, seq = entry.conflict.kind, entry.conflict.seq

  if kind == "page" and choice == "cloud" then
    local resume = self.settings:readSetting("resume")
    if type(resume) ~= "table" then
      resume = {}
      self.settings:saveSetting("resume", resume)
    end
    -- the place to resume is a file's: the one asked about, else the one read last
    local file = type(entry.files) == "table" and entry.files[filepath] and filepath or entry.file or filepath
    resume[file] = entry.conflict.cloud_page
    self.settings:saveSetting("resume", resume)
  elseif kind == "page" and choice == "local" then
    for _, action in ipairs(Actions.list(entry)) do
      if action.kind == "page" and (not entry.conflict.seq or action.seq == entry.conflict.seq) then
        action.force = true
      end
    end
    Actions.refresh(entry)
  elseif kind == "reread" and choice == "yes" then
    local active = entry.conflict.seq == nil
    for _, action in ipairs(Actions.list(entry)) do
      if action.seq == entry.conflict.seq then active = true end
      if active then
        if action.kind == "page" then
          action.reread = true
        elseif action.value == HARDCOVER.STATUS.FINISHED or action.value == HARDCOVER.STATUS.DNF
          or action.value == HARDCOVER.STATUS.TO_READ then
          break
        end
      end
    end
    Actions.refresh(entry)
  elseif kind == "reread" and choice == "no" then
    -- Removed below, along with the page's metadata.
  else
    return false
  end

  entry.conflict = nil
  if (kind == "page" and choice == "cloud") or (kind == "reread" and choice == "no") then
    Actions.rejectPages(entry, seq)
  end
  entry.failures = nil
  if self:isEmpty(entry) then
    self:_drop(filepath)
  end
  self:persist()
  return true
end

-- The place to jump to the next time this file is opened, set when the user
-- chose Hardcover's page over this device's. Cleared once read.
function SyncQueue:takeResumePage(filepath)
  local resume = self.settings:readSetting("resume")
  if type(resume) ~= "table" or resume[filepath] == nil then
    return nil
  end
  local page = resume[filepath]
  resume[filepath] = nil
  self.settings:saveSetting("resume", resume)
  self:persist()
  return page
end

-- Give held entries another go.
function SyncQueue:retryHeld()
  for _, entry in pairs(self:pending()) do
    if type(entry) == "table" then
      entry.failures, entry.held, entry.reason = nil, nil, nil
    end
  end
  self:persist()
end

local function countRejection(self, filepath)
  local entry = self:get(filepath)
  if type(entry) == "table" then
    entry.failures = (entry.failures or 0) + 1
    self:persist()
  end
end

-- A status or removal did not go through. Hardcover not answering (or a busy server) says nothing about the
-- change: it is tried again later. A refusal is counted, and held at once for a missing permission.
local function failed(self, key, err)
  if err ~= nil and OfflineQueue.transient(err) then return false, "transient" end
  local entry = self:get(key)
  if type(entry) == "table" then
    OfflineQueue.reject(entry, err)
    self:persist()
  end
  return false
end

-- A status that was kept as a shelf change (no file here) went through: the screens that showed it as
-- waiting are told. The reader's own changes were shown when they were made.
local function statusSent(opts, entry, status_id, user_book)
  if not opts.on_status_sent or entry.file then return end
  local from = tonumber(entry.from_status_id)
  opts.on_status_sent({
    kind = "status", user_id = entry.user_id, book_id = tonumber(entry.book_id), status_id = status_id,
    user_book_id = entry.user_book_id, from_status_id = (from and from ~= 0) and from or nil,
  }, user_book)
end

local function latestRead(user_book)
  local reads = user_book and user_book.user_book_reads
  return reads and reads[#reads]
end

local function holdChangedReading(self, entry)
  entry.held, entry.reason = true, "reading_changed"
  self:persist()
  return nil, "reading_changed"
end

-- The status request and its remaining date/page writes are separate durable steps. Keep the
-- pre-request identity too: a lost response must not turn a remotely finished read into a reread.
function SyncQueue:_sendStatus(api, key, entry, op, user_book, status, info)
  if op.status_sent then
    if not hasUserBook(user_book) or user_book.id ~= entry.user_book_id then
      return holdChangedReading(self, entry)
    end
    return user_book
  end
  local read = latestRead(user_book)
  local attempt = op.status_attempt
  -- An offline end event may have been queued without a saved shelf. If this
  -- book was already Read before we sent anything, its finish date belongs to
  -- the old reading. Only our own attempted transition may correct that date
  -- on a retry (including a request whose response was lost).
  if not attempt and status == HARDCOVER.STATUS.FINISHED
    and hasUserBook(user_book) and user_book.status_id == status then
    op.finished_date = nil
  end
  if attempt then
    local same_book = (user_book and user_book.id or 0) == attempt.user_book_id
    local same_read = (read and read.id or 0) == attempt.read_id
    local new_read = status == HARDCOVER.STATUS.READING and (attempt.read_id == 0
      or attempt.from_status == HARDCOVER.STATUS.FINISHED or attempt.from_status == HARDCOVER.STATUS.DNF)
    local applied = hasUserBook(user_book) and user_book.status_id == status
      and (same_book or attempt.user_book_id == 0)
      and (new_read and read and not read.finished_at
        and #user_book.user_book_reads == attempt.read_count + 1 or not new_read and same_read)
    if not (same_book and same_read and (user_book and user_book.status_id or 0) == attempt.from_status)
      and not applied then
      return holdChangedReading(self, entry)
    end
  end
  local result, err = user_book, nil
  if not hasUserBook(user_book) or user_book.status_id ~= status then
    op.status_attempt = attempt or { user_book_id = user_book and user_book.id or 0,
      read_id = read and read.id or 0, read_count = #(user_book and user_book.user_book_reads or {}),
      from_status = user_book and user_book.status_id or 0 }
    self:persist()
    result, err = StatusSender.upsert(api, user_book, status, info)
    if not hasUserBook(result) then
      if err ~= nil and not OfflineQueue.transient(err) then
        op.status_attempt = nil -- a definite refusal, not an ambiguous outcome
        self:persist()
      end
      return nil, err
    end
  end
  -- Do not attach a response to an entry replaced while the network yielded.
  if self:get(key) ~= entry or entry.remove then return nil end
  op.status_sent = true
  op.read_id = latestRead(result) and latestRead(result).id
  entry.user_book_id = result.id
  self:persist()
  return result
end

-- Sends one file's pending status and page. Returns true when the entry is
-- fully sent, false when it should be kept for another attempt; the second
-- value is "transient" when the server could not be reached or asked, so the
-- caller can tell an outage from a refusal.
-- The record flush fetched for this book before the loop, used once: a later
-- entry for the same book must see what this one sent, so it asks again.
local function findUserBook(api, book_id, opts, prefetched)
  local key = tostring(book_id)
  local record = prefetched and prefetched[key]
  if record ~= nil then
    prefetched[key] = nil
    return record or nil
  end
  return api:findUserBook(book_id, opts.user_id)
end

function SyncQueue:_flushEntry(api, filepath, opts, prefetched)
  local entry = self:get(filepath)
  if self:isEmpty(entry) then
    return true
  end

  local files = entry.files or {}
  local book_id = entry.book_id
  local edition_id = entry.edition_id
  local privacy_setting_id = entry.privacy_setting_id

  if entry.remove then
    local id = entry.user_book_id
    if not id then
      local found, lookup_err = findUserBook(api, book_id, opts, prefetched)
      if lookup_err ~= nil then return false, "transient" end
      id = found and found.id -- not in the library: nothing to remove
    end
    local removed, err = true, nil
    if id then removed, err = api:removeUserBook(id) end
    if not removed then return failed(self, filepath, err) end
    -- a status made while this was out is what is left to send
    local now = self:get(filepath)
    if now == entry and entry.remove then
      local op = SyncQueue.opOf(entry)
      self:_drop(filepath)
      self:persist()
      if opts.on_status_sent and not entry.file then opts.on_status_sent(op, removed) end
    end
    return true
  end

  -- A failed lookup looks like an empty one; an error means we do not know, so
  -- send nothing rather than create a user book over a real one.
  local user_book, lookup_err = findUserBook(api, book_id, opts, prefetched)
  if lookup_err ~= nil then
    return false, "transient"
  end

  local ops = {}
  for _, action in ipairs(Actions.list(entry)) do ops[#ops + 1] = action end
  local info = {
    book_id = book_id, edition_id = edition_id, privacy_setting_id = privacy_setting_id,
  }

  for i, op in ipairs(ops) do
    -- A cancellation, removal or replacement while the network yielded must stop this stream.
    if self:get(filepath) ~= entry or entry.remove then return false end
    local pending = false
    for _, action in ipairs(entry.actions) do if action.seq == op.seq then pending = true break end end
    if pending then
      entry.sending_seq = op.seq
      info.at = op.at
      local current = hasUserBook(user_book) and user_book.status_id
      local finished = current == HARDCOVER.STATUS.FINISHED or current == HARDCOVER.STATUS.DNF
      local starts = op.kind == "status" and op.value == HARDCOVER.STATUS.READING
        or op.kind == "page" and (not current or current == HARDCOVER.STATUS.TO_READ or op.reread and finished)
      local read = hasUserBook(user_book) and Book:currentRead(user_book.user_book_reads)
      if starts and current ~= HARDCOVER.STATUS.READING and (not read or read.finished_at or finished)
        and not op.start_date and op.at and op.at > 0 then
        -- action_at dates the journal, not the read Hardcover creates. Keep the intended date
        -- before the request: even a lost status response must leave its date correction queued.
        op.start_date = op.kind == "page" and not op.reread and op.started_at or os.date("%Y-%m-%d", op.at)
        self:persist()
      end
      if op.kind == "status" then
        local result, err = self:_sendStatus(api, filepath, entry, op, user_book, op.value, info)
        if not hasUserBook(result) then
          if err == "reading_changed" then return false end
          return failed(self, filepath, err)
        end
        user_book = result
        op.applied = true
        self:persist()
      elseif not op.applied then
        -- An implicit start is still outstanding after a lost response even if the lookup
        -- now says Reading. Reconcile its saved identity before choosing a page's target.
        if op.status_attempt or op.status_sent then
          local started, err = self:_sendStatus(api, filepath, entry, op, user_book, HARDCOVER.STATUS.READING, info)
          if err == "reading_changed" then return false end
          if not hasUserBook(started) then return failed(self, filepath, err) end
          user_book = started
        end
        if not hasUserBook(user_book) then
          local created, err = self:_sendStatus(api, filepath, entry, op, user_book, HARDCOVER.STATUS.READING, info)
          if err == "reading_changed" then return false end
          if not hasUserBook(created) then return failed(self, filepath, err) end
          user_book = created
        end
        local current = user_book.status_id
        if current == HARDCOVER.STATUS.TO_READ then
          -- Reading a Want to Read book offline means it is now being read
          local started, err = self:_sendStatus(api, filepath, entry, op, user_book, HARDCOVER.STATUS.READING, info)
          if err == "reading_changed" then return false end
          if not hasUserBook(started) then
            return failed(self, filepath, err)
          end
          user_book = started
        end

        local reads = user_book.user_book_reads
        local current_read = op.reread and reads and reads[#reads] or Book:currentRead(reads)
        local server_page = current_read and tonumber(current_read.progress_pages)
        -- A Paused book is still being read: a page on it is progress, not the start of a re-read
        local finished = current == HARDCOVER.STATUS.FINISHED or current == HARDCOVER.STATUS.DNF

        if op.read_id and (not current_read or current_read.id ~= op.read_id or finished or current_read.finished_at) then
          holdChangedReading(self, entry)
          return false
        end

        -- Finished / Did Not Finish with new progress here: this may be a
        -- re-read, which only the user can say. The old read is never touched.
        if finished and not op.reread then
          entry.conflict = { kind = "reread", local_page = op.value, cloud_status = current, cloud_page = server_page, seq = op.seq }
          self:persist()
          return false, "conflict"
        end

        -- The cloud is further along (read on another device). Far ahead: ask.
        -- Slightly ahead: it wins quietly. Never take the server backwards
        -- unless the user said to.
        local skip = false
        if not op.reread and not finished and server_page and server_page > op.value and not op.force then
          -- An earlier daily checkpoint behind the cloud is harmless when a later checkpoint
          -- before the next status reaches it. Only the segment's final position needs a choice.
          local caught_up = false
          for j = i + 1, #ops do
            if ops[j].kind ~= "page" then break end
            if ops[j].value >= server_page then caught_up = true end
          end
          if not caught_up and server_page - op.value >= SyncQueue.CONFLICT_PAGES then
            entry.conflict = { kind = "page", local_page = op.value, cloud_page = server_page, seq = op.seq }
            self:persist()
            return false, "conflict"
          end
          skip = true
        end

        if op.reread and finished then
          -- Hardcover creates the new read as part of this transition.
          local reading, err = self:_sendStatus(api, filepath, entry, op, user_book, HARDCOVER.STATUS.READING, info)
          if err == "reading_changed" then return false end
          if not hasUserBook(reading) then
            return failed(self, filepath, err)
          end
          user_book = reading
          reads = user_book.user_book_reads
          current_read = reads and reads[#reads]
        end

        if not skip then
          if op.reread and not (current_read and current_read.id and not current_read.finished_at) then
            countRejection(self, filepath)
            return false
          end
          local action_at = op.at and op.at > 0 and os.date("!%Y-%m-%dT%H:%M:%SZ", op.at) or nil
          local result
          op.read_id = current_read and current_read.id
          op.page_attempt = true
          self:persist()
          if current_read and current_read.id then
            result = api:updatePage(
              current_read.id,
              current_read.edition_id or edition_id,
              op.value,
              op.start_date or current_read.started_at or op.started_at,
              action_at
            )
          elseif user_book.id then
            result = api:createRead(
              user_book.id,
              edition_id or user_book.edition_id,
              op.value,
              op.start_date or op.started_at or os.date("%Y-%m-%d"),
              action_at
            )
          end
          if not hasUserBook(result) then
            countRejection(self, filepath)
            return false
          end
          user_book = result
          op.read_id = op.read_id or (latestRead(result) and latestRead(result).id)
          op.applied = true
          self:persist()
        end
      end
      local target = latestRead(user_book)
      if (op.start_date or op.finished_date) and op.read_id and (not target or target.id ~= op.read_id) then
        holdChangedReading(self, entry)
        return false
      end
      local dates = {}
      if op.start_date and target and target.started_at ~= op.start_date then
        if target.finished_at or (user_book.status_id ~= HARDCOVER.STATUS.READING
          and user_book.status_id ~= HARDCOVER.STATUS.PAUSED) then
          holdChangedReading(self, entry)
          return false
        end
        dates.started_at = op.start_date
      end
      if op.finished_date and target and target.finished_at ~= op.finished_date then
        if user_book.status_id ~= HARDCOVER.STATUS.FINISHED then
          holdChangedReading(self, entry)
          return false
        end
        dates.finished_at = op.finished_date
      end
      if next(dates) then
        if op.at and op.at > 0 then dates.action_at = os.date("!%Y-%m-%dT%H:%M:%SZ", op.at) end
        local result, err = api:updateReadDates(target.id, dates)
        if not hasUserBook(result) then return failed(self, filepath, err) end
        if result.status_id ~= user_book.status_id then
          holdChangedReading(self, entry)
          return false
        end
        -- The sparse mutation returns only its target read. Keep the full lookup's other reads.
        user_book.status_id = result.status_id
        for _, read in ipairs(result.user_book_reads or {}) do
          if read.id == target.id then
            for field, value in pairs(read) do target[field] = value end
          end
        end
      end
      if op.kind == "status" then statusSent(opts, entry, op.value, user_book) end
      entry.sending_seq = nil
      if self:get(filepath) == entry and not entry.remove then
        entry.user_book_id = user_book.id
        Actions.ack(entry, op.seq)
        if self:isEmpty(entry) then self:_drop(filepath) end
        self:persist()
      end
    end
  end

  if self:isEmpty(self:get(filepath)) then
    if opts.settings and opts.settings.saveBookSnapshot then
      for file in pairs(files) do opts.settings:saveBookSnapshot(file, user_book) end
    end
    if opts.state and opts.current_file and files[opts.current_file] then
      opts.state.book_status = user_book
      opts.state.book_status_fetched = true
    end
  end
  return self:isEmpty(self:get(filepath))
end

-- After this many entries fail back to back for want of an answer, stop: that
-- pattern means the network or the token is down, and every remaining book
-- would just wait out its own timeout.
local MAX_CONSECUTIVE_FAILURES = 2

-- Is this entry for the signed-in account? Entries from older versions carry no user_id and
-- belong to whoever is signed in (as in ShelfQueue).
function SyncQueue.ownedBy(entry, user_id)
  return type(entry) ~= "table" or entry.user_id == nil or tostring(entry.user_id) == tostring(user_id)
end

-- Every queued book's library record in one request instead of one per book.
-- nil (each entry asks for its own) when one lookup is all there is, or the
-- batch could not be asked.
function SyncQueue:_prefetchUserBooks(api, paths, user_id)
  if type(api.findUserBooks) ~= "function" then return nil end
  local ids, seen = {}, {}
  for _, key in ipairs(paths) do
    local entry = self:get(key)
    local book_id = type(entry) == "table" and entry.book_id
    if book_id and not self:isEmpty(entry) and not (entry.remove and entry.user_book_id)
      and not seen[tostring(book_id)] then
      seen[tostring(book_id)] = true
      ids[#ids + 1] = tonumber(book_id) or book_id
    end
  end
  if #ids < 2 then return nil end
  local ok, found = pcall(api.findUserBooks, api, ids, user_id)
  if ok and type(found) == "table" then return found end
  return nil
end

function SyncQueue:flush(api, opts)
  opts = opts or {}
  if self.flushing then
    return false
  end

  -- what was queued under an account that is not signed in any more is dropped, not sent to this one
  if opts.user_id ~= nil then
    local pending, dropped = self:pending(), false
    for filepath, entry in pairs(pending) do
      if not SyncQueue.ownedBy(entry, opts.user_id) then
        pending[filepath] = nil
        dropped = true
      end
    end
    if dropped then self:persist() end
  end

  local paths = {}
  for _, key in ipairs(self:keys()) do
    if not self:isHeld(self:get(key)) then
      paths[#paths + 1] = key
    end
  end
  if #paths == 0 then
    return self:heldCount() == 0
  end

  -- Without a user id every lookup would be sent with a null id
  if opts.user_id == nil then
    return false
  end

  return self:withFlushLock(false, function()
    local all_sent = true
    local consecutive_failures = 0
    local prefetched = self:_prefetchUserBooks(api, paths, opts.user_id)

    for _, filepath in ipairs(paths) do
      -- An API call that throws must not leave `flushing` set, or every later
      -- flush is refused until KOReader restarts.
      self.sending_key = filepath
      local ok, sent, reason = pcall(self._flushEntry, self, api, filepath, opts, prefetched)
      self.sending_key = nil
      if ok and sent then
        consecutive_failures = 0
      else
        all_sent = false
        if not ok or reason == "transient" then
          consecutive_failures = consecutive_failures + 1
          if consecutive_failures >= MAX_CONSECUTIVE_FAILURES then
            break
          end
        else
          consecutive_failures = 0
        end
      end
    end

    return all_sent
  end)
end

return SyncQueue
