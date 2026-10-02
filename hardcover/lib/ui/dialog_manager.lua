local _ = require("gettext")
local json = require("json")

local UIManager = require("ui/uimanager")
local NetworkManager = require("ui/network/manager")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local Book = require("hardcover/lib/book")
local Home = require("hardcover/lib/home")
local Shelf = require("hardcover/lib/shelf")
local User = require("hardcover/lib/user")

local HARDCOVER = require("hardcover/lib/constants/hardcover")

local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

-- The book detail, journal, search and shelf dialogs are required where they
-- are first shown, not here. They pull in the vendored ListMenu and CoverMenu
-- (about 1,500 lines) and KOReader loads this plugin on every start, so
-- loading them eagerly cost startup time for screens most sessions never open.

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

-- Tear down a dialog that is about to be replaced.
--
-- free() alone is not enough: a dialog that is still on KOReader's window stack
-- stays there, freed, underneath its replacement. Closing the replacement then
-- reveals the dead one -- a menu that was closed but is still on screen. The
-- retry paths hit this: the failed dialog is still showing when "Retry" builds
-- its successor. close() rather than onClose(), so the dialog's close_callback
-- (which can prompt to turn wifi off) is not fired for a replacement.
local function discard(dialog)
  if not dialog then return end
  if UIManager:isWidgetShown(dialog) then
    UIManager:close(dialog)
  end
  dialog:free()
end

function DialogManager:buildSearchDialog(title, items, active_item, book_callback, search_callback, search)
  local callback = function(book)
    self.search_dialog:onClose()
    book_callback(book)
  end

  discard(self.search_dialog)

  self.search_dialog = require("hardcover/lib/ui/search_dialog"):new {
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

--
-- Show a book list whose contents arrive after the dialog opens.
--
-- The pattern for every "pick something from a list" screen. The alternative --
-- fetch, then build the dialog -- means the tap produces no screen at all while
-- the request is in flight, which is the dead-tap bug this module exists to
-- remove. "Change edition" did exactly that.
--
-- fetch is called with a callback and must invoke it with (items, err). The
-- dialog is on screen before fetch runs, and a failure becomes a retry rather
-- than a blank list the user cannot tell from "no editions exist".
--
-- search_callback, when given, puts a magnifying glass in the title bar that
-- re-runs a query in place. It is not optional in practice: the link-book
-- dialog is useless without it, since the initial lookup can easily return
-- nothing for an edition with a thin metadata record.
--
function DialogManager:buildLoadingSearchDialog(title, fetch, active_item, book_callback, search_callback, search_value)
  discard(self.search_dialog)
  self.search_dialog = nil

  self.search_dialog = require("hardcover/lib/ui/search_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    items = {},
    active_item = active_item,
    loading = true,
    select_book_cb = function(book)
      self.search_dialog:onClose()
      book_callback(book)
    end,
    search_callback = search_callback,
    search_value = search_value,
  }

  UIManager:show(self.search_dialog)

  local loading = StatusDialogs.loading(_("Loading…"))

  fetch(function(items, err)
    StatusDialogs.close(loading)
    if not UIManager:isWidgetShown(self.search_dialog) then return end

    if err or not items then
      StatusDialogs.retry(err or _("no response"), _("Loading the list"),
        function()
          self:buildLoadingSearchDialog(title, fetch, active_item, book_callback,
                                        search_callback, search_value)
        end,
        function() end)
      return
    end

    if #items == 0 then
      self.search_dialog:setEmptyState(_("Nothing to choose from"))
      return
    end

    self.search_dialog:setItems(title, items, active_item)
  end)
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

function DialogManager:journalEntryForm(text, document, page, remote_pages, mapped_page, event_type)
  local settings = self.settings:readBookSettings(document.file) or {}
  local edition_id = settings.edition_id
  local edition_format = settings.edition_format

  mapped_page = mapped_page or self.page_mapper:getMappedPage(page, document:getPageCount(), remote_pages)
  local wifi_was_off = false
  local dialog
  dialog = require("hardcover/lib/ui/journal_dialog"):new {
    input = text,
    event_type = event_type or "note",
    book_id = settings.book_id,
    edition_id = edition_id,
    edition_format = edition_format,
    page = mapped_page,
    pages = remote_pages,
    save_dialog_callback = function(book_data)
      local api_data = mapJournalData(book_data)

      -- This runs inside InputDialog's save handler, which wants the outcome as
      -- a return value, so the request cannot be moved to the background without
      -- reimplementing that handler. It blocks, so put a message on screen and
      -- paint it first: otherwise the dialog just sits there for the length of
      -- the request with no sign the tap was received.
      local saving = StatusDialogs.loading(_("Saving…"))
      UIManager:forceRePaint()
      local result = Api:createJournalEntry(api_data)
      StatusDialogs.close(saving)

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
      dialog:onCloseKeyboard()

      --[[
      Opens the edition picker on top of this dialog, so this is a re-entrant
      call: buildLoadingSearchDialog assigns self.search_dialog while a journal
      dialog is already up. That is safe because the two are different slots and
      different widget classes -- the journal dialog is a local, not a field --
      but it is why this cannot simply be moved into JournalDialog: the child
      would need the manager to build its own replacement, and the manager needs
      the child to know what to fill in.

      Show-then-fetch like every other list here. The fetch used to run inline,
      so tapping "change edition" froze for the length of a request.
      ]]
      self:buildLoadingSearchDialog(
        _("Select edition"),
        function(callback)
          Api:findEditionsAsync(self.settings:getLinkedBookId(), User:getId(), callback)
        end,
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
--
-- The home screen: your shelves with their counts.
--
-- Shown at once from whatever counts were saved (so offline it still opens, with
-- the last numbers), then refreshed in the background. Choosing a shelf opens it
-- on top, so closing the shelf comes back here.
--
-- The plugin's settings, on top of whatever is showing.
function DialogManager:showSettings()
  require("hardcover/lib/ui/settings_dialog").show {
    items = self.settings_items and self.settings_items() or {},
  }
end

function DialogManager:showHome(done_callback)
  local user_id = User:getId()
  local cache = self.shelf_cache
  local ids = Home.statusIds()

  discard(self.home_dialog)
  self.home_dialog = nil

  local saved_counts = cache and cache:counts(user_id, ids) or {}
  local saved_reading = cache and cache:reading(user_id) or {}

  local dialog = require("hardcover/lib/ui/home_dialog"):new {
    rows = Home.rows(saved_counts),
    entries = saved_reading,
    select_cb = function(row)
      self:showShelf(row.status_id, row.title)
    end,
    open_book_cb = function(book_id)
      self:showBookDetail(book_id)
    end,
    settings_cb = function()
      self:showSettings()
    end,
    close_callback = function()
      if done_callback then done_callback() end
    end,
  }
  self.home_dialog = dialog

  UIManager:show(dialog)

  if not NetworkManager:isConnected() then
    return
  end

  -- Two requests, one after the other, each independent of the other's outcome.
  Background.run(function()
    local counts = Api:getShelfCounts(user_id, ids)

    -- failed or cancelled: the saved numbers are still on screen, leave them
    if counts and UIManager:isWidgetShown(dialog) then
      if cache then
        cache:putCounts(user_id, counts)
      end
      -- a refresh that changed nothing repaints nothing
      if not Home.sameCounts(counts, saved_counts, ids) then
        dialog:setRows(Home.rows(counts))
      end
    end

    if not UIManager:isWidgetShown(dialog) then
      return
    end

    local entries = Api:getCurrentlyReading(user_id, 5)
    if not entries or not UIManager:isWidgetShown(dialog) then
      return
    end

    if cache then
      cache:putReading(user_id, entries)
    end
    if not Home.sameCards(entries, saved_reading) then
      dialog:setReading(entries)
    end
  end)
end

-- How many books each request asks for. The loop below keeps asking until a page
-- comes back empty rather than until one comes back short, so a server that
-- returns fewer than requested still yields the whole shelf.
local SHELF_PAGE_SIZE = 50

-- A tap cancels a request in flight (KOReader's rule for a dismissable
-- subprocess). Loading a long shelf takes several requests, and the reader will
-- tap while it runs, so a cancelled page is asked for again this many times
-- before the load gives up.
local SHELF_PAGE_RETRIES = 3

-- A shelf this long is not being loaded to be read; stop rather than loop.
local SHELF_MAX_PAGES = 200

function DialogManager:showShelf(status_id, title, done_callback)
  local user_id = User:getId()
  local cache = self.shelf_cache

  discard(self.shelf_dialog)
  self.shelf_dialog = nil

  -- The whole list as it was last loaded, if it ever was. Shown at once, so the
  -- shelf is there before (or without) the network; the load below then
  -- refreshes it.
  local cached = cache and cache:get(user_id, status_id)

  local dialog = require("hardcover/lib/ui/shelf_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    status_id = status_id,
    -- Empty until the load lands. Passing a nil here would reach the API as a
    -- nil offset and silently refetch page one forever.
    entries = {},
    has_more = false,
    offset = 0,
    page_size = SHELF_PAGE_SIZE,
    -- Only used by the reload icon, which is shown when a load was interrupted
    -- and the shelf is not complete: it carries on from where the list stops.
    fetch_page = function(offset, limit, callback)
      if not NetworkManager:isConnected() then
        callback(nil, _("not available offline"))
        return
      end
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
  self.shelf_dialog = dialog

  UIManager:show(dialog)

  if cached and #cached.entries > 0 then
    dialog.offset = #cached.entries
    dialog:setEntries(cached.entries, not cached.complete)
  end

  -- Offline there is nothing to wait for: say what is being shown and stop.
  if not NetworkManager:isConnected() then
    if cached then
      StatusDialogs.info(string.format(_("Offline: showing your list as it was on %s"),
        os.date("%Y-%m-%d", cached.saved_at or os.time())))
    else
      StatusDialogs.retry(_("no internet connection"), _("Loading your shelf"),
        function() self:showShelf(status_id, title, done_callback) end,
        function() end)
    end
    return
  end

  -- With a saved list already on screen the refresh is quiet; without one the
  -- reader is waiting on it, so say so.
  local loading = not cached and StatusDialogs.loading(_("Loading your shelf…")) or nil

  -- Load the whole shelf, a page at a time, in the background. Rows appear as
  -- they arrive when there is nothing saved to show; with a saved list on
  -- screen the fresh one replaces it once it is complete, so the list never
  -- shrinks to its first page while it refreshes.
  Background.run(function()
    local fresh, seen = {}, {}
    local offset, retries, pages = 0, 0, 0
    local complete, failure = false, nil

    local function stopLoading()
      if loading then
        StatusDialogs.close(loading)
        loading = nil
      end
    end

    while true do
      -- closed while loading: nothing left to update
      if not UIManager:isWidgetShown(dialog) then
        stopLoading()
        return
      end

      if not NetworkManager:isConnected() then
        failure = _("no internet connection")
        break
      end

      local entries, err = Api:getShelf(user_id, status_id, offset, SHELF_PAGE_SIZE)

      if not UIManager:isWidgetShown(dialog) then
        stopLoading()
        return
      end

      if entries == nil then
        if type(err) == "table" and err.completed == false and retries < SHELF_PAGE_RETRIES then
          retries = retries + 1
        else
          failure = err
          break
        end
      else
        retries = 0
        pages = pages + 1
        offset = offset + #entries

        for _, entry in ipairs(entries) do
          -- the shelf can change while it loads, shifting later rows into
          -- earlier pages; do not show a book twice
          local id = entry.user_book_id or entry.book_id
          if id == nil or not seen[id] then
            if id ~= nil then seen[id] = true end
            fresh[#fresh + 1] = entry
          end
        end

        if #entries == 0 then
          complete = true
          break
        end

        stopLoading()
        if not cached then
          dialog.offset = #fresh
          dialog:setEntries(fresh, true, true)
        end

        if pages >= SHELF_MAX_PAGES then
          break
        end
      end
    end

    stopLoading()
    if not UIManager:isWidgetShown(dialog) then return end

    if complete then
      if cache then
        cache:put(user_id, status_id, fresh, true)
      end
      if #fresh == 0 then
        dialog:setEmptyState(_("No books on this shelf yet"))
      else
        dialog.offset = #fresh
        dialog:setEntries(fresh, false, true)
      end
      return
    end

    -- Interrupted. A saved list is still right there, and failing to refresh it
    -- is not worth interrupting for.
    if cached then return end

    if #fresh > 0 then
      -- Keep what arrived. The reload icon stays so the reader can carry on.
      if cache then
        cache:put(user_id, status_id, fresh, false)
      end
      return
    end

    -- Nothing arrived and nothing was saved: offer the retry rather than an
    -- error the reader can only dismiss and start again.
    StatusDialogs.retry(failure, _("Loading your shelf"),
      function()
        self:showShelf(status_id, title, done_callback)
      end,
      function() end)
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
  local dialog = require("hardcover/lib/ui/book_detail_dialog"):new {
    detail = nil,
    loading = true,
  }

  UIManager:show(dialog)

  local user_id = User:getId()
  local saved = self.shelf_cache and self.shelf_cache:findEntry(user_id, book_id)

  -- What a shelf row already knows, shown when the network cannot supply the
  -- full record. Book level only: edition fields are not on a shelf row.
  local function showSaved()
    dialog:setDetail(Shelf.detailFromEntry(saved))
    StatusDialogs.info(_("Offline: showing saved details"))
    if done_callback then
      done_callback()
    end
  end

  if not NetworkManager:isConnected() then
    if saved then
      showSaved()
    else
      StatusDialogs.retry(_("no internet connection"), _("Loading book details"),
        function()
          UIManager:close(dialog)
          self:showBookDetail(book_id, edition_id, done_callback)
        end,
        function() UIManager:close(dialog) end)
    end
    return dialog
  end

  local loading = StatusDialogs.loading(_("Loading book details…"))

  Api:getBookDetailAsync(book_id, user_id, edition_id, function(detail)
    StatusDialogs.close(loading)
    if not UIManager:isWidgetShown(dialog) then return end

    if not detail then
      if saved then
        showSaved()
        return
      end

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

    self:loadSeries(dialog, detail.book, user_id)
  end)

  return dialog
end

--
-- The "more in this series" card for a book's detail screen.
--
-- The screen is already showing the book; the rest of the series arrives in the
-- background and is added when it does. Tapping a row opens that book's details
-- on top of this one, so Close comes back here. Nothing is fetched offline (the
-- screen simply has no card) or for a book that is in no series.
--
function DialogManager:loadSeries(dialog, book, user_id)
  local series_id = Shelf.seriesId(book)
  if not series_id or not NetworkManager:isConnected() then
    return
  end

  Background.run(function()
    local series = Api:getSeriesBooks(series_id, user_id)

    -- failed, cancelled by a tap, or the screen was closed meanwhile
    if not series or not UIManager:isWidgetShown(dialog) then
      return
    end

    local card = Shelf.seriesCard(series, book.book_id)
    if not card then
      return
    end

    dialog:setSeries(card, function(book_id)
      self:showBookDetail(book_id)
    end)
  end)
end

--
-- A failure the user must notice.
--
-- Delegates rather than building an InfoMessage here, because this predates
-- hardcover/lib/ui/status_dialogs.lua and duplicated it: two implementations
-- of the same message, one with a 2-second timeout and one with 5, and
-- BookDetailDialog had a third. A failure reported through the wrong one is a
-- failure that vanishes before it is read.
--
function DialogManager:showError(err)
  return StatusDialogs.error(err)
end

return DialogManager
