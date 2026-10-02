local _ = require("gettext")
local T = require("ffi/util").template
local json = require("json")

local UIManager = require("ui/uimanager")
local NetworkManager = require("ui/network/manager")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local Book = require("hardcover/lib/book")
local BookSearch = require("hardcover/lib/book_search")
local Home = require("hardcover/lib/home")
local Lists = require("hardcover/lib/lists")
local Reviews = require("hardcover/lib/reviews")
local Shelf = require("hardcover/lib/shelf")
local Zlibrary = require("hardcover/lib/zlibrary")
local User = require("hardcover/lib/user")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")
local VERSION = require("hardcover_version")

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

--
-- Search for books from the home screen.
--
-- Type, submit, see a list, tap a book for its details. One search is two
-- requests (the search, then the books' details) against a limit of 60 a
-- minute, so it only runs on submit, never while typing.
--
function DialogManager:showSearchInput(initial)
  local input
  local function submit()
    local query = BookSearch.normalize(input:getInputText())
    if not query then return end
    UIManager:close(input)
    self:searchBooks(query)
  end
  input = require("ui/widget/inputdialog"):new {
    title = _("Search books"),
    input = initial or "",
    input_hint = _("Title or author"),
    buttons = { {
      {
        text = _("Cancel"),
        callback = function() UIManager:close(input) end,
      },
      {
        text = _("Search"),
        is_enter_default = true,
        callback = submit,
      },
    } },
  }
  UIManager:show(input)
  input:onShowKeyboard()
  return input
end

function DialogManager:searchBooks(query)
  if not NetworkManager:isConnected() then
    StatusDialogs.error(_("Searching needs an internet connection."))
    return
  end

  local loading = StatusDialogs.loading(_("Searching…"))
  Api:findBooksAsync(query, nil, User:getId(), function(books, err)
    StatusDialogs.close(loading)

    -- nil is a failure; an empty list is an answer
    if not books then
      StatusDialogs.retry(err, _("Searching for books"),
        function() self:searchBooks(query) end,
        function() end)
      return
    end

    self:showSearchResults(query, BookSearch.cap(books))
  end)
end

function DialogManager:showSearchResults(query, books)
  discard(self.search_results_dialog)

  local dialog = require("hardcover/lib/ui/shelf_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = BookSearch.title(query),
    entries = books,
    has_more = false,
    offset = #books,
    select_entry_cb = function(entry)
      self:showBookDetail(entry.book_id)
    end,
  }
  self.search_results_dialog = dialog
  UIManager:show(dialog)

  if #books == 0 then
    dialog:setEmptyState(_("No results"))
  end
end

-- At most once a day, ask GitHub whether there is a newer release and remember
-- the answer (the Settings row shows it). A newer version is mentioned once.
function DialogManager:checkForUpdate()
  local Updater = require("hardcover/lib/updater")
  if not Updater.due(self.settings) then return end
  require("hardcover/lib/github"):latestReleaseAsync(function(release)
    if not release then return end
    local before = Updater.available(self.settings, VERSION)
    Updater.remember(self.settings, release)
    if release.version and not (before and before.version == release.version) then
      UIManager:show(InfoMessage:new {
        text = T(_("Hardcover Sync %1 is available. Install it from Settings."), release.version),
        timeout = 5,
      })
    end
  end)
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
    search_cb = function()
      self:showSearchInput()
    end,
    lists_cb = function()
      self:showLists()
    end,
    -- the saved goals, so the card is there at once and offline
    goals = cache and cache:goals(user_id) or nil,
    finished_offline = self:finishedOffline(),
    goal_cb = function(goal)
      self:showGoal(goal, nil)
    end,
    goals_cb = function()
      self:showGoals()
    end,
    close_callback = function()
      if done_callback then done_callback() end
    end,
  }
  self.home_dialog = dialog

  UIManager:show(dialog)
  self:checkForUpdate()

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
    if not UIManager:isWidgetShown(dialog) then
      return
    end

    if entries then
      if cache then
        cache:putReading(user_id, entries)
      end
      if not Home.sameCards(entries, saved_reading) then
        dialog:setReading(entries)
      end
    end

    -- the "More lists" tile's number: yours plus the ones you follow
    local list_count = Api:getListCount()
    if list_count and UIManager:isWidgetShown(dialog) and dialog.list_count ~= list_count then
      dialog.list_count = list_count
      dialog:rebuild()
    end

    -- the goal card: fresh goals replace the saved ones
    if UIManager:isWidgetShown(dialog) then
      local goals = Api:getGoals()
      if goals and UIManager:isWidgetShown(dialog) then
        if cache then cache:putGoals(user_id, goals) end
        dialog.goals = goals
        dialog.finished_offline = self:finishedOffline()
        dialog:rebuild()
      end
    end
  end)
end

-- How many books each request asks for. The loop below keeps asking until a page
-- comes back empty rather than until one comes back short, so a server that
-- returns fewer than requested still yields the whole shelf.
--
-- 100, not 50: a 600-book shelf is 7 requests instead of 13. Hardcover allows
-- 10 requests back to back and then one a second (60 a minute), and a quick
-- connection loading page after page uses the burst up -- seen against the real
-- API, where the later pages came back 429. The API accepts far more per request
-- (500 was fine) but each book carries its description for the offline copy, so
-- a page is already 70-140 KB.
local SHELF_PAGE_SIZE = 100

-- A tap cancels a request in flight (KOReader's rule for a dismissable
-- subprocess). Loading a long shelf takes several requests, and the reader will
-- tap while it runs, so a cancelled page is asked for again this many times
-- before the load gives up.
local SHELF_PAGE_RETRIES = 3

-- A shelf this long is not being loaded to be read; stop rather than loop.
local SHELF_MAX_PAGES = 200

-- Told to slow down (HTTP 429): wait, then ask for the same page again. The
-- bucket refills at one request a second, so a couple of seconds is enough; a
-- load that is still refused after this many waits gives up like any failure.
local SHELF_RATE_LIMIT_WAITS = 5

function DialogManager:showShelf(status_id, title, done_callback)
  local user_id = User:getId()
  local cache = self.shelf_cache

  discard(self.shelf_dialog)
  self.shelf_dialog = nil

  -- The whole list as it was last loaded, if it ever was. Shown at once, so the
  -- shelf is there before (or without) the network; the load below then
  -- refreshes it.
  local cached = cache and cache:get(user_id, status_id)

  -- the order you last chose for this shelf (the order of each shelf is
  -- remembered separately)
  local sort_choices = self.settings:readSetting(SETTING.SHELF_SORT)
  local sort_key = type(sort_choices) == "table" and sort_choices[tostring(status_id)] or nil

  local dialog = require("hardcover/lib/ui/shelf_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    status_id = status_id,
    sortable = true,
    sort_key = sort_key,
    on_sort_change = function(key)
      local saved = self.settings:readSetting(SETTING.SHELF_SORT)
      saved = type(saved) == "table" and saved or {}
      saved[tostring(status_id)] = key
      self.settings:updateSetting(SETTING.SHELF_SORT, saved)
    end,
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
    local rate_waits = 0
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
        elseif type(err) == "table" and err.status == 429 and rate_waits < SHELF_RATE_LIMIT_WAITS then
          rate_waits = rate_waits + 1
          Background.sleep(2 * rate_waits)
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
-- Reading goals. Shown at once from the saved copy (or a loading line), refreshed
-- when the network answers; the saved copy is what an offline device shows, with a
-- note saying when it is from. Pace is worked out on the device (see goals.lua), and
-- books finished here but not yet sent count toward the number.
--
local function goalsNote(saved_at, why)
  local when = os.date("%b %d", saved_at or os.time())
  return string.format(_("%s Showing your goals as of %s."), why, when)
end

function DialogManager:finishedOffline()
  return self.sync_queue and self.sync_queue:finishedCount() or 0
end

function DialogManager:showGoals(done_callback)
  local user_id = User:getId()
  local cache = self.shelf_cache
  local cached, saved_at = cache and cache:goals(user_id)

  discard(self.goals_dialog)
  self.goals_dialog = nil

  local note
  local online = NetworkManager:isConnected()
  if cached and not online then note = goalsNote(saved_at, _("Offline.")) end

  local dialog = require("hardcover/lib/ui/goals_dialog"):new {
    goals = cached,
    finished_offline = self:finishedOffline(),
    note = note,
    message = cached == nil and (online and _("Loading your goals\226\128\166") or _("Goals need an internet connection the first time.")) or nil,
    open_cb = function(goal)
      self:showGoal(goal, note)
    end,
    close_callback = function()
      if done_callback then done_callback() end
    end,
  }
  if cached and #cached == 0 then
    dialog.message = _("No goals yet. Set one on hardcover.app and it will show up here.")
  end
  self.goals_dialog = dialog
  UIManager:show(dialog)
  if not online then return end

  Api:getGoalsAsync(function(goals, err)
    if not UIManager:isWidgetShown(dialog) then return end
    if goals then
      if cache then cache:putGoals(user_id, goals) end
      dialog.open_cb = function(goal) self:showGoal(goal, nil) end
      dialog:setGoals(goals, nil, self:finishedOffline())
    elseif cached then
      dialog:setGoals(cached, goalsNote(saved_at, _("Couldn't refresh.")), self:finishedOffline())
    else
      StatusDialogs.retry(err, _("Loading your goals"),
        function() self:showGoals(done_callback) end,
        function() UIManager:close(dialog) end)
    end
  end)
end

-- One goal, big. `note` is the saved-copy note when the goals shown are not fresh.
function DialogManager:showGoal(goal, note, done_callback)
  UIManager:show(require("hardcover/lib/ui/goal_dialog"):new {
    goal = goal,
    finished_offline = self:finishedOffline(),
    note = note,
    close_callback = function()
      if done_callback then done_callback() end
    end,
  })
end

--
-- Your lists and the ones you follow. Shown at once with a loading line, filled in
-- when the answer arrives; a list opens in the shelf screen (showList).
--
function DialogManager:showLists(done_callback)
  discard(self.lists_dialog)
  self.lists_dialog = nil

  local dialog = require("hardcover/lib/ui/lists_dialog"):new {
    message = _("Loading your lists\226\128\166"),
    select_cb = function(row)
      self:showList(row)
    end,
    close_callback = function()
      if done_callback then done_callback() end
    end,
  }
  self.lists_dialog = dialog
  UIManager:show(dialog)

  if not NetworkManager:isConnected() then
    dialog:setMessage(_("Lists need an internet connection."))
    return
  end

  Api:getListsAsync(function(lists, err)
    if not UIManager:isWidgetShown(dialog) then return end
    if not lists then
      StatusDialogs.retry(err, _("Loading your lists"),
        function() self:showLists(done_callback) end,
        function() UIManager:close(dialog) end)
      return
    end
    if #lists.mine == 0 and #lists.following == 0 then
      dialog:setMessage(_("No lists yet. Make one on hardcover.app and it will show up here."))
      return
    end
    dialog:setLists(lists.mine, lists.following)
  end)
end

--
-- One list's books, in the list's own order, in the shelf screen (a ranked list
-- numbers them). Loaded a page at a time in the background, like a shelf, but not
-- saved for offline: a list is read when you open it.
--
function DialogManager:showList(row, done_callback)
  local dialog = require("hardcover/lib/ui/shelf_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = row.name,
    sortable = false,
    entries = {},
    has_more = false,
    offset = 0,
    page_size = SHELF_PAGE_SIZE,
    fetch_page = function(_offset, _limit, callback) callback(nil, _("not available offline")) end,
    select_entry_cb = function(entry)
      self:showBookDetail(entry.book_id, nil, done_callback)
    end,
    close_callback = function()
      if done_callback then done_callback() end
    end,
  }
  UIManager:show(dialog)

  if not NetworkManager:isConnected() then
    StatusDialogs.info(_("Lists need an internet connection."))
    UIManager:close(dialog)
    return
  end

  local loading = StatusDialogs.loading(_("Loading the list\226\128\166"))
  Background.run(function()
    local fresh, offset, retries, pages, rate_waits = {}, 0, 0, 0, 0
    local complete, failure = false, nil

    local function stopLoading()
      if loading then
        StatusDialogs.close(loading)
        loading = nil
      end
    end

    while UIManager:isWidgetShown(dialog) do
      local entries, err, has_more = Api:getListBooks(row.id, row.source, row.ranked, offset, SHELF_PAGE_SIZE)

      if not UIManager:isWidgetShown(dialog) then break end

      if entries == nil then
        if type(err) == "table" and err.completed == false and retries < SHELF_PAGE_RETRIES then
          retries = retries + 1
        elseif type(err) == "table" and err.status == 429 and rate_waits < SHELF_RATE_LIMIT_WAITS then
          rate_waits = rate_waits + 1
          Background.sleep(2 * rate_waits)
        else
          failure = err
          break
        end
      else
        retries = 0
        pages = pages + 1
        offset = offset + #entries
        for _i, entry in ipairs(entries) do fresh[#fresh + 1] = entry end

        if #entries == 0 or not has_more then
          complete = true
          break
        end
        stopLoading()
        dialog.offset = #fresh
        dialog:setEntries(fresh, true, true)
        if pages >= SHELF_MAX_PAGES then break end
      end
    end

    stopLoading()
    if not UIManager:isWidgetShown(dialog) then return end

    if complete then
      if #fresh == 0 then
        dialog:setEmptyState(_("No books on this list yet"))
      else
        dialog.offset = #fresh
        dialog:setEntries(fresh, false, true)
      end
      return
    end

    if #fresh > 0 then return end -- keep what arrived
    StatusDialogs.retry(failure, _("Loading the list"),
      function()
        UIManager:close(dialog)
        self:showList(row, done_callback)
      end,
      function() UIManager:close(dialog) end)
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
    -- the details on screen go along, so the reviews can say which book and how it is rated
    on_reviews = function(d) self:showReviews(book_id, nil, Reviews.summary(d and d.detail)) end,
    -- only when the Z-library plugin is there: no button that does nothing
    on_zlibrary = Zlibrary.available(self.ui) and function(d) self:searchZlibrary(d) end or nil,
    on_shelf = function(d) self:chooseShelf(d) end,
    -- only when signed in with OAuth (the write scope is an OAuth thing)
    on_lists = self:canChooseLists() and function(d) self:chooseLists(d) end or nil,
    -- these open on top of the details, so closing them comes back here
    on_series = function(_, name) self:searchBooks(name) end,
    on_author = function(_, name) self:searchBooks(name) end,
    on_status = function(_, status_id) self:showShelf(status_id, Shelf.statusLabel(status_id)) end,
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
-- Search for the book on screen in the Z-library plugin (a separate plugin, found
-- by what it can do). Its own results screen opens on top of this one.
function DialogManager:searchZlibrary(dialog)
  local detail = dialog and dialog.detail
  -- the details carry authors as contributions: the summary joins them
  local summary = detail and detail.book and Shelf.detailSummary(detail) or {}
  local ok, why = Zlibrary.search(self.ui, { title = summary.title, authors = summary.authors })
  if ok then return end

  if why == "not_installed" then
    StatusDialogs.info(_("The Z-library plugin is not installed or not enabled."))
  elseif why == "no_title" then
    StatusDialogs.info(_("This book has no title to search for."))
  else
    StatusDialogs.info(_("Could not open the Z-library search."))
  end
end

-- Other readers' reviews of a book, opened from its details screen.
--
-- Nothing is fetched until this is called, and then one request per page of
-- ten (Reviews.PAGE_SIZE): the API allows 60 a minute. Show-then-fetch, like
-- the shelves: the list appears at once saying it is loading. Offline there is
-- nothing to wait for, so say so and open nothing. A failed page offers a retry
-- instead of a dead end.
--
function DialogManager:showReviews(book_id, done_callback, summary)
  if not NetworkManager:isConnected() then
    StatusDialogs.info(_("Reviews need an internet connection"))
    return
  end

  local dialog

  -- one page, normalised; callback(rows, err, raw_count)
  local function fetch_page(offset, limit, callback)
    Api:getReviewsAsync(book_id, limit, offset, function(raw, err)
      if not UIManager:isWidgetShown(dialog) then return end

      if not raw then
        StatusDialogs.retry(err, _("Loading reviews"),
          function()
            if offset == 0 then
              dialog:setMessage(_("Loading reviews\226\128\166"))
              fetch_page(0, limit, function(rows, e, raw_count)
                if rows then dialog:addPage(rows, raw_count, 0) end
              end)
            else
              dialog:loadMore()
            end
          end,
          function()
            -- giving up on the first page leaves nothing to look at
            if offset == 0 then UIManager:close(dialog) end
          end)
        callback(nil, err or true)
        return
      end

      callback(Reviews.normalizeAll(raw), nil, #raw)
    end)
  end

  -- Hardcover only names reviewers to apps that were granted read:users. A
  -- sign-in from before that scope was asked for (false; nil = cannot tell, as
  -- with a personal token) shows "A reader" for everyone, so say why.
  local hint
  if Api.auth and Api.auth:hasScope("read:users") == false then
    hint = _("Names are hidden: sign out and back in to see them.")
  end

  dialog = require("hardcover/lib/ui/reviews_dialog"):new {
    message = _("Loading reviews\226\128\166"),
    summary = summary,
    hint = hint,
    fetch_page = fetch_page,
    close_callback = done_callback,
  }
  UIManager:show(dialog)

  fetch_page(0, Reviews.PAGE_SIZE, function(rows, _err, raw_count)
    if not rows then
      -- a failed first page: the retry above reloads it, or closes the screen
      return
    end
    dialog:addPage(rows, raw_count, 0)
  end)
end

-- Put the book on the details screen on a shelf, or take it off.
--
-- Online only: the change is sent at once and the screen is updated from the
-- answer, so offline there is nothing honest to show. (It does not touch the
-- offline sync queue, which is for reading progress.)
--
function DialogManager:chooseShelf(dialog)
  local detail = dialog.detail
  if not (detail and detail.book and detail.book.book_id) then return end

  if not NetworkManager:isConnected() then
    StatusDialogs.info(_("You are offline. Changing a shelf needs a connection."))
    return
  end

  local picker
  local rows = {}

  for _i, choice in ipairs(Shelf.statusChoices()) do
    local current = detail.status_id == choice.status_id
    rows[#rows + 1] = {
      -- a bullet marks where the book is now; choosing it again does nothing
      text = (current and "\226\128\162 " or "") .. _(choice.label),
      current = current,
      callback = function()
        UIManager:close(picker)
        if not current then
          self:saveShelf(dialog, choice.status_id)
        end
      end,
    }
  end

  if detail.user_book_id then
    rows[#rows + 1] = {
      text = _("Remove from library"),
      callback = function()
        UIManager:close(picker)
        StatusDialogs.confirm {
          text = string.format(_("Remove \"%s\" from your library? Your status, rating and reading history for it are deleted."),
            tostring(detail.book.title or "")),
          ok_text = _("Remove"),
          ok_callback = function() self:removeFromShelf(dialog) end,
        }
      end,
    }
  end

  rows[#rows + 1] = {
    text = _("Cancel"),
    callback = function() UIManager:close(picker) end,
  }

  picker = require("hardcover/lib/ui/picker").new {
    title = detail.status_id and _("Move to shelf") or _("Add to shelf"),
    rows = rows,
  }
  UIManager:show(picker)
end

-- Signed in with OAuth, so there is a sign-in whose scopes can say whether it may
-- change lists.
function DialogManager:canChooseLists()
  local auth = Api.auth
  return auth ~= nil and auth:usingOAuth() and not auth:needsReauth()
end

local function listsNeedNewSignIn()
  StatusDialogs.info(_("Sign out and back in (Settings > Account) to add books to lists."), 6)
end

-- The lists screen, when it is open underneath, shows the new size of a list.
function DialogManager:refreshListsScreen(list_id, count)
  local screen = self.lists_dialog
  if not (screen and UIManager:isWidgetShown(screen)) then return end
  local changed = false
  for _i, row in ipairs(screen.mine or {}) do
    if row.id == list_id and row.count ~= count then
      row.count = count
      changed = true
    end
  end
  if changed then screen:rebuild() end
end

-- Put the book on the details screen on your lists, or take it off, one tick box
-- per list (a book can be on many).
--
-- Online only, like the shelf: each tap is sent at once. Which lists the book is on
-- comes from one request, kept on the details screen so opening the picker again
-- asks nothing. Where a "New list" row would go: first in the picker's rows (see
-- showListsPicker), creating the list with a name prompt, then adding the book.
--
function DialogManager:chooseLists(dialog)
  local detail = dialog.detail
  if not (detail and detail.book and detail.book.book_id) then return end

  if not NetworkManager:isConnected() then
    StatusDialogs.info(_("You are offline. Changing a list needs a connection."))
    return
  end

  -- a sign-in known to lack the scope would only fail: say what to do instead
  -- (nil, as with a personal token, is "cannot tell": try and see)
  if Api.auth and Api.auth:hasScope(Lists.WRITE_SCOPE) == false then
    listsNeedNewSignIn()
    return
  end

  if detail.lists then
    self:showListsPicker(dialog)
    return
  end

  local loading = StatusDialogs.loading(_("Loading your lists\226\128\166"))
  Api:getBookListsAsync(detail.book.book_id, function(rows, err)
    StatusDialogs.close(loading)
    if not UIManager:isWidgetShown(dialog) then return end

    if not rows then
      StatusDialogs.retry(err, _("Loading your lists"),
        function() self:chooseLists(dialog) end,
        function() end)
      return
    end
    detail.lists = rows
    self:showListsPicker(dialog)
  end)
end

function DialogManager:showListsPicker(dialog)
  local detail = dialog.detail
  local book_id = detail.book.book_id
  local state = detail.lists
  if #state == 0 then
    StatusDialogs.info(_("You have no lists yet. Make one on hardcover.app and it will show up here."), 5)
    return
  end

  local picker
  local open = true

  -- the details screen names the lists once the picker is done with them
  local function syncDetail()
    if UIManager:isWidgetShown(dialog) then dialog:setLists(detail.lists) end
  end
  local function close()
    if not open then return end
    open = false
    UIManager:close(picker)
    syncDetail()
  end

  local function redraw(r)
    require("hardcover/lib/ui/picker").setRow(picker, "list_" .. r.id, Lists.pickerLabel(r), not r.busy)
  end
  local function changed(r)
    r.busy = nil
    redraw(r)
    self:refreshListsScreen(r.id, r.count)
    if not open then syncDetail() end -- the answer came after the picker was closed
  end
  -- the tick stays as it was; say why
  local function failed(r, err)
    r.busy = nil
    redraw(r)
    if Lists.isScopeError(err) then
      listsNeedNewSignIn()
    else
      StatusDialogs.error(string.format(_("Could not change \"%s\": %s"), r.name, StatusDialogs.describe(err)))
    end
  end

  local function toggle(r)
    if r.busy then return end
    if not NetworkManager:isConnected() then
      StatusDialogs.info(_("You are offline. Changing a list needs a connection."))
      return
    end
    r.busy = true
    redraw(r)

    if not r.on then
      -- the end of the list: Lists.insertObject
      Api:addToListAsync(book_id, r.id, r.count, function(added, err)
        if not added then return failed(r, err) end
        Lists.markAdded(r, added.id)
        changed(r)
      end)
      return
    end

    local function remove(list_book_id)
      Api:removeFromListAsync(list_book_id, function(removed, err)
        if not removed then return failed(r, err) end
        Lists.markRemoved(r)
        changed(r)
      end)
    end
    if r.list_book_id then
      remove(r.list_book_id)
      return
    end
    -- added a moment ago and Hardcover's answer did not say which row it made:
    -- look it up (one request) rather than guess
    Api:getBookListsAsync(book_id, function(fresh, err)
      local found
      for _i, f in ipairs(fresh or {}) do
        if f.id == r.id then found = f end
      end
      if not found then return failed(r, err or { message = _("the list was not found") }) end
      if not found.on then
        Lists.markRemoved(r) -- already off it
        return changed(r)
      end
      if not found.list_book_id then return failed(r, { message = _("no answer from Hardcover") }) end
      remove(found.list_book_id)
    end)
  end

  local rows = {}
  for _i, r in ipairs(state) do
    rows[#rows + 1] = {
      id = "list_" .. r.id,
      text = Lists.pickerLabel(r),
      callback = function() toggle(r) end,
    }
  end
  rows[#rows + 1] = { text = _("Done"), callback = close }

  picker = require("hardcover/lib/ui/picker").new {
    title = _("Add to lists"),
    rows = rows,
    close_callback = function()
      open = false
      syncDetail()
    end,
  }
  UIManager:show(picker)
end

-- The saved shelves and counts that a change of status makes wrong.
function DialogManager:forgetShelves(old_status_id, new_status_id)
  if not self.shelf_cache then return end
  local ids = {}
  if old_status_id then ids[#ids + 1] = old_status_id end
  if new_status_id then ids[#ids + 1] = new_status_id end
  self.shelf_cache:invalidate(User:getId(), ids)
end

function DialogManager:saveShelf(dialog, status_id)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local in_library = detail.user_book_id ~= nil or old_status_id ~= nil

  local loading = StatusDialogs.loading(_("Saving to your shelf…"))

  -- the edition is only passed when the book is new to the library: for a book
  -- already on a shelf, the upsert must not switch the edition it is read in
  Api:updateUserBookAsync(detail.book.book_id, status_id, nil,
    (not in_library) and detail.book.edition_id or nil,
    function(user_book, err)
      StatusDialogs.close(loading)

      if not user_book then
        StatusDialogs.retry(err, _("Saving to your shelf"),
          function() self:saveShelf(dialog, status_id) end,
          function() end)
        return
      end

      -- the change happened whether or not the screen is still there
      self:forgetShelves(old_status_id, status_id)
      if UIManager:isWidgetShown(dialog) then
        dialog:setStatus(status_id, user_book.id or detail.user_book_id)
      end
    end)
end

function DialogManager:removeFromShelf(dialog)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local user_book_id = detail.user_book_id
  if not user_book_id then return end

  local loading = StatusDialogs.loading(_("Removing from your library…"))

  Api:removeUserBookAsync(user_book_id, function(removed, err)
    StatusDialogs.close(loading)

    if not removed then
      StatusDialogs.retry(err, _("Removing from your library"),
        function() self:removeFromShelf(dialog) end,
        function() end)
      return
    end

    self:forgetShelves(old_status_id, nil)
    if UIManager:isWidgetShown(dialog) then
      dialog:setStatus(nil, nil)
    end
  end)
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
