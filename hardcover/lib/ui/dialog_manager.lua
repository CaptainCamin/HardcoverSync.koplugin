local _ = require("gettext")
local T = require("ffi/util").template
local json = require("json")

local UIManager = require("ui/uimanager")
local Network = require("hardcover/lib/network")
local Notification = require("ui/widget/notification")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local Book = require("hardcover/lib/book")
local BookSearch = require("hardcover/lib/book_search")
local Home = require("hardcover/lib/home")
local HomeLoader = require("hardcover/lib/home_loader")
local Goals = require("hardcover/lib/goals")
local GoalActions = require("hardcover/lib/goal_actions")
local Vibes = require("hardcover/lib/vibes")
local ScreenLoad = require("hardcover/lib/screen_load")
local ScreenRegistry = require("hardcover/lib/screen_registry")
local ShelfLoader = require("hardcover/lib/shelf_loader")
local User = require("hardcover/lib/user")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")
local VERSION = require("hardcover_version")

local AuthScope = require("hardcover/lib/ui/auth_scope")
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

-- The book details screen's flows (open, shelf, rating, lists, series, similar) and the
-- reviews screen live in their own file; they are methods of this class all the same.
require("hardcover/lib/ui/book_flows").install(DialogManager)

-- The open screens by kind (see screen_registry.lua). Built on first use so a manager
-- made without it, or by a test, still works.
function DialogManager:screens()
  if not self._screens then
    self._screens = ScreenRegistry.new(self, {
      is_shown = function(widget) return UIManager:isWidgetShown(widget) end,
      close = function(widget) UIManager:close(widget) end,
    })
  end
  return self._screens
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

-- True when the sign-in is known to lack `scope`: the screen then says to sign out and
-- back in (see auth_scope.lua).
local scopeMissing = AuthScope.missing

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
  if not Network.connected() then
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
  self:screens():discard("search_results")

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
  self:screens():track("search_results", dialog)
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
  local beta = self.settings:readSetting(SETTING.UPDATE_BETA) == true
  require("hardcover/lib/github"):latestReleaseAsync(function(release)
    if not release then
      Updater.failed(self.settings)
      return
    end
    local before = Updater.available(self.settings, VERSION)
    Updater.remember(self.settings, release)
    if release.version and not (before and before.version == release.version) then
      UIManager:show(InfoMessage:new {
        text = T(_("Hardcover Sync %1 is available. Install it from Settings."), release.version),
        timeout = 5,
      })
    end
  end, beta, true)
end

function DialogManager:showHome()
  local user_id = User:getId()
  local cache = self.shelf_cache
  local ids = Home.statusIds()

  self:screens():discard("home")

  local saved_counts = cache and cache:counts(user_id, ids) or {}
  local saved_reading = cache and cache:reading(user_id) or {}
  -- what Currently Reading shows: the saved or fetched cards with the reading done
  -- offline (pages turned, books finished or started) laid over them
  local function shownReading(entries)
    local queue = self.sync_queue
    if not (queue and queue.applyToReading) then return entries end
    return queue:applyToReading(entries, function(book_id)
      return cache and cache:findEntry(user_id, book_id)
    end)
  end

  local dialog = require("hardcover/lib/ui/home_dialog"):new {
    rows = Home.rows(saved_counts),
    entries = shownReading(saved_reading),
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
    -- Hardcover's own recommendation lists (Top Picks, Recommendations, ...)
    vibes_cb = function()
      self:showVibes()
    end,
    stats_cb = function()
      self:showStats()
    end,
    -- books suggested from your ratings; a setting turns the tile off
    for_you_cb = self.settings:readSetting(SETTING.SHOW_FOR_YOU) ~= false and function()
      self:showForYou()
    end or nil,
    -- the saved goals, so the card is there at once and offline
    goals = self:shownGoals(cache and cache:goals(user_id) or nil),
    finished_offline = self:finishedOffline(),
    goal_cb = function(goal)
      self:showGoal(goal, nil)
    end,
    goals_cb = function()
      self:showGoals()
    end,
  }
  self:screens():track("home", dialog)

  UIManager:show(dialog)
  self:checkForUpdate()

  if not Network.connected() then
    return
  end

  -- the account line in Settings names who is signed in: found out here if it is not known yet
  User:refreshName()

  -- One request after another, each independent of the other's outcome.
  Background.run(function()
    HomeLoader.refresh {
      api = Api,
      cache = cache,
      alive = function() return UIManager:isWidgetShown(dialog) end,
      sleep = Background.sleep,
      user_id = user_id,
      status_ids = ids,
      saved_counts = saved_counts,
      saved_reading = saved_reading,
      shown_reading = shownReading,
      on_counts = function(counts)
        dialog:setRows(Home.rows(counts), true)
      end,
      on_reading = function(shown)
        dialog:setReading(shown, true)
      end,
      on_list_count = function(list_count)
        if dialog.list_count ~= list_count then
          dialog.list_count = list_count
          dialog:rebuildSoon()
        end
      end,
      on_goals = function(goals)
        dialog.goals = self:shownGoals(goals)
        dialog.finished_offline = self:finishedOffline()
        dialog:rebuildSoon()
      end,
    }
  end)
end

-- The shelf loader owns the paging rules; list screens page by the same size.
local SHELF_PAGE_SIZE = ShelfLoader.PAGE_SIZE

function DialogManager:showShelf(status_id, title)
  local user_id = User:getId()
  local cache = self.shelf_cache

  self:screens():discard("shelf")

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
      if not Network.connected() then
        callback(nil, _("not available offline"))
        return
      end
      Api:getShelfAsync(user_id, status_id, offset, limit, callback)
    end,
    select_entry_cb = function(entry)
      self:showBookDetail(entry.book_id)
    end,
  }
  self:screens():track("shelf", dialog)

  UIManager:show(dialog)

  if cached and #cached.entries > 0 then
    dialog.offset = #cached.entries
    dialog:setEntries(cached.entries, not cached.complete)
  end

  -- Offline there is nothing to wait for: say what is being shown and stop.
  if not Network.connected() then
    if cached then
      StatusDialogs.info(string.format(_("Offline: showing your list as it was on %s"),
        os.date("%Y-%m-%d", cached.saved_at or os.time())))
    else
      StatusDialogs.retry(_("no internet connection"), _("Loading your shelf"),
        function() self:showShelf(status_id, title) end,
        function() end)
    end
    return
  end

  -- With a saved list already on screen the refresh is quiet; without one the
  -- reader is waiting on it, so say so.
  local loading = not cached and StatusDialogs.loading(_("Loading your shelf…")) or nil

  local function stopLoading()
    if loading then
      StatusDialogs.close(loading)
      loading = nil
    end
  end

  -- Load the whole shelf, a page at a time, in the background. Rows appear as
  -- they arrive when there is nothing saved to show; with a saved list on
  -- screen the fresh one replaces it once it is complete, so the list never
  -- shrinks to its first page while it refreshes.
  Background.run(function()
    local result = ShelfLoader.load {
      fetch = function(offset, limit) return Api:getShelf(user_id, status_id, offset, limit) end,
      network = Network,
      dedupe = true,
      alive = function() return UIManager:isWidgetShown(dialog) end,
      sleep = Background.sleep,
      on_page = function(fresh)
        stopLoading()
        if not cached then
          dialog.offset = #fresh
          dialog:setEntries(fresh, true, true)
        end
      end,
    }

    stopLoading()
    -- closed while loading: nothing left to update
    if not result then return end

    local plan = ShelfLoader.plan(result, cached ~= nil)
    local fresh = result.entries

    if plan == "replace" then
      if cache then
        cache:put(user_id, status_id, fresh, true)
      end
      if #fresh == 0 then
        dialog:setEmptyState(_("No books on this shelf yet"))
      else
        dialog.offset = #fresh
        dialog:setEntries(fresh, false, true)
      end
    elseif plan == "partial" then
      -- Keep what arrived. The reload icon stays so the reader can carry on.
      if cache then
        cache:put(user_id, status_id, fresh, false)
      end
    elseif plan == "retry" then
      -- Nothing arrived and nothing was saved: offer the retry rather than an
      -- error the reader can only dismiss and start again.
      StatusDialogs.retry(result.failure, _("Loading your shelf"),
        function()
          self:showShelf(status_id, title)
        end,
        function() end)
    end
    -- "keep": a saved list is still right there, and failing to refresh it is not
    -- worth interrupting for
  end)
end

--
-- Reading goals. Shown at once from the saved copy (or a loading line), refreshed
-- when the network answers; the saved copy is what an offline device shows, with a
-- note saying when it is from. Pace is worked out on the device (see goals.lua), and
-- books finished here but not yet sent count toward the number.
--
-- "<why> Showing your <things> as of <date>.": `sentence` is the whole translated line (with the
-- two %s), `why` what happened ("Offline.", "Couldn't refresh.")
local function savedNote(sentence, saved_at, why)
  return string.format(sentence, why, os.date("%b %d", saved_at or os.time()))
end

local function goalsNote(saved_at, why)
  return savedNote(_("%s Showing your goals as of %s."), saved_at, why)
end

function DialogManager:finishedOffline()
  return self.sync_queue and self.sync_queue:finishedCount() or 0
end

-- The goals as the screens show them: what Hardcover last said (or the saved copy),
-- with the changes made offline and not yet sent laid over it, marked as waiting.
function DialogManager:shownGoals(goals)
  local queue = self.goal_queue
  if queue and goals and not queue:isEmpty() then
    return queue:apply(goals)
  end
  return goals
end

-- Goal changes are sent by the sync (see HardcoverApp:flushSyncQueue); this brings
-- the saved copy and every screen up to date with what went through.
function DialogManager:goalsFlushed(sent_goals, archived_keys)
  if #sent_goals == 0 and #archived_keys == 0 then return end
  self:applyGoals(GoalActions.afterFlush(self:savedGoals(), sent_goals, archived_keys))
end

function DialogManager:showGoals()
  local user_id = User:getId()
  local cache = self.shelf_cache
  local cached, saved_at = cache and cache:goals(user_id)

  self:screens():discard("goals")

  local online = Network.connected()
  local start = ScreenLoad.start(cached, online)
  local note
  if start == "saved_offline" then note = goalsNote(saved_at, _("Offline.")) end

  local dialog = require("hardcover/lib/ui/goals_dialog"):new {
    goals = self:shownGoals(cached),
    finished_offline = self:finishedOffline(),
    note = note,
    message = (start == "loading" and _("Loading your goals\226\128\166"))
      or (start == "needs_network" and _("Goals need an internet connection the first time."))
      or nil,
    open_cb = function(goal)
      self:showGoal(goal, note)
    end,
    new_cb = function()
      self:showGoalForm(nil)
    end,
  }
  if cached and #(self:shownGoals(cached)) == 0 then
    dialog.message = _("No goals yet. Tap New goal to set one.")
  end
  self:screens():track("goals", dialog)
  UIManager:show(dialog)
  if not online then return end

  Api:getGoalsAsync(function(goals, err)
    if not UIManager:isWidgetShown(dialog) then return end
    local outcome = ScreenLoad.finish(goals, cached)
    if outcome == "fresh" then
      if cache then cache:putGoals(user_id, goals) end
      dialog.open_cb = function(goal) self:showGoal(goal, nil) end
      dialog:setGoals(self:shownGoals(goals), nil, self:finishedOffline())
    elseif outcome == "stale" then
      dialog:setGoals(self:shownGoals(cached), goalsNote(saved_at, _("Couldn't refresh.")), self:finishedOffline())
    else
      StatusDialogs.retry(err, _("Loading your goals"),
        function() self:showGoals() end,
        function() UIManager:close(dialog) end)
    end
  end)
end

local function statsNote(saved_at, why)
  return savedNote(_("%s Showing your stats as of %s."), saved_at, why)
end

-- Your reading as charts. The saved copy shows at once (or a loading line the first time),
-- and a fresh load replaces it when the connection allows. A change of shelf marks the
-- saved copy stale, so it is refreshed here even when it is recent.
function DialogManager:showStats()
  local user_id = User:getId()
  local cache = self.shelf_cache
  local saved = cache and cache:stats(user_id)

  self:screens():discard("stats")

  local online = Network.connected()
  local start = ScreenLoad.start(saved, online)
  local dialog = require("hardcover/lib/ui/stats_dialog"):new {
  }
  if saved then
    dialog.rows, dialog.genres, dialog.complete = saved.rows, saved.genres, saved.complete ~= false
    if start == "saved_offline" then dialog.note = statsNote(saved.saved_at, _("Offline.")) end
    dialog:rebuild()
  elseif start == "loading" then
    dialog.message = _("Loading your stats\226\128\166")
  else
    dialog.message = _("Stats need an internet connection the first time.")
  end
  self:screens():track("stats", dialog)
  UIManager:show(dialog)
  if not online then return end

  Api:getStatsAsync(user_id, function(stats, err)
    if not UIManager:isWidgetShown(dialog) then return end
    local outcome = ScreenLoad.finish(stats, saved)
    if outcome == "fresh" then
      if cache then cache:putStats(user_id, stats) end
      dialog:setStats(stats, nil)
    elseif outcome == "stale" then
      dialog:setStats(saved, statsNote(saved.saved_at, _("Couldn't refresh.")))
    else
      StatusDialogs.retry(err, _("Loading your stats"),
        function() self:showStats() end,
        function() UIManager:close(dialog) end)
    end
  end)
end

-- One goal, big. `note` is the saved-copy note when the goals shown are not fresh.
function DialogManager:showGoal(goal, note)
  local dialog = require("hardcover/lib/ui/goal_dialog"):new {
    goal = goal,
    finished_offline = self:finishedOffline(),
    note = note,
    edit_cb = function(current)
      self:showGoalForm(current)
    end,
  }
  self:screens():track("goal", dialog)
  UIManager:show(dialog)
end

--
-- Making a goal (`goal` nil) or changing one: a form that stays open until the save
-- has gone through, so a failure (no connection, a refusal) keeps what was typed.
-- Saving needs the connection and the write:goals permission; neither is assumed:
-- offline says so without sending anything, and a sign-in from before the
-- permission existed is asked to sign in again.
--
function DialogManager:showGoalForm(goal, on_saved)
  local dialog
  dialog = require("hardcover/lib/ui/goal_form_dialog"):new {
    goal = goal,
    on_save = function(form)
      self:saveGoal(dialog, form, on_saved)
    end,
    on_archive = goal and function()
      self:archiveGoal(dialog, goal, on_saved)
    end or nil,
  }
  self:screens():track("goal_form", dialog)
  UIManager:show(dialog)
  return dialog
end

-- The goals as they are now (a list), everywhere they are shown: saved for offline,
-- on the Goals screen, on Home's card, and on the goal screen if it is open.
function DialogManager:applyGoals(goals, changed)
  local user_id = User:getId()
  if self.shelf_cache then self.shelf_cache:putGoals(user_id, goals) end

  local shown = self:shownGoals(goals)
  local screen = self:screens():open("goals")
  if screen then
    screen:setGoals(shown, nil, self:finishedOffline())
  end
  local home = self:screens():open("home")
  if home then
    home.goals = shown
    home.finished_offline = self:finishedOffline()
    home:rebuild()
  end
  local one = changed and self:screens():open("goal")
  if one and one.goal and one.goal.id == changed.id then
    one:setGoal(changed)
  end
end

-- the goals saved on the device (a list; empty when none)
function DialogManager:savedGoals()
  local cache = self.shelf_cache
  return cache and cache:goals(User:getId()) or {}
end

-- the goal screen under a form is about a goal that is no longer listed
function DialogManager:closeGoalScreen(goal_id)
  local one = self:screens():open("goal")
  if one and one.goal and one.goal.id == goal_id then
    UIManager:close(one)
  end
end

-- Make a change wait for the connection: it shows at once everywhere, and the sync
-- sends it. `goal` is what to show now (a goal, or nil for an archive).
function DialogManager:queueGoalChange(dialog, apply_fn, on_saved, goal)
  apply_fn()
  self:applyGoals(self:savedGoals(), goal)
  UIManager:close(dialog)
  if on_saved and goal then on_saved(goal) end
  UIManager:show(Notification:new { text = _("Saved on this device. It will sync when you're online.") })
end

function DialogManager:saveGoal(dialog, form, on_saved)
  local queue = self.goal_queue
  local route = GoalActions.route {
    scope_missing = scopeMissing(Goals.WRITE_SCOPE),
    queue = queue,
    connected = Network.connected(),
    goal_id = form.id,
  }

  if route == "sign_in" then
    dialog:setMessage(GoalActions.SIGN_IN_AGAIN)
    return
  end

  -- Offline, or a change to this goal is already waiting: keep it here.
  if route == "queue" then
    local base
    for _i, g in ipairs(self:savedGoals()) do if g.id == form.id then base = g end end
    local goal = queue:queueSave(form, base)
    self:queueGoalChange(dialog, function() end, on_saved, goal)
    if Network.connected() and self.flush_goals then self.flush_goals() end
    return
  end

  if route == "offline" then
    dialog:setMessage(_("You're offline. Your changes are kept here: save when you're connected."))
    return
  end

  dialog:setBusy(true)
  Api:saveGoalAsync(form.id, Goals.input(form), function(saved, err)
    -- the goal is saved on Hardcover whether or not the form is still open, so the
    -- saved copy follows either way
    if saved then
      self:applyGoals(Goals.upsert(self:savedGoals(), saved), saved)
    end
    if not UIManager:isWidgetShown(dialog) then return end
    if not saved then
      dialog:setBusy(false)
      dialog:setMessage(string.format(_("Couldn't save the goal: %s Your changes are kept."), GoalActions.problem(err)))
      return
    end
    UIManager:close(dialog)
    if on_saved then on_saved(saved) end
  end)
end

function DialogManager:archiveGoal(dialog, goal, on_saved)
  local queue = self.goal_queue
  local route = GoalActions.route {
    scope_missing = scopeMissing(Goals.WRITE_SCOPE),
    queue = queue,
    connected = Network.connected(),
    goal_id = goal.id,
  }

  if route == "sign_in" then
    dialog:setMessage(GoalActions.SIGN_IN_AGAIN)
    return
  end

  if route == "queue" then
    queue:queueArchive(goal.id, goal)
    self:queueGoalChange(dialog, function() end, nil, nil)
    self:closeGoalScreen(goal.id)
    if on_saved then on_saved(nil) end
    if Network.connected() and self.flush_goals then self.flush_goals() end
    return
  end

  if route == "offline" then
    dialog:setMessage(_("You're offline. Archiving needs a connection."))
    return
  end

  dialog:setBusy(true)
  Api:archiveGoalAsync(goal, function(done, err)
    if done then
      self:applyGoals(Goals.remove(self:savedGoals(), goal.id))
    end
    if not UIManager:isWidgetShown(dialog) then return end
    if not done then
      dialog:setBusy(false)
      dialog:setMessage(string.format(_("Couldn't archive the goal: %s"), GoalActions.problem(err)))
      return
    end
    UIManager:close(dialog)
    self:closeGoalScreen(goal.id)
    if on_saved then on_saved(nil) end
  end)
end

--
-- Your lists and the ones you follow. Shown at once with a loading line, filled in
-- when the answer arrives; a list opens in the shelf screen (showList).
--
function DialogManager:showLists()
  self:screens():discard("lists")

  local dialog = require("hardcover/lib/ui/lists_dialog"):new {
    message = _("Loading your lists\226\128\166"),
    select_cb = function(row)
      self:showList(row)
    end,
  }
  self:screens():track("lists", dialog)
  UIManager:show(dialog)

  if not Network.connected() then
    dialog:setMessage(_("Lists need an internet connection."))
    return
  end

  Api:getListsAsync(function(lists, err)
    if not UIManager:isWidgetShown(dialog) then return end
    if not lists then
      StatusDialogs.retry(err, _("Loading your lists"),
        function() self:showLists() end,
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
-- "For you": books suggested from the ones you rated 4 or more (see Api:getForYou), in the
-- shelf screen with the reason under each. The saved picks show at once (and are all
-- there is offline, with the date they are from); a fresh set replaces them when it
-- arrives and is saved for next time.
--
function DialogManager:showForYou()
  local user_id = User:getId()
  local cache = self.shelf_cache
  local saved, saved_at
  if cache then saved, saved_at = cache:forYou(user_id) end

  local dialog
  dialog = require("hardcover/lib/ui/shelf_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = _("For you"),
    sortable = false,
    entries = saved or {},
    has_more = false,
    offset = saved and #saved or 0,
    page_size = SHELF_PAGE_SIZE,
    fetch_page = function(_offset, _limit, callback) callback(nil, _("not available offline")) end,
    select_entry_cb = function(entry)
      self:showBookDetail(entry.book_id)
    end,
  }
  self:screens():track("for_you", dialog)
  UIManager:show(dialog)

  if not Network.connected() then
    if saved and #saved > 0 then
      StatusDialogs.info(T(_("Offline: showing your picks from %1."), os.date("%b %d", saved_at or os.time())))
    else
      StatusDialogs.info(_("Suggestions need an internet connection."))
      UIManager:close(dialog)
    end
    return
  end

  local loading = not (saved and #saved > 0) and StatusDialogs.loading(_("Finding books for you\226\128\166"))
  Api:getForYouAsync(function(entries, err, note)
    if loading then StatusDialogs.close(loading) end
    if not UIManager:isWidgetShown(dialog) then return end

    if entries == nil then
      if saved and #saved > 0 then return end -- keep the saved picks
      StatusDialogs.retry(err, _("Finding books for you"),
        function()
          UIManager:close(dialog)
          self:showForYou()
        end,
        function() UIManager:close(dialog) end)
      return
    end

    if #entries == 0 then
      dialog:setEmptyState(note == "no_ratings"
        and _("Rate a few books 4 or 5 stars and suggestions will appear here.")
        or _("No suggestions yet."))
      return
    end
    if cache then cache:putForYou(user_id, entries) end
    dialog.offset = #entries
    dialog:setEntries(entries, false, true)
  end)
end

--
-- Hardcover's vibes for your account: the ones it makes for you (Top Picks, Recommendations,
-- "Based on ...") and the ones you made, each with its first covers; one opens in the shelf
-- screen in its own ranking (showVibe). Needs the read:vibes permission, which a sign-in from
-- before it was asked for lacks.
--
function DialogManager:showVibes()
  self:screens():discard("vibes")

  local dialog = require("hardcover/lib/ui/lists_dialog"):new {
    title = _("Vibes"),
    mine_title = _("From Hardcover"),
    following_title = _("Made by you"),
    message = _("Loading your vibes\226\128\166"),
    select_cb = function(row)
      self:showVibe(row.vibe)
    end,
  }
  self:screens():track("vibes", dialog)
  UIManager:show(dialog)

  if scopeMissing(Vibes.SCOPE) then
    dialog:setMessage(_("Sign out and back in (Settings > Account) to see your vibes."))
    return
  end
  if not Network.connected() then
    dialog:setMessage(_("Vibes need an internet connection."))
    return
  end

  Api:getVibesAsync(User:getId(), function(vibes, covers_or_err)
    if not UIManager:isWidgetShown(dialog) then return end
    if not vibes then
      if Vibes.isScopeError(covers_or_err) then
        dialog:setMessage(_("Sign out and back in (Settings > Account) to see your vibes."))
        return
      end
      StatusDialogs.retry(covers_or_err, _("Loading your vibes"),
        function() self:showVibes() end,
        function() UIManager:close(dialog) end)
      return
    end
    if #vibes == 0 then
      dialog:setMessage(_("No vibes yet. Make one on hardcover.app and it will show up here."))
      return
    end
    local system, mine = Vibes.rows(vibes, covers_or_err)
    dialog:setLists(system, mine)
  end)
end

-- One vibe's books in its ranking, in the shelf screen, a page at a time as you page on.
function DialogManager:showVibe(vibe)
  local PAGE = 20
  local dialog
  local function fetch_page(offset, limit, callback)
    Api:getBooksByIdsAsync(Vibes.page(vibe, offset, limit), function(entries, err)
      if not UIManager:isWidgetShown(dialog) then return end
      callback(entries, err, offset + (limit or PAGE) < #vibe.ids)
    end)
  end
  dialog = require("hardcover/lib/ui/shelf_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = vibe.title,
    sortable = false,
    entries = {},
    has_more = false,
    offset = 0,
    page_size = PAGE,
    fetch_page = fetch_page,
    select_entry_cb = function(entry)
      self:showBookDetail(entry.book_id)
    end,
  }
  UIManager:show(dialog)

  if not Network.connected() then
    StatusDialogs.info(_("Vibes need an internet connection."))
    UIManager:close(dialog)
    return
  end

  local loading = StatusDialogs.loading(_("Loading the books\226\128\166"))
  Api:getBooksByIdsAsync(Vibes.page(vibe, 0, PAGE), function(entries, err)
    StatusDialogs.close(loading)
    if not UIManager:isWidgetShown(dialog) then return end
    if not entries then
      StatusDialogs.retry(err, _("Loading the vibe"),
        function()
          UIManager:close(dialog)
          self:showVibe(vibe)
        end,
        function() UIManager:close(dialog) end)
      return
    end
    if #entries == 0 then
      dialog:setEmptyState(_("No books in this vibe yet"))
      return
    end
    dialog.offset = PAGE
    dialog:setEntries(entries, #vibe.ids > PAGE, true)
  end)
end

--
-- One list's books, in the list's own order, in the shelf screen (a ranked list
-- numbers them). Loaded a page at a time in the background, like a shelf, but not
-- saved for offline: a list is read when you open it.
--
function DialogManager:showList(row)
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
      self:showBookDetail(entry.book_id)
    end,
  }
  UIManager:show(dialog)

  if not Network.connected() then
    StatusDialogs.info(_("Lists need an internet connection."))
    UIManager:close(dialog)
    return
  end

  local loading = StatusDialogs.loading(_("Loading the list\226\128\166"))
  local function stopLoading()
    if loading then
      StatusDialogs.close(loading)
      loading = nil
    end
  end

  Background.run(function()
    local result = ShelfLoader.load {
      fetch = function(offset, limit)
        return Api:getListBooks(row.id, row.source, row.ranked, offset, limit)
      end,
      use_has_more = true,
      alive = function() return UIManager:isWidgetShown(dialog) end,
      sleep = Background.sleep,
      on_page = function(fresh)
        stopLoading()
        dialog.offset = #fresh
        dialog:setEntries(fresh, true, true)
      end,
    }

    stopLoading()
    if not result then return end

    local plan = ShelfLoader.plan(result, false)
    local fresh = result.entries

    if plan == "replace" then
      if #fresh == 0 then
        dialog:setEmptyState(_("No books on this list yet"))
      else
        dialog.offset = #fresh
        dialog:setEntries(fresh, false, true)
      end
    elseif plan == "retry" then
      StatusDialogs.retry(result.failure, _("Loading the list"),
        function()
          UIManager:close(dialog)
          self:showList(row)
        end,
        function() UIManager:close(dialog) end)
    end
    -- "partial": keep what arrived
  end)
end

--
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
