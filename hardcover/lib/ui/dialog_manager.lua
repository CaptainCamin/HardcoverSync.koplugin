local _ = require("gettext")
local json = require("json")

local UIManager = require("ui/uimanager")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")

local Api = require("hardcover/lib/hardcover_api")
local Book = require("hardcover/lib/book")
local User = require("hardcover/lib/user")

local HARDCOVER = require("hardcover/lib/constants/hardcover")

local BookDetailDialog = require("hardcover/lib/ui/book_detail_dialog")
local JournalDialog = require("hardcover/lib/ui/journal_dialog")
local SearchDialog = require("hardcover/lib/ui/search_dialog")
local ShelfDialog = require("hardcover/lib/ui/shelf_dialog")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local DialogManager = {}
DialogManager.__index = DialogManager

function DialogManager:new(o)
  return setmetatable(o or {}, self)
end

local function mapJournalData(data)
  local result = {
    book_id = data.book_id,
    event = data.event_type,
    entry = data.text,
    edition_id = data.edition_id,
    privacy_setting_id = data.privacy_setting_id,
    tags = json.util.InitArray({})
  }

  if #data.tags > 0 then
    for _, tag in ipairs(data.tags) do
      table.insert(result.tags, { category = HARDCOVER.CATEGORY.TAG, tag = tag, spoiler = false })
    end
  end
  if #data.hidden_tags > 0 then
    for _, tag in ipairs(data.hidden_tags) do
      table.insert(result.tags, { category = HARDCOVER.CATEGORY.TAG, tag = tag, spoiler = true })
    end
  end

  if data.page then
    result.metadata = {
      position = {
        type = "pages",
        value = data.page,
        possible = data.pages
      }
    }
  end

  return result
end

function DialogManager:buildSearchDialog(title, items, active_item, book_callback, search_callback, search)
  local callback = function(book)
    self.search_dialog:onClose()
    book_callback(book)
  end

  if self.search_dialog then
    self.search_dialog:free()
  end

  self.search_dialog = SearchDialog:new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    items = items,
    active_item = active_item,
    select_book_cb = callback,
    search_callback = search_callback,
    search_value = search
  }

  UIManager:show(self.search_dialog)
end

function DialogManager:confirm(options)
  options.text = options.text or "Are you sure"

  UIManager:show(ConfirmBox:new(options))
end

function DialogManager:maybeConfirm(options)
  local original_callback = options.ok_callback

  local manual_confirm_callback = options.no_confirm_callback
  options.no_confirm_callback = nil

  if self.settings:menuConfirm() then
    options.ok_callback = function()
      original_callback()
      if manual_confirm_callback then
        manual_confirm_callback()
      end
    end

    self:confirm(options)
  else
    original_callback()
  end
end

function DialogManager:buildBookListDialog(title, items, icon_callback, disable_wifi_after)
  if self.search_dialog then
    self.search_dialog:free()
  end

  self.search_dialog = SearchDialog:new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    items = items,
    left_icon_callback = icon_callback,
    left_icon = "cre.render.reload",
    select_book_cb = function(book)
      local clean_title = book.title:gsub("^The ", ""):gsub("^An ", ""):gsub("^A ", ""):gsub(" ?%(%d+%)$", "")

      FileSearcher.search_path = G_reader_settings:readSetting("home_dir")
      FileSearcher.search_string = clean_title
      self.ui.filesearcher.case_sensitive = false
      self.ui.filesearcher.include_subfolders = true
      self.ui.filesearcher.include_metadata = true
      self.ui.filesearcher:doSearch()
    end,
    close_callback = function()
      if disable_wifi_after then
        UIManager:nextTick(function()
          self.wifi:wifiDisablePrompt()
        end)
      end
    end
  }

  UIManager:show(self.search_dialog)
end

--
-- Re-run a search against the dialog already on screen.
--
-- The dialog is shown, so there is nothing to show first here -- but the error
-- path was a silent no-op: it closed the dialog only when Api.enabled was false
-- and otherwise did nothing, leaving stale rows that looked like results. A
-- failure the user cannot see is indistinguishable from a search that worked.
--
function DialogManager:updateSearchResults(search)
  if not self.search_dialog then return end

  local loading = StatusDialogs.loading(_("Searching…"))

  Api:findBooksAsync(search, nil, User:getId(), function(books, err)
    StatusDialogs.close(loading)
    if not UIManager:isWidgetShown(self.search_dialog) then return end

    if err or not books then
      -- Keep the previous rows. Clearing them turns a transient failure into
      -- an empty list, which reads as "no matches" -- a different and wrong
      -- answer to the question the user asked.
      StatusDialogs.error(_("Search failed. Tap the search icon to try again."))
      return
    end

    self.search_dialog:setItems(self.search_dialog.title, books,
                                self.search_dialog.active_item)
    self.search_dialog.search_value = search
  end)
end

function DialogManager:updateRandomBooks(books)
  self.search_dialog:setItems(self.search_dialog.title, books)
end

function DialogManager:journalEntryForm(text, document, page, remote_pages, mapped_page, event_type)
  local settings = self.settings:readBookSettings(document.file) or {}
  local edition_id = settings.edition_id
  local edition_format = settings.edition_format

  mapped_page = mapped_page or self.page_mapper:getMappedPage(page, document:getPageCount(), remote_pages)
  local wifi_was_off = false
  local dialog
  dialog = JournalDialog:new {
    input = text,
    event_type = event_type or "note",
    book_id = settings.book_id,
    edition_id = edition_id,
    edition_format = edition_format,
    page = mapped_page,
    pages = remote_pages,
    save_dialog_callback = function(book_data)
      local api_data = mapJournalData(book_data)
      local result = Api:createJournalEntry(api_data)
      if result then
        UIManager:nextTick(function()
          UIManager:close(dialog)

          if wifi_was_off then
            UIManager:nextTick(function()
              self.wifi:wifiDisablePrompt()
            end)
          end
        end)

        return true, _(event_type .. " saved")
      else
        return false, _(event_type .. " could not be saved")
      end
    end,
    select_edition_callback = function()
      -- TODO: could be moved into child dialog but needs access to build dialog, which needs dialog again
      dialog:onCloseKeyboard()

      local editions = Api:findEditions(self.settings:getLinkedBookId(), User:getId())
      self:buildSearchDialog(
        "Select edition",
        editions,
        { edition_id = dialog.edition_id },
        function(edition)
          if not edition then
            return
          end

          dialog:setEdition(
            edition.edition_id,
            Book:editionFormatName(edition.edition_format, edition.reading_format_id),
            edition.pages
          )
        end
      )
    end,

    close_callback = function()
      if wifi_was_off then
        UIManager:nextTick(function()
          self.wifi:wifiDisablePrompt()
        end)
      end
    end
  }
  -- scroll to the bottom instead of overscroll displayed
  dialog._input_widget:scrollToBottom()

  self.wifi:wifiPrompt(function(wifi_enabled)
    wifi_was_off = wifi_enabled

    UIManager:show(dialog)
    dialog:onShowKeyboard()

    --[[
    Resolve the edition only after the dialog is up. This lookup used to run
    above the dialog's construction, so a book with no linked edition -- which
    is every book the reader has not linked yet -- blocked for the length of a
    request before anything appeared. The dialog is fully usable without it:
    it just does not know which edition the note belongs to yet, and setEdition
    fills that in when the answer lands.

    A failure here is not worth a dialog of its own. The user can still write
    the note and save it; the edition is filled in later, or the note is saved
    against the default by the save path. Reporting it would interrupt a task
    that is otherwise fine.
    ]]
    if not edition_id and settings.book_id then
      Api:findDefaultEditionAsync(settings.book_id, User:getId(), function(edition)
        if not edition then return end
        if not UIManager:isWidgetShown(dialog) then return end
        dialog:setEdition(
          edition.id,
          Book:editionFormatName(edition.edition_format, edition.reading_format_id),
          edition.pages
        )
      end)
    end
  end)
end

--
-- Browse a shelf (Want to Read by default) and open details for a selection.
--
-- Show-then-fetch. The first page used to be fetched here, before the dialog
-- existed, and an error called showError and returned -- so on a device with no
-- route to the API the tap produced no screen at all for up to six seconds
-- (socketutil:set_timeout(6, 12) in hardcover_api.lua), which on e-ink reads as
-- a crashed device. The dialog is now built and shown empty, and the fetch only
-- updates a screen that already exists.
--
-- The user can close the dialog while the request is in flight, so every write
-- below is guarded on isWidgetShown. Updating a freed widget crashes.
--
function DialogManager:showShelf(status_id, title, done_callback)
  local user_id = User:getId()

  if self.shelf_dialog then
    self.shelf_dialog:free()
    self.shelf_dialog = nil
  end

  self.shelf_dialog = ShelfDialog:new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    status_id = status_id,
    -- Empty until the fetch lands. Passing a nil here would reach the API as a
    -- nil offset and silently refetch page one forever.
    entries = {},
    has_more = false,
    offset = 0,
    page_size = 20,
    fetch_page = function(offset, limit, callback)
      Api:getShelfAsync(user_id, status_id, offset, limit, callback)
    end,
    select_entry_cb = function(entry)
      self:showBookDetail(entry.book_id, nil, done_callback)
    end,
    close_callback = function()
      if done_callback then
        done_callback()
      end
    end,
  }

  UIManager:show(self.shelf_dialog)

  local loading = StatusDialogs.loading(_("Loading your shelf…"))

  Api:getShelfAsync(user_id, status_id, 0, self.shelf_dialog.page_size,
    function(entries, err, has_more)
      StatusDialogs.close(loading)
      if not UIManager:isWidgetShown(self.shelf_dialog) then return end

      if err or not entries then
        -- Offer the retry rather than an error the user can only dismiss and
        -- start again. Recursion is safe: it rebuilds the dialog and shows it
        -- again, and the fetch below is the same code.
        StatusDialogs.retry(err or _("no response"), _("Loading your shelf"),
          function()
            self:showShelf(status_id, title, done_callback)
          end,
          function() end)
        return
      end

      if #entries == 0 then
        self.shelf_dialog:setEmptyState(_("No books on this shelf yet"))
        return
      end

      self.shelf_dialog.offset = #entries
      self.shelf_dialog:setEntries(entries, has_more and #entries > 0)
    end)
end

--
-- Fetch and display full details for one book.
--
-- Show-then-fetch, same reason as showShelf: the detail used to be fetched
-- before the dialog existed, so a failure showed an error in place of a screen
-- and an offline tap did nothing at all.
--
function DialogManager:showBookDetail(book_id, edition_id, done_callback)
  local dialog = BookDetailDialog:new {
    detail = nil,
    loading = true,
  }

  UIManager:show(dialog)

  local loading = StatusDialogs.loading(_("Loading book details…"))

  Api:getBookDetailAsync(book_id, User:getId(), edition_id, function(detail)
    StatusDialogs.close(loading)
    if not UIManager:isWidgetShown(dialog) then return end

    if not detail then
      StatusDialogs.retry(_("no response"), _("Loading book details"),
        function()
          UIManager:close(dialog)
          self:showBookDetail(book_id, edition_id, done_callback)
        end,
        function() UIManager:close(dialog) end)
      return
    end

    dialog:setDetail(detail)
    if done_callback then
      done_callback()
    end
  end)

  return dialog
end

function DialogManager:showError(err)
  UIManager:show(InfoMessage:new {
    text = err,
    icon = "notice-warning",
    timeout = 2
  })
end

return DialogManager
