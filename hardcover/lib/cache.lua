local Api = require("hardcover/lib/hardcover_api")
local User = require("hardcover/lib/user")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local NetworkManager = require("ui/network/manager")

local Cache = {}
Cache.__index = Cache

function Cache:new(o)
  return setmetatable(o, self)
end

function Cache:saveSnapshot(filename, user_book)
  if filename then
    self.settings:saveBookSnapshot(filename, user_book)
  end
end

function Cache:hydrateBookStatus(filename)
  filename = filename or self.settings:getFilePath()
  if not filename then
    return false
  end

  local book_status = self.settings:bookStatusFromSnapshot(filename)
  if not book_status then
    local book_id = self.settings:readBookSetting(filename, "book_id")
    if not book_id then
      return false
    end
    book_status = {
      book_id = book_id,
      edition_id = self.settings:readBookSetting(filename, "edition_id"),
      status_id = self.settings:readBookSetting(filename, "status_id"),
      privacy_setting_id = self.settings:readBookSetting(filename, "privacy_setting_id"),
    }
  end

  if self.sync_queue then
    book_status = self.sync_queue:applyPending(filename, book_status)
  end

  self.state.book_status = book_status
  return book_status.id ~= nil or book_status.book_id ~= nil
end

function Cache:applyLocalPage(mapped_page, edition_id, started_at, read_id)
  local book_status = self.state.book_status or {}
  local reads = book_status.user_book_reads
  if reads and reads[#reads] then
    reads[#reads].progress_pages = mapped_page
    if edition_id then
      reads[#reads].edition_id = edition_id
    end
  else
    book_status.user_book_reads = { {
      id = read_id,
      progress_pages = mapped_page,
      edition_id = edition_id or book_status.edition_id,
      started_at = started_at,
    } }
  end
  if not book_status.status_id then
    book_status.status_id = HARDCOVER.STATUS.READING
  end
  self.state.book_status = book_status
end

function Cache:applyLocalStatus(filename, status_id, privacy_setting_id)
  local book_status = self.state.book_status or {}
  book_status.status_id = status_id
  if privacy_setting_id then
    book_status.privacy_setting_id = privacy_setting_id
  end
  if not book_status.book_id then
    book_status.book_id = self.settings:readBookSetting(filename, "book_id")
  end
  if not book_status.edition_id then
    book_status.edition_id = self.settings:readBookSetting(filename, "edition_id")
  end
  self.state.book_status = book_status
end

function Cache:queueMeta(filename)
  local book_status = self.state.book_status or {}
  local reads = book_status.user_book_reads
  local current_read = reads and reads[#reads]
  return {
    title = self.settings:readBookSetting(filename, "title"),
    book_id = book_status.book_id or self.settings:readBookSetting(filename, "book_id"),
    edition_id = (current_read and current_read.edition_id)
      or book_status.edition_id
      or self.settings:readBookSetting(filename, "edition_id"),
    user_book_id = book_status.id,
    read_id = current_read and current_read.id,
    started_at = current_read and current_read.started_at,
    privacy_setting_id = book_status.privacy_setting_id
      or self.settings:readBookSetting(filename, "privacy_setting_id"),
  }
end

function Cache:syncPage(filename, mapped_page)
  local book_status = self.state.book_status or {}
  local reads = book_status.user_book_reads
  local current_read = reads and reads[#reads]
  local edition_id = (current_read and current_read.edition_id) or book_status.edition_id
    or self.settings:readBookSetting(filename, "edition_id")
  local started_at = current_read and current_read.started_at

  self:applyLocalPage(mapped_page, edition_id, started_at, current_read and current_read.id)

  local enqueue = function()
    local payload = self:queueMeta(filename)
    payload.mapped_page = mapped_page
    self.sync_queue:enqueuePage(filename, payload)
    return { queued = true }
  end

  if not NetworkManager:isConnected() then
    return enqueue()
  end

  local result
  if current_read and current_read.id then
    result = Api:updatePage(current_read.id, edition_id, mapped_page, started_at)
  elseif book_status.id then
    result = Api:createRead(book_status.id, edition_id, mapped_page, started_at or os.date("%Y-%m-%d"))
  end

  if result then
    self.state.book_status = result
    self.state.book_status_fetched = true
    self:saveSnapshot(filename, result)
    if self.sync_queue then
      local entry = self.sync_queue:get(filename)
      if entry then
        entry.mapped_page = nil
        self.sync_queue:save(filename, entry)
      end
    end
    return result
  end

  return enqueue()
end

-- Keep a page the reader set by hand: shown at once, and sent when there is a connection.
-- `edition_page` is the page of the edition. A page typed in is the reader's own say, so
-- it is sent even if the cloud is further along (the sync would otherwise ask, or skip it).
function Cache:queuePage(filename, edition_page)
  local book_status = self.state.book_status or {}
  local reads = book_status.user_book_reads
  local current_read = reads and reads[#reads]
  local edition_id = (current_read and current_read.edition_id) or book_status.edition_id
    or self.settings:readBookSetting(filename, "edition_id")

  self:applyLocalPage(edition_page, edition_id, current_read and current_read.started_at, current_read and current_read.id)

  local payload = self:queueMeta(filename)
  payload.mapped_page = edition_page
  local entry = self.sync_queue:enqueuePage(filename, payload)
  if type(entry) == "table" then
    entry.force_page = true
    self.sync_queue:save(filename, entry)
  end
  return entry
end

function Cache:updateBookStatus(filename, status, privacy_setting_id)
  local settings = self.settings:readBookSettings(filename) or {}
  local book_id = settings.book_id
  local edition_id = settings.edition_id

  if not privacy_setting_id then
    privacy_setting_id = self.state.book_status and self.state.book_status.privacy_setting_id
      or settings.privacy_setting_id
  end

  self:applyLocalStatus(filename, status, privacy_setting_id)

  local enqueue = function()
    local payload = self:queueMeta(filename)
    payload.status_id = status
    payload.privacy_setting_id = privacy_setting_id
    self.sync_queue:enqueueStatus(filename, payload)
    return { queued = true }
  end

  if not NetworkManager:isConnected() then
    return enqueue()
  end

  local result = Api:updateUserBook(book_id, status, privacy_setting_id, edition_id)
  if result then
    self.state.book_status = result
    self.state.book_status_fetched = true
    self:saveSnapshot(filename, result)
    if self.sync_queue then
      local entry = self.sync_queue:get(filename)
      if entry then
        entry.status_id = nil
        self.sync_queue:save(filename, entry)
      end
    end
    return result
  end

  return enqueue()
end

function Cache:cacheUserBook()
  local file = self.settings:getFilePath()
  local status, errors = Api:findUserBook(self.settings:getLinkedBookId(), User:getId())
  if status and status.id then
    self.state.book_status = status
    self.state.book_status_fetched = true
    if file then
      self:saveSnapshot(file, status)
      if self.sync_queue then
        self.sync_queue:applyPending(file, self.state.book_status)
      end
    end
    return nil
  end

  if file then
    self:hydrateBookStatus(file)
  else
    self.state.book_status = status or {}
  end

  return errors
end

return Cache
