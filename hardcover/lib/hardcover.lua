-- wrapper around hardcover_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")
local util = require("util")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local Book = require("hardcover/lib/book")
local User = require("hardcover/lib/user")

local SETTING = require("hardcover/lib/constants/settings")

local Hardcover = {}
Hardcover.__index = Hardcover

function Hardcover:new(o)
  return setmetatable(o, self)
end

function Hardcover:showLinkBookDialog(force_search, link_callback)
  -- Show first, then look the book up.
  --
  -- findBookOptions resolves identifiers and falls back to a title search, which
  -- is two round trips before anything appeared. Tapping "Link book" on a
  -- disconnected device therefore did nothing for up to six seconds per
  -- request -- and on e-ink that is indistinguishable from a crashed device.
  --
  -- The dialog opens with the title/author of the book already open, so there is
  -- something meaningful on screen immediately, and the results replace it.
  local prefill = self.ui.document and self.ui.document:getProps() or {}
  local search_value = prefill.title

  self.dialog_manager:buildLoadingSearchDialog(
    _("Select book"),
    function(callback)
      -- Two lookups (identifiers, then a title search) in the background, so the
      -- dialog that is already on screen stays alive while they run.
      Background.run(function()
        -- findBookOptions returns (title, books, err); the dialog wants
        -- (books, err).
        local ok, resolved_title, books, err = pcall(self.findBookOptions, self, force_search)
        UIManager:nextTick(function()
          if not ok then
            callback(nil, tostring(resolved_title))
            return
          end
          search_value = search_value or resolved_title
          callback(books, err)
        end)
      end)
    end,
    {
      book_id = self.settings:getLinkedBookId()
    },
    function(book)
      Background.run(function()
        self:linkBook(book)
        if link_callback then link_callback(book) end
      end)
    end,
    -- Without this the dialog cannot be searched from, and the initial lookup
    -- returns nothing often enough -- a thin metadata record, an edition with
    -- no ISBN -- that the dialog would be unusable without it.
    function(search)
      self.dialog_manager:updateSearchResults(search)
      return true
    end,
    search_value
  )
end

function Hardcover:updateCurrentBookStatus(status, privacy_setting_id)
  Background.run(function()
    self.cache:updateBookStatus(self.ui.document.file, status, privacy_setting_id)
    if not self.state.book_status.id then
      self.dialog_manager:showError("Book status could not be updated")
    end
  end)
end

function Hardcover:changeBookVisibility(visibility)
  Background.run(function()
    self.cache:cacheUserBook()

    if self.state.book_status.id then
      self:updateCurrentBookStatus(self.state.book_status.status_id, visibility)
    end
  end)
end

function Hardcover:linkBook(book)
  local filename = self.ui.document.file

  local delete = {}
  local clear_keys = { "book_id", "edition_id", "edition_format", "pages", "title" }
  for _, key in ipairs(clear_keys) do
    if book[key] == nil then
      table.insert(delete, key)
    end
  end

  -- a link chosen here is not a bulk-link guess any more
  table.insert(delete, "guessed_book_id")

  local new_settings = {
    book_id = book.book_id,
    edition_id = book.edition_id,
    edition_format = Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    _delete = delete
  }

  -- Linking to a different book: nothing of the old book's identity (user
  -- book, read, status, queued progress) may be used for the new one. Without
  -- this its page updates land on the old book's read.
  local previous = self.settings:readBookSetting(filename, "book_id")
  local old_edition = self.settings:readBookSetting(filename, "edition_id")
  local old_pages = self.settings:pages()
  if previous ~= book.book_id then
    self.settings:clearBookSnapshot(filename)
    if self.cache.sync_queue then
      self.cache.sync_queue:clear(filename)
    end
    self.state.book_status = {}
  end

  -- The same book with another edition: the server is asked first, when the book is on the
  -- user's shelf, so a failure leaves the link as it was.
  local changing = book.book_id and previous == book.book_id and new_settings.edition_id
    and new_settings.edition_id ~= old_edition
  if changing and not self:moveEdition(filename, book, new_settings.edition_id, old_pages) then
    UIManager:show(Notification:new {
      text = _("The edition could not be changed. Check your connection and try again."),
    })
    return false
  end

  self.settings:updateBookSetting(filename, new_settings)
  self.cache:cacheUserBook()

  return true
end

-- A position in a book is a share of its pages, so the same place in another edition is the
-- same share of that edition's pages: page 120 of 300 is page 160 of 400.
local function movedPage(page, old_pages, new_pages)
  if not (page and old_pages and new_pages and old_pages > 0 and new_pages > 0) then
    return page
  end
  return math.min(math.max(1, math.floor(page * new_pages / old_pages + 0.5)), new_pages)
end

-- Moves the book to another edition. A shelved book is moved on Hardcover first: the edition is on
-- the shelf entry and on the current read, and the read's progress is in the old edition's pages,
-- so the read moves first, with its progress. Returns false, having changed nothing on this device,
-- when Hardcover does not answer; trying again is then safe, because it works from what was saved.
-- Whether shelved or not, a queued page is in the old edition's pages, so it moves too.
function Hardcover:moveEdition(filename, book, edition_id, old_pages)
  local status = self.state.book_status
  if status.id then
    local reads = status.user_book_reads
    local read = reads and reads[#reads]

    local moved_read
    if read and read.id then
      moved_read = Api:updatePage(read.id, edition_id, movedPage(read.progress_pages, old_pages, book.pages), read.started_at)
      if not (moved_read and moved_read.id) then
        return false
      end
    end

    local user_book = Api:updateUserBook(book.book_id, status.status_id, status.privacy_setting_id, edition_id)
    if not (user_book and user_book.id) then
      return false
    end

    for key, value in pairs(user_book) do
      status[key] = value
    end
    if moved_read and status.user_book_reads and #status.user_book_reads > 0 then
      status.user_book_reads[#status.user_book_reads] = moved_read
    end
    self.cache:saveSnapshot(filename, status)
  end

  local queue = self.cache.sync_queue
  local entry = queue and queue:get(filename)
  if entry then
    entry.mapped_page = movedPage(entry.mapped_page, old_pages, book.pages)
    entry.edition_id = edition_id
    queue:save(filename, entry)
  end

  return true
end

-- could be moved to book search model
function Hardcover:findBookOptions(force_search)
  local props = self.ui.document:getProps()
  local identifiers = Book:parseIdentifiers(props.identifiers)
  local user_id = User:getId()

  if not force_search then
    local book_lookup = Api:findBookByIdentifiers(identifiers, user_id)
    if book_lookup then
      return nil, { book_lookup }
    end
  end

  local title = props.title
  if not title or title == "" then
    local _dir, path = util.splitFilePathName(self.ui.document.file)
    local filename, _suffix = util.splitFileNameSuffix(path)

    title = filename:gsub("_", " ")
  end
  local result, err = Api:findBooks(title, props.authors, user_id)
  return title, result, err
end

function Hardcover:autolinkBook(book)
  if not book then
    return
  end

  local linked = self:linkBook(book)
  if linked then
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end
end

function Hardcover:linkBookByIsbn(identifiers)
  if identifiers.isbn_10 or identifiers.isbn_13 then
    local user_id = User:getId()
    local book_lookup = Api:findBookByIdentifiers({
      isbn_10 = identifiers.isbn_10,
      isbn_13 = identifiers.isbn_13
    },
      user_id
    )
    if book_lookup then
      self:autolinkBook(book_lookup)
      return true
    end
  end
end

function Hardcover:linkBookByHardcover(identifiers)
  if identifiers.book_slug or identifiers.edition_id then
    local user_id = User:getId()
    local book_lookup = Api:findBookByIdentifiers(
      { book_slug = identifiers.book_slug, edition_id = identifiers.edition_id }, user_id)
    if book_lookup then
      self:autolinkBook(book_lookup)
      return true
    end
  end
end

function Hardcover:linkBookByTitle()
  local props = self.ui.document:getProps()

  local results = Api:findBooks(props.title, props.authors, User:getId())
  if results and #results > 0 then
    self:autolinkBook(results[1])
    return true
  end
end

function Hardcover:tryAutolink()
  if self.settings:bookLinked() then
    return
  end

  local props = self.ui.document:getProps()

  local identifiers = Book:parseIdentifiers(props.identifiers)
  if ((identifiers.isbn_10 or identifiers.isbn_13) and self.settings:readSetting(SETTING.LINK_BY_ISBN))
    or ((identifiers.book_slug or identifiers.edition_id) and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER))
    or (props.title and self.settings:readSetting(SETTING.LINK_BY_TITLE)) then
    self.wifi:withWifi(function()
      Background.run(function()
        self:_runAutolink(identifiers)
      end)
    end)
  end
end

function Hardcover:_runAutolink(identifiers)
  local linked = false
  if self.settings:readSetting(SETTING.LINK_BY_ISBN) then
    linked = self:linkBookByIsbn(identifiers)
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) then
    linked = self:linkBookByHardcover(identifiers)
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_TITLE) then
    self:linkBookByTitle()
  end
end

return Hardcover
