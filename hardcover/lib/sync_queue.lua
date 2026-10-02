local HARDCOVER = require("hardcover/lib/constants/hardcover")

local SyncQueue = {}
SyncQueue.__index = SyncQueue

function SyncQueue:new(o)
  o = o or {}
  setmetatable(o, self)
  o.flushing = false
  return o
end

function SyncQueue:pending()
  local pending = self.settings:readSetting("pending")
  if type(pending) ~= "table" then
    pending = {}
    self.settings:saveSetting("pending", pending)
  end
  return pending
end

function SyncQueue:persist()
  if self.settings.flush then
    self.settings:flush()
  end
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

function SyncQueue:enqueuePage(filepath, payload)
  -- No page to record: keep whatever is already queued rather than erase it
  if payload.mapped_page == nil then
    return self:get(filepath)
  end
  local entry = self:_ensure(filepath, payload)
  entry.mapped_page = payload.mapped_page
  entry.page_updated_at = os.time()
  entry.first_page_date = entry.first_page_date or os.date("%Y-%m-%d")
  entry.failures = nil
  self:persist()
  return entry
end

function SyncQueue:enqueueStatus(filepath, payload)
  local entry = self:_ensure(filepath, payload)
  entry.status_id = payload.status_id
  entry.status_updated_at = os.time()
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
      if not shown or shown < entry.mapped_page then
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

local function hasUserBook(user_book)
  return type(user_book) == "table" and user_book.id ~= nil
end

-- An entry the server answered for but refused this many flushes in a row is
-- held: it stays queued (the user can retry or discard it) but no longer
-- takes a turn, so one dead book cannot starve the rest.
SyncQueue.MAX_REJECTIONS = 3

function SyncQueue:isHeld(entry)
  return type(entry) == "table" and (entry.failures or 0) >= SyncQueue.MAX_REJECTIONS
end

function SyncQueue:heldCount()
  local n = 0
  for _, entry in pairs(self:pending()) do
    if not self:isEmpty(entry) and self:isHeld(entry) then
      n = n + 1
    end
  end
  return n
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
  end
  if sent.status ~= nil and entry.status_id == sent.status and entry.status_updated_at == sent.status_at then
    entry.status_id = nil
    entry.status_updated_at = nil
  end
  if self:isEmpty(entry) then
    self:pending()[filepath] = nil
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
    ops[#ops + 1] = { kind = "status", value = entry.status_id, at = entry.status_updated_at or 0 }
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
      sent.status, sent.status_at = first.value, first.at
      table.remove(ops, 1)
      self:_clearSent(filepath, sent)
      sent = {}
    end
  end

  for _, op in ipairs(ops) do
    if op.kind == "status" then
      local result = api:updateUserBook(
        book_id,
        op.value,
        privacy_setting_id or user_book.privacy_setting_id,
        edition_id
      )
      if not hasUserBook(result) then
        countRejection(self, filepath)
        return false
      end
      user_book = result
      self:_clearSent(filepath, { status = op.value, status_at = op.at })
    else
      local current = user_book.status_id
      if current == HARDCOVER.STATUS.TO_READ then
        -- Reading a Want to Read book offline means it is now being read
        local started = api:updateUserBook(
          book_id,
          HARDCOVER.STATUS.READING,
          privacy_setting_id or user_book.privacy_setting_id,
          edition_id
        )
        if not hasUserBook(started) then
          countRejection(self, filepath)
          return false
        end
        user_book = started
      end

      local reads = user_book.user_book_reads
      local current_read = reads and reads[#reads]
      local server_page = current_read and tonumber(current_read.progress_pages)

      -- Finished / Did Not Finish: do not quietly reopen it from a stale queue.
      -- And never take the server backwards: if it is already further along,
      -- the queued page is older news. Either way the page is dropped.
      local skip = (current and current ~= HARDCOVER.STATUS.READING and current ~= HARDCOVER.STATUS.TO_READ)
        or (server_page and server_page > op.value)

      if not skip then
        local result
        if current_read and current_read.id then
          result = api:updatePage(
            current_read.id,
            current_read.edition_id or edition_id,
            op.value,
            current_read.started_at or entry.started_at or entry.first_page_date
          )
        elseif user_book.id then
          result = api:createRead(
            user_book.id,
            edition_id or user_book.edition_id,
            op.value,
            entry.started_at or entry.first_page_date or os.date("%Y-%m-%d")
          )
        end
        if not hasUserBook(result) then
          countRejection(self, filepath)
          return false
        end
        user_book = result
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

  -- Without a user id every lookup would be sent with a null id
  if opts.user_id == nil then
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

  self.flushing = true

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

  self.flushing = false
  return all_sent
end

return SyncQueue
