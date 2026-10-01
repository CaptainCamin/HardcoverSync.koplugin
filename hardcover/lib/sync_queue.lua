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
  if not pending then
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

function SyncQueue:isEmpty(entry)
  return not entry or (entry.mapped_page == nil and entry.status_id == nil)
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

function SyncQueue:filepaths()
  local paths = {}
  for filepath, entry in pairs(self:pending()) do
    if not self:isEmpty(entry) then
      table.insert(paths, filepath)
    end
  end
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
  self:persist()
  return entry
end

function SyncQueue:enqueuePage(filepath, payload)
  local entry = self:_ensure(filepath, payload)
  entry.mapped_page = payload.mapped_page
  entry.page_updated_at = os.time()
  self:persist()
  return entry
end

function SyncQueue:enqueueStatus(filepath, payload)
  local entry = self:_ensure(filepath, payload)
  entry.status_id = payload.status_id
  entry.status_updated_at = os.time()
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
      reads[#reads].progress_pages = entry.mapped_page
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
  return user_book and user_book.id ~= nil
end

function SyncQueue:flush(api, opts)
  opts = opts or {}
  if self.flushing then
    return false
  end

  local paths = self:filepaths()
  if #paths == 0 then
    return true
  end

  self.flushing = true

  local user_id = opts.user_id
  local settings = opts.settings
  local current_file = opts.current_file
  local state = opts.state

  for _, filepath in ipairs(paths) do
    local entry = self:get(filepath)
    if not self:isEmpty(entry) then
      local book_id = entry.book_id
      local edition_id = entry.edition_id
      local privacy_setting_id = entry.privacy_setting_id
      local pending_status = entry.status_id
      local flush_page = self:shouldFlushPage(entry)

      local user_book = api:findUserBook(book_id, user_id)
      if not hasUserBook(user_book) then
        local status_to_set = pending_status or HARDCOVER.STATUS.READING
        user_book = api:updateUserBook(book_id, status_to_set, privacy_setting_id, edition_id)
        if not hasUserBook(user_book) then
          self.flushing = false
          return false
        end
        pending_status = nil
        entry.status_id = nil
        self:save(filepath, entry)
      elseif pending_status then
        user_book = api:updateUserBook(
          book_id,
          pending_status,
          privacy_setting_id or user_book.privacy_setting_id,
          edition_id
        )
        if not hasUserBook(user_book) then
          self.flushing = false
          return false
        end
        entry.status_id = nil
        self:save(filepath, entry)
      end

      if flush_page then
        local reads = user_book.user_book_reads
        local current_read = reads and reads[#reads]
        local result
        if current_read and current_read.id then
          result = api:updatePage(
            current_read.id,
            current_read.edition_id or edition_id,
            entry.mapped_page,
            current_read.started_at or entry.started_at
          )
        elseif user_book.id then
          result = api:createRead(
            user_book.id,
            edition_id or user_book.edition_id,
            entry.mapped_page,
            entry.started_at or os.date("%Y-%m-%d")
          )
        end
        if not result then
          self.flushing = false
          return false
        end
        user_book = result
      end

      self:clear(filepath)
      if settings and settings.saveBookSnapshot then
        settings:saveBookSnapshot(filepath, user_book)
      end
      if state and current_file == filepath then
        state.book_status = user_book
        state.book_status_fetched = true
      end
    end
  end

  self.flushing = false
  return true
end

return SyncQueue
