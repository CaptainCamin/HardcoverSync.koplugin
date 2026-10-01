-- wrapper around hardcover_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")
local util = require("util")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local Book = require("hardcover/lib/book")
local User = require("hardcover/lib/user")

local SETTING = require("hardcover/lib/constants/settings")

local cache = {}

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

function Hardcover:cacheRandomBooks()
  local user_id = User:getId()

  local books, error = Api:getRandomToRead(user_id, 10)
  if error then
    UIManager:show(InfoMessage:new {
      text = _("Error fetching to-read list"),
      icon = "notice-warning",
      timeout = 2
    })
    return
  end

  cache.random_books = books
  return books
end

function Hardcover:showRandomBookDialog()
  self.wifi:wifiPrompt(function(wifi_enabled)
    -- Cache first: a warm list means no request at all, which is the whole
    -- point of keeping it. Only a cold cache goes to the network, and when it
    -- does the dialog is already on screen -- this used to fetch first, so a
    -- cold cache meant the tap did nothing for the length of a request.
    local cached = cache.random_books
    local has_cache = cached and #cached > 0

    local function reload()
      return self:cacheRandomBooks()
    end

    self.dialog_manager:buildBookListDialog(
      _("Suggest a book"),
      has_cache and cached or {},
      function()
        Background.run(function()
          local books = reload()
          if books and #books > 0 then
            self.dialog_manager:updateRandomBooks(books)
          end
        end)
      end,
      wifi_enabled,
      has_cache and nil or function(callback)
        Api:getRandomToReadAsync(User:getId(), 10, function(books, err)
          if books and #books > 0 then
            cache.random_books = books
          end
          callback(books, err)
        end)
      end
    )
  end)
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

  local new_settings = {
    book_id = book.book_id,
    edition_id = book.edition_id,
    edition_format = Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    _delete = delete
  }

  self.settings:updateBookSetting(filename, new_settings)
  self.cache:cacheUserBook()

  if book.book_id and self.state.book_status.id then
    if new_settings.edition_id and new_settings.edition_id ~= self.state.book_status.edition_id then
      -- update edition
      self.state.book_status = Api:updateUserBook(
        new_settings.book_id,
        self.state.book_status.status_id,
        self.state.book_status.privacy_setting_id,
        new_settings.edition_id
      ) or {}
    end
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
