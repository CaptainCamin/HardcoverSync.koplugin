local HARDCOVER = require("hardcover/lib/constants/hardcover")

local OfflineQueue = require("hardcover/lib/offline_queue")

local SyncQueue = OfflineQueue.extend({})
SyncQueue.store_key = "pending"

-- one entry per book file: its queued page and status
function SyncQueue:pending()
  return self:store()
end

-- a malformed entry (a hand edit, a merged settings file) is not something to send
function SyncQueue:valid(entry)
  return not self:isEmpty(entry)
end

function SyncQueue:get(filepath)
  if not filepath then
    return nil
  end
  return self:pending()[filepath]
end

-- A malformed entry (a hand edit, a merged settings file) counts as empty so
-- one bad value cannot make every queue check throw.
function SyncQueue:isEmpty(entry)
  return type(entry) ~= "table" or (entry.mapped_page == nil and entry.status_id == nil)
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

function SyncQueue:filepaths()
  local paths = {}
  for filepath, entry in pairs(self:pending()) do
    if not self:isEmpty(entry) then
      table.insert(paths, filepath)
    end
  end
  -- pairs() order is arbitrary; a stable order keeps flushes reproducible
  table.sort(paths)
  return paths
end

function SyncQueue:pendingCount()
  return #self:filepaths()
end

-- How many changes are waiting, counting a page and a status separately when
-- both are queued for the same book. pendingCount() remains the number of files.
function SyncQueue:changeCount()
  local count = 0
  for _, filepath in ipairs(self:filepaths()) do
    local entry = self:get(filepath)
    if entry.mapped_page ~= nil then count = count + 1 end
    if entry.status_id ~= nil then count = count + 1 end
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
function SyncQueue:_ensure(filepath, meta)
  local pending = self:pending()
  local entry = pending[filepath] or {}
  if meta then
    for key, value in pairs(meta) do
      if value ~= nil then
        entry[key] = value
      end
    end
  end
  entry.updated_at = os.time()
  pending[filepath] = entry
  return entry
end

-- The page the reader had reached at the end of each day, oldest first, so reading over several
-- days offline reaches Hardcover as one dated progress entry per day instead of one entry for
-- the day the connection came back. `entry.page_days` holds { day = "2026-10-23", page, at }; a
-- page on the same local day replaces that day's. The last one is always mapped_page.
SyncQueue.MAX_DAYS = 31

function SyncQueue:_noteDay(entry)
  local days = type(entry.page_days) == "table" and entry.page_days or {}
  local day = os.date("%Y-%m-%d", entry.page_updated_at)
  local last = days[#days]
  if last and last.day == day then
    last.page, last.at = entry.mapped_page, entry.page_updated_at
  else
    days[#days + 1] = { day = day, page = entry.mapped_page, at = entry.page_updated_at }
  end
  while #days > SyncQueue.MAX_DAYS do table.remove(days, 1) end
  entry.page_days = days
end

function SyncQueue:enqueuePage(filepath, payload)
  -- No page to record: keep whatever is already queued rather than erase it
  if payload.mapped_page == nil then
    return self:get(filepath)
  end
  local entry = self:_ensure(filepath, payload)
  entry.mapped_page = payload.mapped_page
  entry.page_updated_at = os.time()
  entry.first_page_date = entry.first_page_date or os.date("%Y-%m-%d")
  self:_noteDay(entry)
  entry.failures = nil
  -- reading on changes the question being asked (and the user's earlier answer)
  entry.conflict = nil
  self:persist()
  return entry
end

-- A page that starts the book again. The flush opens a new read for it (see _flushEntry), so the
-- finished read is never written. Only the page is queued, not a status: a READING status queued
-- ahead of the page would make the page land on the finished read.
function SyncQueue:startReread(filepath, payload)
  local held = self:shelfChangeWaiting(filepath)
  local origin = held and self:get(filepath).from_status_id
  local entry = self:enqueuePage(filepath, payload)
  -- pages queued before the restart belong to the read that finished
  entry.page_days = { entry.page_days[#entry.page_days] }
  entry.reread = true
  entry.from_status_id = origin or payload.from_status_id or 0
  self:persist()
  return entry
end

-- Is a change of the book's shelf (a status, or a re-read) waiting for this file?
function SyncQueue:shelfChangeWaiting(filepath)
  local entry = self:get(filepath)
  return type(entry) == "table" and (entry.status_id ~= nil or entry.reread == true)
end

-- `payload.from_status_id` is the shelf the book was on before the change (nil: on none), kept
-- as `from_status_id` (0 for none) so that cancelling the change can put the saved shelves back.
-- When a change is already waiting, the shelf it started from is kept.
function SyncQueue:enqueueStatus(filepath, payload)
  local held = self:shelfChangeWaiting(filepath)
  local origin = held and self:get(filepath).from_status_id
  local entry = self:_ensure(filepath, payload)
  entry.from_status_id = origin or payload.from_status_id or 0
  entry.status_id = payload.status_id
  entry.status_updated_at = os.time()
  -- The day the book was finished, kept so a sync on a later day does not become the finish date
  entry.finished_date = payload.status_id == HARDCOVER.STATUS.FINISHED and os.date("%Y-%m-%d") or nil
  entry.failures = nil
  self:persist()
  return entry
end

function SyncQueue:save(filepath, entry)
  local pending = self:pending()
  if self:isEmpty(entry) then
    pending[filepath] = nil
  else
    pending[filepath] = entry
  end
  self:persist()
end

--
-- Cancel one waiting change of one book, leaving the others. The entry goes when nothing
-- is left in it. (A page that was waiting for the reader's answer to a question is no
-- longer asked about once it is cancelled.)
--
function SyncQueue:cancelPage(filepath)
  local entry = self:get(filepath)
  if type(entry) ~= "table" then return false end
  entry.mapped_page, entry.page_updated_at, entry.page_days = nil, nil, nil
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
  entry.status_id, entry.status_updated_at, entry.finished_date = nil, nil, nil
  entry.privacy_setting_id, entry.failures = nil, nil
  if not entry.reread then entry.from_status_id = nil end
  self:save(filepath, entry)
  return true
end

function SyncQueue:clear(filepath)
  local pending = self:pending()
  pending[filepath] = nil
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

  if entry.status_id then
    book_status.status_id = entry.status_id
  end
  if entry.privacy_setting_id then
    book_status.privacy_setting_id = entry.privacy_setting_id
  end
  if entry.mapped_page ~= nil then
    local reads = book_status.user_book_reads
    if reads and reads[#reads] then
      -- The server may already be ahead (read on another device): never show
      -- the book as further back than the cloud says.
      local shown = tonumber(reads[#reads].progress_pages)
      -- (unless the reader set this page by hand: that is theirs to move backwards)
      if not shown or shown < entry.mapped_page or entry.force_page then
        reads[#reads].progress_pages = entry.mapped_page
      end
      if entry.edition_id then
        reads[#reads].edition_id = entry.edition_id
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
  for _, filepath in ipairs(self:filepaths()) do
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
    if not (q and q.status_id and q.status_id ~= HARDCOVER.STATUS.READING) then
      local card = {}
      for k, v in pairs(entry) do card[k] = v end
      if q and q.mapped_page ~= nil then
        local shown = tonumber(card.progress_pages)
        if not shown or shown < q.mapped_page or q.force_page then card.progress_pages = q.mapped_page end
      end
      out[#out + 1] = card
    end
  end

  -- books started (or put back to Currently Reading) offline, the newest first
  local fresh = {}
  for id, q in pairs(queued) do
    if (q.status_id == HARDCOVER.STATUS.READING or q.reread) and not have[id] then fresh[#fresh + 1] = { id = id, q = q } end
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
    and ((entry.failures or 0) >= SyncQueue.MAX_REJECTIONS or entry.conflict ~= nil)
end

-- When the cloud is ahead of a queued page by this many pages or more the user
-- is asked which to keep; by less, the cloud quietly wins (a few pages is a
-- re-read of the same stretch, not a different place in the book).
SyncQueue.CONFLICT_PAGES = 5

-- Entries waiting for the user's answer: a list of { filepath, entry }, ordered.
function SyncQueue:conflicts()
  local list = {}
  for _, filepath in ipairs(self:filepaths()) do
    local entry = self:get(filepath)
    if type(entry) == "table" and entry.conflict then
      list[#list + 1] = { filepath = filepath, entry = entry }
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
  local kind = entry.conflict.kind

  if kind == "page" and choice == "cloud" then
    local resume = self.settings:readSetting("resume")
    if type(resume) ~= "table" then
      resume = {}
      self.settings:saveSetting("resume", resume)
    end
    resume[filepath] = entry.conflict.cloud_page
    self.settings:saveSetting("resume", resume)
    entry.mapped_page = nil
    entry.page_updated_at = nil
    entry.page_days = nil
  elseif kind == "page" and choice == "local" then
    entry.force_page = true
  elseif kind == "reread" and choice == "yes" then
    entry.reread = true
  elseif kind == "reread" and choice == "no" then
    entry.mapped_page = nil
    entry.page_updated_at = nil
    entry.page_days = nil
  else
    return false
  end

  entry.conflict = nil
  entry.failures = nil
  if self:isEmpty(entry) then
    self:pending()[filepath] = nil
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
      entry.failures = nil
    end
  end
  self:persist()
end

-- Remove only what was sent. The flush yields to the UI while a request is out,
-- so the entry may have changed meanwhile; a newer page or status stays queued.
function SyncQueue:_clearSent(filepath, sent)
  local entry = self:get(filepath)
  if type(entry) ~= "table" then
    return
  end
  if sent.page ~= nil and entry.mapped_page == sent.page and entry.page_updated_at == sent.page_at then
    entry.mapped_page = nil
    entry.page_updated_at = nil
    entry.page_days = nil
    entry.force_page = nil
    entry.reread = nil
  end
  if sent.status ~= nil and entry.status_id == sent.status and entry.status_updated_at == sent.status_at then
    entry.status_id = nil
    entry.status_updated_at = nil
    entry.finished_date = nil
  end
  if self:isEmpty(entry) then
    self:pending()[filepath] = nil
  end
  self:persist()
end

-- The writes one queued page needs: the days read before the latest page (only those that
-- move the read forward from what Hardcover has), then the latest page itself. Every one carries
-- the time it was read.
function SyncQueue:_pageSteps(entry, op, server_page)
  local steps, above = {}, tonumber(server_page) or 0
  for _, day in ipairs(type(entry.page_days) == "table" and entry.page_days or {}) do
    if type(day) == "table" and (tonumber(day.at) or 0) > 0 and day.at < op.at
      and tonumber(day.page) and day.page > above and day.page < op.value then
      steps[#steps + 1] = { page = day.page, action_at = os.date("!%Y-%m-%dT%H:%M:%SZ", day.at), day = day.day }
      above = day.page
    end
  end
  -- an entry from before the time was kept has none: send the page undated rather than as 1970
  steps[#steps + 1] = { page = op.value, action_at = op.at > 0 and os.date("!%Y-%m-%dT%H:%M:%SZ", op.at) or nil }
  return steps
end

function SyncQueue:_dropDay(filepath, day)
  local entry = self:get(filepath)
  if not (day and type(entry) == "table" and type(entry.page_days) == "table") then return end
  for i, item in ipairs(entry.page_days) do
    if item.day == day then
      table.remove(entry.page_days, i)
      break
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

-- The page and the status are sent in the order they were made, so reading to
-- the last page and then finishing the book lands the same way it would online.
-- When both carry the same second, a page goes first before a status that ends
-- the read and after one that starts it.
local function orderedOps(entry)
  local ops = {}
  if entry.mapped_page ~= nil then
    ops[#ops + 1] = { kind = "page", value = entry.mapped_page, at = entry.page_updated_at or 0 }
  end
  if entry.status_id ~= nil then
    ops[#ops + 1] = {
      kind = "status", value = entry.status_id, at = entry.status_updated_at or 0,
      finished_date = entry.finished_date,
    }
  end
  local status_first = entry.status_id == HARDCOVER.STATUS.READING
      or entry.status_id == HARDCOVER.STATUS.TO_READ
  table.sort(ops, function(a, b)
    if a.at ~= b.at then
      return a.at < b.at
    end
    if a.kind == b.kind then
      return false
    end
    return (a.kind == "status") == status_first
  end)
  return ops
end

-- Sends one file's pending status and page. Returns true when the entry is
-- fully sent, false when it should be kept for another attempt; the second
-- value is "transient" when the server could not be reached or asked, so the
-- caller can tell an outage from a refusal.
function SyncQueue:_flushEntry(api, filepath, opts)
  local entry = self:get(filepath)
  if self:isEmpty(entry) then
    return true
  end

  if entry.book_id == nil then
    countRejection(self, filepath)
    return false
  end

  local book_id = entry.book_id
  local edition_id = entry.edition_id
  local privacy_setting_id = entry.privacy_setting_id

  -- A failed lookup looks like an empty one; an error means we do not know, so
  -- send nothing rather than create a user book over a real one.
  local user_book, lookup_err = api:findUserBook(book_id, opts.user_id)
  if lookup_err ~= nil then
    return false, "transient"
  end

  local ops = orderedOps(entry)
  local sent = {}

  if not hasUserBook(user_book) then
    local first = ops[1]
    local status_to_set = HARDCOVER.STATUS.READING
    if first.kind == "status" then
      status_to_set = first.value
    end
    user_book = api:updateUserBook(book_id, status_to_set, privacy_setting_id, edition_id)
    if not hasUserBook(user_book) then
      countRejection(self, filepath)
      return false
    end
    if first.kind == "status" then
      if first.finished_date then user_book = api:setFinishedDate(user_book, first.finished_date) or user_book end
      sent.status, sent.status_at = first.value, first.at
      table.remove(ops, 1)
      self:_clearSent(filepath, sent)
      sent = {}
    end
  end

  for _, op in ipairs(ops) do
    if op.kind == "status" then
      local result = api:updateUserBookStatus(user_book.id, op.value)
      if not hasUserBook(result) then
        countRejection(self, filepath)
        return false
      end
      user_book = result
      if op.finished_date then user_book = api:setFinishedDate(result, op.finished_date) or result end
      self:_clearSent(filepath, { status = op.value, status_at = op.at })
    else
      local current = user_book.status_id
      if current == HARDCOVER.STATUS.TO_READ then
        -- Reading a Want to Read book offline means it is now being read
        local started = api:updateUserBookStatus(user_book.id, HARDCOVER.STATUS.READING)
        if not hasUserBook(started) then
          countRejection(self, filepath)
          return false
        end
        user_book = started
      end

      local reads = user_book.user_book_reads
      local current_read = reads and reads[#reads]
      local server_page = current_read and tonumber(current_read.progress_pages)
      -- A Paused book is still being read: a page on it is progress, not the start of a re-read
      local finished = current == HARDCOVER.STATUS.FINISHED or current == HARDCOVER.STATUS.DNF

      -- Finished / Did Not Finish with new progress here: this may be a
      -- re-read, which only the user can say. The old read is never touched.
      if finished and not entry.reread then
        entry.conflict = { kind = "reread", local_page = op.value, cloud_status = current, cloud_page = server_page }
        self:persist()
        return false, "conflict"
      end

      -- The cloud is further along (read on another device). Far ahead: ask.
      -- Slightly ahead: it wins quietly. Never take the server backwards
      -- unless the user said to.
      local skip = false
      if not finished and server_page and server_page > op.value and not entry.force_page then
        if server_page - op.value >= SyncQueue.CONFLICT_PAGES then
          entry.conflict = { kind = "page", local_page = op.value, cloud_page = server_page }
          self:persist()
          return false, "conflict"
        end
        skip = true
      end

      if entry.reread and finished then
        -- a new read first, then the book is being read again
        local made = api:createRead(
          user_book.id,
          edition_id or user_book.edition_id,
          op.value,
          entry.first_page_date or os.date("%Y-%m-%d")
        )
        if not hasUserBook(made) then
          countRejection(self, filepath)
          return false
        end
        local reading = api:updateUserBookStatus(made.id, HARDCOVER.STATUS.READING)
        if not hasUserBook(reading) then
          countRejection(self, filepath)
          return false
        end
        user_book = reading
        entry.reread = nil
        skip = true
      end

      if not skip then
        -- Each earlier day goes first, dated when it was read, then the latest page. A day that
        -- is sent leaves the list, so a retry after a failure does not send it twice.
        local steps = self:_pageSteps(entry, op, server_page)
        for _, step in ipairs(steps) do
          local reads_now = user_book.user_book_reads
          current_read = reads_now and reads_now[#reads_now] or current_read
          local result
          if current_read and current_read.id then
            result = api:updatePage(
              current_read.id,
              current_read.edition_id or edition_id,
              step.page,
              current_read.started_at or entry.started_at or entry.first_page_date,
              step.action_at
            )
          elseif user_book.id then
            result = api:createRead(
              user_book.id,
              edition_id or user_book.edition_id,
              step.page,
              entry.started_at or entry.first_page_date or os.date("%Y-%m-%d"),
              step.action_at
            )
          end
          if not hasUserBook(result) then
            countRejection(self, filepath)
            return false
          end
          user_book = result
          self:_dropDay(filepath, step.day)
        end
      end
      self:_clearSent(filepath, { page = op.value, page_at = op.at })
    end
  end

  if self:isEmpty(self:get(filepath)) then
    if opts.settings and opts.settings.saveBookSnapshot then
      opts.settings:saveBookSnapshot(filepath, user_book)
    end
    if opts.state and opts.current_file == filepath then
      opts.state.book_status = user_book
      opts.state.book_status_fetched = true
    end
  end
  return true
end

-- After this many entries fail back to back for want of an answer, stop: that
-- pattern means the network or the token is down, and every remaining book
-- would just wait out its own timeout.
local MAX_CONSECUTIVE_FAILURES = 2

function SyncQueue:flush(api, opts)
  opts = opts or {}
  if self.flushing then
    return false
  end

  local paths = {}
  for _, filepath in ipairs(self:filepaths()) do
    if not self:isHeld(self:get(filepath)) then
      paths[#paths + 1] = filepath
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

    for _, filepath in ipairs(paths) do
      -- An API call that throws must not leave `flushing` set, or every later
      -- flush is refused until KOReader restarts.
      local ok, sent, reason = pcall(self._flushEntry, self, api, filepath, opts)
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
