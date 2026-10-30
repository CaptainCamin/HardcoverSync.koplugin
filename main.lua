local _ = require("gettext")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local logger = require("logger")
local math = require("math")

local T = require("ffi/util").template

local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local Event = require("ui/event")
local Notification = require("ui/widget/notification")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local _t = require("hardcover/lib/table_util")
local Api = require("hardcover/lib/hardcover_api")
local Auth = require("hardcover/lib/auth")
local AutoWifi = require("hardcover/lib/auto_wifi")
local Background = require("hardcover/lib/background")
local BookActions = require("hardcover/lib/book_actions")
local BookStore = require("hardcover/lib/book_store")
local Cache = require("hardcover/lib/cache")
local Config = require("hardcover/lib/config")
local debounce = require("hardcover/lib/debounce")
local EndOfBook = require("hardcover/lib/end_of_book")
local Hardcover = require("hardcover/lib/hardcover")
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local ListStore = require("hardcover/lib/list_store")
local JournalStore = require("hardcover/lib/journal_store")
local ReviewStore = require("hardcover/lib/review_store")
local PageMapper = require("hardcover/lib/page_mapper")
local Scheduler = require("hardcover/lib/scheduler")
local ShelfCache = require("hardcover/lib/shelf_cache")
local BookshelfSources = require("hardcover/lib/bookshelf_sources")
local BookshelfModules = require("hardcover/lib/bookshelf_modules")
local FileDialog = require("hardcover/lib/file_dialog")
local ShelfStore = require("hardcover/lib/shelf_store")
local SqliteStore = require("hardcover/lib/sqlite_store")
local SyncQueue = require("hardcover/lib/sync_queue")
local GoalQueue = require("hardcover/lib/goal_queue")
local RatingQueue = require("hardcover/lib/rating_queue")
local ShelfQueue = require("hardcover/lib/shelf_queue")
local ListQueue = require("hardcover/lib/list_queue")
local JournalQueue = require("hardcover/lib/journal_queue")
local ReviewQueue = require("hardcover/lib/review_queue")
local json = require("json")
local SyncConflicts = require("hardcover/lib/sync_conflicts")
local StartReading = require("hardcover/lib/start_reading")
local throttle = require("hardcover/lib/throttle")
local User = require("hardcover/lib/user")

local DialogManager = require("hardcover/lib/ui/dialog_manager")
local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")

local HardcoverApp = WidgetContainer:extend {
  name = "hardcoverappsync",
  is_doc_only = false,
  state = nil,
  settings = nil,
  width = nil,
  enabled = true
}

local HIGHLIGHT_MENU_NAME = "13_0_make_hardcover_highlight_item"

function HardcoverApp:onDispatcherRegisterActions()
  Dispatcher:registerAction("hardcover_link", {
    category = "none",
    event = "HardcoverLink",
    title = _("Hardcover: Link book"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_track", {
    category = "none",
    event = "HardcoverTrack",
    title = _("Hardcover: Track progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_stop_track", {
    category = "none",
    event = "HardcoverStopTrack",
    title = _("Hardcover: Stop tracking progress"),
    general = true,
  })

  -- A button for the home screen: it appears wherever KOReader lists actions
  -- (gestures, profiles, quick menus), so another plugin can launch it too.
  Dispatcher:registerAction("hardcover_home", {
    category = "none",
    event = "HardcoverHome",
    title = _("Hardcover: Home"),
    general = true,
  })

  -- The open book's panel: status, page, rating, notes, details. Bind it to a
  -- gesture (Settings > Taps and gestures) to open it from the reading screen.
  Dispatcher:registerAction("hardcover_book", {
    category = "none",
    event = "HardcoverBook",
    title = _("Hardcover: This book"),
    general = true,
  })

  -- The one button: the open book's panel while reading, the home screen in the file
  -- browser. The same as the Hardcover entry in the main menu.
  Dispatcher:registerAction("hardcover_open", {
    category = "none",
    event = "HardcoverOpen",
    title = _("Hardcover: Home or this book"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_update_progress", {
    category = "none",
    event = "HardcoverUpdateProgress",
    title = _("Hardcover: Update progress"),
    general = true,
  })
end

function HardcoverApp:init()
  self.state = {
    page = nil,
    pos = nil,
    search_results = {},
    book_status = {},
    page_update_pending = false,
    end_asked = {},
  }
  --logger.warn("HARDCOVER app init")
  self.settings = HardcoverSettings:new(
    ("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_settings.lua"),
    self.ui
  )
  self.settings:subscribe(function(field, change, original_value) self:onSettingsChanged(field, change, original_value) end)

  -- Lato for the redesigned screens, copied into KOReader's fonts folder once (nothing happens after
  -- that). Off the startup path, and it cannot fail the plugin: without it the screens use KOReader's font.
  UIManager:nextTick(function()
    pcall(function() require("hardcover/lib/font_install").run() end)
  end)

  -- Hooks into KOReader's book-status screen and its end-of-document menu (see koreader_hooks.lua)
  pcall(function() require("hardcover/lib/koreader_hooks").install() end)

  -- OAuth when hardcover_config.lua supplies a client_id; otherwise the
  -- static token in that same file is used, as before.
  self.auth = Auth:new {
    config = Config,
  }
  Api.auth = self.auth

  -- Opened on first use, so an unused cache costs nothing at startup.
  self.shelf_cache = ShelfCache:new {
    path = ("%s/%s"):format(DataStorage:getSettingsDir(), "hardcovershelf_cache.lua"),
    open = function(path) return LuaSettings:open(path) end,
  }

  -- Your lists, your shelves and every book on them, kept once each (see book_store.lua). Also opened
  -- on first use; closed with this plugin (onCloseWidget).
  self.library_db = SqliteStore:new {
    path = ("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_library.sqlite3"),
  }
  self.book_store = BookStore:new { db = self.library_db }
  self.list_store = ListStore:new { db = self.library_db, books = self.book_store }
  self.shelf_store = ShelfStore:new { db = self.library_db, books = self.book_store }
  self.journal_store = JournalStore:new { db = self.library_db }
  self.review_store = ReviewStore:new { db = self.library_db }

  self.sync_queue = SyncQueue:new {
    settings = LuaSettings:open(("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_queue.lua"))
  }

  -- goal changes made offline wait in the same file as the progress queue
  self.goal_queue = GoalQueue:new { settings = self.sync_queue.settings }
  -- so are ratings set offline from the book details screen
  self.rating_queue = RatingQueue:new { settings = self.sync_queue.settings }
  -- and so are shelf and list changes made from a book's details
  self.shelf_queue = ShelfQueue:new { settings = self.sync_queue.settings }
  self.list_queue = ListQueue:new { settings = self.sync_queue.settings }
  -- and so are notes and quotes written for a book
  self.journal_queue = JournalQueue:new { settings = self.sync_queue.settings }
  -- and so are reviews written from a book's details
  self.review_queue = ReviewQueue:new { settings = self.sync_queue.settings }

  User.settings = self.settings
  Api.on_error = function(err)
    if not err or not self.enabled then
      return
    end

    -- With OAuth a rejected token is usually recoverable: Auth has already
    -- marked it expired and will refresh on the next call. Only a static API
    -- key needs the user to intervene, so only that case disables the plugin.
    if self.auth and self.auth:usingOAuth() then
      return
    end

    if err == HARDCOVER.ERROR.TOKEN or _t.dig(err, "extensions", "code") == HARDCOVER.ERROR.JWT or (err.message and string.find(err.message, "JWT")) then
      self:disable()
      StatusDialogs.error("Your Hardcover API key is not valid or has expired. Please update it and restart")
    end
  end

  self.cache = Cache:new {
    settings = self.settings,
    state = self.state,
    sync_queue = self.sync_queue,
    -- a status set from the reader moves the book on the saved shelves, as one set in the Library does
    on_shelf_changed = function(book_id, old_status_id, status_id, user_book_id, unsent, info)
      local dm = self.dialog_manager
      if not (dm and dm.shelfChanged) then return end
      if old_status_id == nil then
        -- not known from the book's own status: the saved shelves may say where it was
        local store = dm.shelves and dm:shelves()
        local m = store and store:member(User:getId(), book_id)
        old_status_id = m and m.status_id
      end
      dm:shelfChanged(book_id, old_status_id, status_id, user_book_id, unsent, info)
    end,
  }
  self.page_mapper = PageMapper:new {
    state = self.state,
    ui = self.ui,
  }
  self.wifi = AutoWifi:new {
    settings = self.settings
  }
  self.dialog_manager = DialogManager:new {
    page_mapper = self.page_mapper,
    settings = self.settings,
    shelf_cache = self.shelf_cache,
    book_store = self.book_store,
    list_store = self.list_store,
    shelf_store = self.shelf_store,
    journal_store = self.journal_store,
    review_store = self.review_store,
    -- books finished offline, for the reading goal's number
    sync_queue = self.sync_queue,
    -- goals made or changed offline, and the way to send them
    goal_queue = self.goal_queue,
    rating_queue = self.rating_queue,
    shelf_queue = self.shelf_queue,
    list_queue = self.list_queue,
    journal_queue = self.journal_queue,
    review_queue = self.review_queue,
    flush_goals = function() self:flushSyncQueue(false) end,
    -- Home's sync box: Sync now sends, and the rest of the box opens the list (the menu's)
    send_now = function() self.menu:sendPending() end,
    show_pending = function() self.menu:showPendingChanges() end,
    -- the settings, for the home screen's Settings button; read when asked, as
    -- the menu is built after this
    settings_items = function()
      return self.menu and self.menu:getHomeSettingsItems() or {}
    end,
    -- the details screen's Edition button opens the menu's link actions (the menu is built below)
    show_link_actions = function(on_close) self.menu:showLinkActions(on_close) end,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }
  self.hardcover = Hardcover:new {
    cache = self.cache,
    dialog_manager = self.dialog_manager,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }

  self.menu = HardcoverMenu:new {
    enabled = true,

    auth = self.auth,
    book_store = self.book_store,
    cache = self.cache,
    dialog_manager = self.dialog_manager,
    hardcover = self.hardcover,
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    sync_queue = self.sync_queue,
    goal_queue = self.goal_queue,
    rating_queue = self.rating_queue,
    shelf_queue = self.shelf_queue,
    list_queue = self.list_queue,
    journal_queue = self.journal_queue,
    review_queue = self.review_queue,
    ui = self.ui,
    wifi = self.wifi,
    on_flush_sync_queue = function() self:on_flush_sync_queue() end,
    on_sign_in = function(on_done) self:signIn(on_done) end,
    on_sign_out = function()
      -- the cache holds this account's library, so it goes with the sign in
      self.review_store:invalidate()
      self.shelf_cache:clear()
      self.book_store:clear()
      self.auth:signOut()
      BookshelfSources.changed(self)
    end,
  }

  -- Register optional Bookshelf sources when its source API is available.
  if not BookshelfSources.register(self) then
    UIManager:nextTick(function() BookshelfSources.register(self) end)
  end

  -- Bookshelf loads spec files from its settings folder; this feeds it the goal and stats cards.
  pcall(BookshelfModules.install, self)

  FileDialog.register(self)

  self:onDispatcherRegisterActions()
  self:initializePageUpdate()
  self.ui.menu:registerToMainMenu(self)
end

function HardcoverApp:_bookSettingChanged(setting, key)
  return setting[key] ~= nil or _t.contains(_t.dig(setting, "_delete"), key)
end

-- Open note dialog
--
-- UIManager:broadcastEvent(Event:new("HardcoverNote", note_params))
--
-- note_params can contain:
--   text: Value will prepopulate the note section
--   page_number: The local page number
--   remote_page (optional): The mapped page in the linked book edition
--   note_type: one of "quote" or "note"
function HardcoverApp:onHardcoverNote(note_params)
  -- open journal dialog
  self.dialog_manager:journalEntryForm(
    note_params.text,
    self.ui.document,
    note_params.page_number,
    self.settings:pages(),
    note_params.remote_page,
    note_params.note_type or "quote"
  )
end

--
-- Start the OAuth device flow: fetch a code, then show it and poll.
--
-- `on_done` is called once the user has signed in (not when the dialog only opens).
function HardcoverApp:signIn(on_done)
  if not self.auth or not self.auth:usingOAuth() then
    return
  end

  if not NetworkManager:isConnected() then
    StatusDialogs.error(_("Connect to the internet to sign in"), 3)
    return
  end

  -- Show a "signing in" indicator straight away, before the network call.
  --
  -- beginDeviceFlow() is a blocking HTTPS request, and it used to run before
  -- anything was displayed. When it stalled, the screen simply never changed,
  -- which on e-ink looks identical to a refresh failure. The indicator means
  -- there is always something on screen, and it is replaced by the code entry
  -- dialog or by an error.
  local working = StatusDialogs.loading(_("Contacting Hardcover\u{2026}"))

  -- UIManager:show only queues the widget; nothing is drawn until the event
  -- loop runs, which the blocking call below prevents. Paint it now.
  UIManager:forceRePaint()

  local device, err = self.auth:beginDeviceFlow()

  StatusDialogs.close(working)

  if not device then
    local message = "Could not start sign in"
    if err and err.error == "timeout" then
      message = "Sign in timed out. Please try again."
    end

    StatusDialogs.error(_(message), 3)
    return
  end

  -- required here, not at the top: only needed when signing in
  local SignInDialog = require("hardcover/lib/ui/signin_dialog")
  local dialog = SignInDialog:new {
    auth = self.auth,
    device = device,
  }

  -- on success, clear any cached user id: a different account may be signed in
  dialog.success_callback = function()
    User:forget()
    BookshelfSources.changed(self)
    if on_done then on_done() end
  end

  -- onShowSignIn shows the dialog and starts polling, so do not show it here as
  -- well: showing the same widget twice puts two entries in UIManager's window
  -- stack for one screen.
  dialog:onShowSignIn()
end

function HardcoverApp:disable()
  self.enabled = false
  if self.menu then
    self.menu.enabled = false
  end
  self:registerHighlight()
end

function HardcoverApp:onHardcoverLink()
  if not self.ui.document then return end
  self.hardcover:showLinkBookDialog(false, function(book)
    StatusDialogs.info(_("Linked to: " .. book.title))
  end)
end

function HardcoverApp:onHardcoverHome()
  self.dialog_manager:showHome()
  return true
end

function HardcoverApp:onHardcoverOpen()
  self.menu:open()
  return true
end

function HardcoverApp:onHardcoverBook()
  self.menu:showReaderPanel()
  return true
end

function HardcoverApp:onHardcoverTrack()
  if not self.ui.document then return end
  self.settings:setSync(true)
  UIManager:nextTick(function()
    StatusDialogs.info(_("Progress tracking enabled"))
  end)
end

function HardcoverApp:onHardcoverStopTrack()
  if not self.ui.document then return end
  self.settings:setSync(false)
  StatusDialogs.info(_("Progress tracking disabled"))
end

function HardcoverApp:onHardcoverUpdateProgress()
  if self.ui.document and self.settings:bookLinked() then
    -- In the background so the request does not freeze the reader. The updates
    -- sent when the document closes or the device suspends deliberately stay
    -- blocking: they have to finish before the device goes away.
    Background.run(function()
      self:updatePageNow(function(result)
        if result then
          local text = result.queued and _("Progress saved offline, will sync") or _("Progress updated")
          StatusDialogs.info(text)
        else
          logger.warn("Unsuccessful updating page progress", self.ui.document.file)
        end
      end)
    end)
  else
    logger.warn(self.state.book_status)
    local error
    if not self.ui.document then
      error = "No book active"
    elseif not self.state.book_status.id then
      error = "Book has not been mapped"
    end

    local error_message = error and "Unable to update reading progress: " .. error or "Unable to update reading progress"
    StatusDialogs.error(error_message)
  end
end

function HardcoverApp:onSettingsChanged(field, change, original_value)
  if field == SETTING.BOOKS then
    local book_settings = change.config
    -- (only a real change: Bookshelf's shelves are kept in memory, and a progress sync saves the same status again)
    if HardcoverSettings.statusChanged(book_settings, original_value) then
      BookshelfSources.invalidate(self)
    end
    if self:_bookSettingChanged(book_settings, "sync") then
      if book_settings.sync then
        if not self.state.book_status.id then
          self:startReadCache()
        end
      else
        self:cancelPendingUpdates()
      end
    end

    if self:_bookSettingChanged(book_settings, "book_id") then
      self:registerHighlight()
    end
  elseif field == SETTING.TRACK_METHOD or field == SETTING.TRACK_FREQUENCY then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.LINK_BY_HARDCOVER or field == SETTING.LINK_BY_ISBN or field == SETTING.LINK_BY_TITLE then
    if change then
      self.hardcover:tryAutolink()
    end
  end
end

function HardcoverApp:effectiveStatusId(filename)
  local pending = self.sync_queue:statusOf(filename)
  if pending then
    return pending
  end
  return self.state.book_status and self.state.book_status.status_id
end

-- What a page turn does to the book, from what the device knows (see BookActions.pageWrite).
function HardcoverApp:pageWriteDecision(filename)
  return BookActions.pageWrite(self:effectiveStatusId(filename))
end

-- A book that is not being read: pages turned forward are counted here, and once there are enough
-- the reader is asked whether to start it. Nothing is sent or queued until they say yes.
function HardcoverApp:countPageForStart(filename, old_page, new_page)
  self.state.start_reading = self.state.start_reading or StartReading.new()
  if StartReading.turn(self.state.start_reading, old_page, new_page, self.settings:startReadingPages()) then
    self:askToStartReading(filename)
  end
end

function HardcoverApp:askToStartReading(filename)
  local state = self.state.start_reading
  StatusDialogs.confirm {
    title = _("Start reading this book?"),
    text = _("Set it to Currently Reading on Hardcover, and update it as you read."),
    ok_text = _("Start reading"),
    cancel_text = _("Not now"),
    ok_callback = function() self:startReading(filename) end,
    cancel_callback = function() if state then StartReading.declined(state) end end,
  }
end

-- "Start reading": after the reader confirms, move a Want to Read book or one with an unknown
-- status to Currently Reading, then send its current page. Keep the prompt from overwriting a
-- different status if the book changed while it was open.
function HardcoverApp:startReading(filename)
  Trapper:wrap(function()
    local status_id = self:effectiveStatusId(filename)
    if status_id ~= nil
      and status_id ~= HARDCOVER.STATUS.TO_READ
      and status_id ~= HARDCOVER.STATUS.READING then
      return
    end
    if not self.settings:syncEnabled() then
      self.settings:setSync(true)
      self.state.process_page_turns = true
    end
    if status_id ~= HARDCOVER.STATUS.READING then
      self.cache:updateBookStatus(filename, HARDCOVER.STATUS.READING)
      StatusDialogs.info(_("Now on your 'Currently Reading' shelf"), 2)
    end
    self:updatePageNowForced(filename)
  end)
end

function HardcoverApp:updatePageNowForced(filename)
  local page = self.ui.getCurrentPage and self.ui:getCurrentPage() or self.state.page
  local mapped_page = self.page_mapper:getMappedPage(page, self.ui.document:getPageCount(), self.settings:pages())
  self.cache:syncPage(filename, mapped_page)
end

function HardcoverApp:_handlePageUpdate(filename, mapped_page, immediate, callback)
  --logger.warn("HARDCOVER: Throttled page update", mapped_page)
  self.page_update_pending = false

  if not self:syncFileUpdates(filename) then
    return
  end

  if self:pageWriteDecision(filename) ~= "allow" then
    return
  end

  local immediate_update = function()
    -- decided again here, not above: the update can wait a second, and the status can change in it
    if self:pageWriteDecision(filename) ~= "allow" then
      return
    end
    local result = self.cache:syncPage(filename, mapped_page)
    if callback then
      callback(result)
    end
  end

  local trapped_update = function()
    Trapper:wrap(immediate_update)
  end

  if immediate then
    immediate_update()
  else
    UIManager:scheduleIn(1, trapped_update)
  end
end

function HardcoverApp:initializePageUpdate()
  local track_frequency = math.max(math.min(self.settings:trackFrequency(), 120), 1) * 60

  HardcoverApp._throttledHandlePageUpdate, HardcoverApp._cancelPageUpdate = throttle(
    track_frequency,
    HardcoverApp._handlePageUpdate
  )

  HardcoverApp._debouncedPageUpdate, HardcoverApp._cancelPageUpdateEvent = debounce(2, HardcoverApp.pageUpdateEvent)
end

-- Observe every turn before debouncing: a rapid run of turns must not look like
-- one large jump, and a glance back must cancel any pending automatic write.
function HardcoverApp:observePage(page)
  local previous = self.state.observed_page or self.state.page
  if previous and page and page ~= previous then
    local step = page - previous
    if step < -StartReading.MAX_STEP then
      self.state.rereading_pages = 0
      if self._cancelPageUpdate then self:_cancelPageUpdate() end
      if self._cancelPageUpdateEvent then self:_cancelPageUpdateEvent() end
      self.page_update_pending = false
    elseif self.state.rereading_pages then
      if step > 0 and step <= StartReading.MAX_STEP then
        self.state.rereading_pages = self.state.rereading_pages + step
        if self.state.rereading_pages >= 5 then self.state.rereading_pages = nil end
      elseif step < 0 or step > StartReading.MAX_STEP then
        self.state.rereading_pages = 0
      end
    end
  end
  self.state.observed_page = page
  return not self.state.rereading_pages
end

function HardcoverApp:onPageUpdate(page)
  local may_sync = self:observePage(page)
  if may_sync and self.settings:syncEnabled() then self.page_update_pending = true end
  self:_debouncedPageUpdate(page)
end

function HardcoverApp:pageUpdateEvent(page)
  if not self.ui.document then return end
  self.state.last_page = self.state.page
  self.state.page = page
  self:checkLastPage(page)

  if not (self.state.book_status.id or self.settings:bookLinked()) then
    return
  end
  --logger.warn("HARDCOVER page update event pending")
  -- counted whether or not tracking is on: tracking is off for every book until it is turned on,
  -- and "start reading?" is how a book that is not being read gets there
  if self:pageWriteDecision(self.ui.document.file) == "ask" then
    self:countPageForStart(self.ui.document.file, self.state.last_page, page)
  end
  if not self.settings:syncEnabled() or self.state.rereading_pages then
    return
  end
  local document_pages = self.ui.document:getPageCount()
  local remote_pages = self.settings:pages()

  if self.settings:trackByTime() then
    local mapped_page = self.page_mapper:getMappedPage(page, document_pages, remote_pages)

    self:_throttledHandlePageUpdate(self.ui.document.file, mapped_page)
    self.page_update_pending = true
  elseif self.settings:trackByProgress() and self.state.last_page then
    local percent_interval = self.settings:trackPercentageInterval()

    local previous_percent = self.page_mapper:getRemotePagePercent(
      self.state.last_page,
      document_pages,
      remote_pages
    )

    local current_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      document_pages,
      remote_pages
    )

    local last_compare = math.floor(previous_percent * 100 / percent_interval)
    local current_compare = math.floor(current_percent * 100 / percent_interval)

    if last_compare ~= current_compare then
      self:_handlePageUpdate(self.ui.document.file, mapped_page)
    end
  end
end

function HardcoverApp:onPosUpdate(_, page)
  if self.state.process_page_turns then
    local may_sync = self:observePage(page)
    if may_sync and self.settings:syncEnabled() then self.page_update_pending = true end
    self:pageUpdateEvent(page)
  end
end

function HardcoverApp:onUpdatePos()
  self.page_mapper:cachePageMap()
end

function HardcoverApp:onReaderReady()
  --logger.warn("HARDCOVER on ready")

  self.page_mapper:cachePageMap()
  self:registerHighlight()
  self.state.page = self.ui:getCurrentPage()
  self.state.observed_page = self.state.page
  self.state.rereading_pages = nil

  if self.ui.document and (self.settings:syncEnabled() or (not self.settings:bookLinked() and self.settings:autolinkEnabled())) then
    UIManager:scheduleIn(2, self.startReadCache, self)
  elseif self.ui.document and self.settings:bookLinked() then
    -- tracking is off: nothing is sent, but page turns are still counted for "Start reading this book?"
    self.cache:hydrateBookStatus(self.ui.document.file)
    self.state.process_page_turns = true
  end

  UIManager:scheduleIn(3, self.askAboutOpenBook, self)
end

function HardcoverApp:cancelPendingUpdates()
  if self._cancelPageUpdate then
    self:_cancelPageUpdate()
  end

  if self._cancelPageUpdateEvent then
    self:_cancelPageUpdateEvent()
  end

  self.page_update_pending = false
end

function HardcoverApp:onCloseDocument()
  UIManager:unschedule(self.startReadCache)
  UIManager:unschedule(self.askAboutOpenBook)
  UIManager:unschedule(self.askAtLastPage)
  UIManager:unschedule(self.checkEndMenu)

  local document = self.ui.document
  local file_path = document and document.file
  if file_path then
    local page = self.ui.getCurrentPage and self.ui:getCurrentPage() or self.state.page
    self:observePage(page)
    if EndOfBook.atLastPage(page, document:getPageCount()) then self:checkLastPage(page) end
    local marked = self:markIfMarkedFinished(file_path)
    if not marked and EndOfBook.atLastPage(page, document:getPageCount())
      and self:syncFileUpdates(file_path)
      and self:effectiveStatusId(file_path) ~= HARDCOVER.STATUS.FINISHED
      and not (self.state.end_asked and self.state.end_asked[file_path])
      and EndOfBook.promptOnLastPage(self.settings:endPrompt(), G_reader_settings:readSetting("end_document_action")) then
      UIManager:nextTick(function() self:askAtLastPage(file_path) end)
    end
  end

  local had_pending = self.page_update_pending and not self.state.rereading_pages
  self:cancelPendingUpdates()
  self.state.read_cache_started = false
  self.state.start_reading = nil
  self.state.jump_offered = nil
  self.state.observed_page = nil
  self.state.rereading_pages = nil

  if not self.state.book_status.id and not self.settings:syncEnabled() and not self.sync_queue:hasPending() then
    self.state.process_page_turns = false
    self.page_update_pending = false
    self.state.book_status = {}
    self.state.book_status_fetched = false
    self.state.page_map = nil
    return
  end

  if had_pending and self.ui.document then
    self:updatePageNow()
  end

  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    self:flushSyncQueue(true)
  elseif NetworkManager:isConnected() then
    -- already online: no need to switch wifi on, just send what is queued
    self:flushSyncQueue(false)
  end

  self.state.process_page_turns = false
  self.page_update_pending = false
  self.state.book_status = {}
  self.state.book_status_fetched = false
  self.state.page_map = nil
end

-- KOReader is closing the screen this plugin belongs to (switching between the file
-- browser and a book, or quitting): stop the list downloads and let the database go. The
-- next screen's plugin opens it again when it needs it.
function HardcoverApp:onCloseWidget()
  if self.dialog_manager then self.dialog_manager.closed = true end
  if self.library_db then self.library_db:close() end
end

function HardcoverApp:onSuspend()
  -- a cover download for offline stops; running it again carries on
  if self.dialog_manager and self.dialog_manager.stopCoverDownload then self.dialog_manager:stopCoverDownload() end
  if self.ui.document and self.ui.getCurrentPage then self:observePage(self.ui:getCurrentPage()) end
  local had_pending = self.page_update_pending and not self.state.rereading_pages
  self:cancelPendingUpdates()

  if had_pending and self.ui.document then
    self:updatePageNow()
  end

  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    self:flushSyncQueue(true)
  elseif NetworkManager:isConnected() then
    -- already online: no need to switch wifi on, just send what is queued
    self:flushSyncQueue(false)
  end

  Scheduler:clear()
  self.state.read_cache_started = false
end

function HardcoverApp:onResume()
  -- deliberately not gated on connectivity: startReadCache hydrates from the
  -- local snapshot when offline, which is what enables offline tracking
  if self.ui.document and self.settings:syncEnabled() then
    UIManager:scheduleIn(2, self.startReadCache, self)
  end
  if NetworkManager:isConnected() then
    UIManager:scheduleIn(2, self.flushSyncQueue, self, false)
  end
end

function HardcoverApp:updatePageNow(callback)
  -- state.page is the page of the last debounced event; the reader may have
  -- turned further in the two seconds since. Use the page on screen.
  local page = self.ui.getCurrentPage and self.ui:getCurrentPage() or self.state.page
  local mapped_page = self.page_mapper:getMappedPage(
    page,
    self.ui.document:getPageCount(),
    self.settings:pages()
  )
  self:_handlePageUpdate(self.ui.document.file, mapped_page, true, callback)
end

function HardcoverApp:onNetworkDisconnecting()
  --logger.warn("HARDCOVER on disconnecting")
  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    return
  end

  local had_pending = self.page_update_pending
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false

  -- Keep tracking after a mid-session disconnect: the snapshot plus whatever
  -- is already queued is enough to record progress offline, so rebuild the
  -- status and restart the cache pass instead of waiting for a reconnect.
  if self.ui.document and self.settings:syncEnabled() and not self.state.book_status.id then
    if self.cache:hydrateBookStatus(self.ui.document.file) then
      self.state.book_status_fetched = false
      UIManager:scheduleIn(1, self.startReadCache, self)
    end
  end

  if had_pending and self.ui.document and self.settings:syncEnabled() and self.settings:trackByTime() then
    self:updatePageNow()
  end
  self.page_update_pending = false
end

function HardcoverApp:onNetworkConnected()
  if self.ui.document and self.settings:syncEnabled() and not self.state.read_cache_started then
    --logger.warn("HARDCOVER on connected", self.state.read_cache_started)

    self:startReadCache()
  end
  self:flushSyncQueue(false)
end

function HardcoverApp:on_flush_sync_queue()
  -- pressing Sync is the user asking again: let goal changes Hardcover refused try once more
  if self.goal_queue then self.goal_queue:retryHeld() end
  if self.shelf_queue then self.shelf_queue:retryHeld() end
  if self.list_queue then self.list_queue:retryHeld() end
  if self.journal_queue then self.journal_queue:retryHeld() end
  if self.review_queue then self.review_queue:retryHeld() end
  if self.rating_queue then self.rating_queue:retryHeld() end
  local pending = self.sync_queue:changeCount() + (self.goal_queue and self.goal_queue:count() or 0)
    + (self.rating_queue and self.rating_queue:count() or 0)
    + (self.shelf_queue and self.shelf_queue:count() or 0)
    + (self.list_queue and self.list_queue:count() or 0)
    + (self.journal_queue and self.journal_queue:count() or 0)
    + (self.review_queue and self.review_queue:count() or 0)

  if pending == 0 then
    StatusDialogs.info(_("Nothing to sync"), 2)
    return
  end

  if not NetworkManager:isConnected() then
    StatusDialogs.info(T(_("%1 change(s) saved. They will sync when you are online."), pending), 3)
    return
  end

  local done = function(success)
    if success then
      StatusDialogs.info(_("Progress synced"), 2)
    else
      StatusDialogs.error(_("Sync failed. Changes are saved and will retry."), 3)
    end
  end

  self:flushSyncQueue(false, done)
end

-- Seconds to wait before trying a failed flush again while still online: the
-- server answering 429/5xx is exactly when queued changes matter, and nothing
-- else would trigger another attempt until the next connect or resume.
local FLUSH_RETRY_DELAYS = { 30, 120, 600, 1800 }

function HardcoverApp:_scheduleFlushRetry(success)
  if success then
    self.flush_retries = 0
    return
  end

  -- entries the server keeps refusing are held and wait for the user; retrying
  -- them here would only repeat the refusal
  local held = self.sync_queue.heldCount and self.sync_queue:heldCount() or 0
  if self.sync_queue:pendingCount() <= held then
    return
  end

  local attempt = (self.flush_retries or 0) + 1
  local delay = FLUSH_RETRY_DELAYS[attempt]
  if not delay then
    return
  end
  self.flush_retries = attempt

  UIManager:unschedule(self._retryFlush)
  self._retryFlush = function()
    if NetworkManager:isConnected() then
      self:flushSyncQueue(false)
    end
  end
  UIManager:scheduleIn(delay, self._retryFlush)
end

-- A sync can end with questions only the user can answer (this device and
-- Hardcover disagree about where they are in a book). Say so once per new
-- question; the answers are in the Sync menu.
function HardcoverApp:_noticeSyncConflicts()
  if not self.sync_queue.conflictCount then return end
  local count = self.sync_queue:conflictCount()
  if count > 0 and count ~= self.noticed_conflicts then
    StatusDialogs.info(SyncConflicts.notice(count), 5)
  end
  self.noticed_conflicts = count
end

-- The page of this file for a page of the edition Hardcover has, by the book's page labels when
-- it has them. nil when the edition's length is not known.
function HardcoverApp:jumpTarget(edition_page)
  return SyncConflicts.documentPage(edition_page, self.settings:pages(), self.ui.document:getPageCount(),
    function(page, document_pages, edition_pages)
      return self.page_mapper:getUnmappedPage(page, document_pages, edition_pages)
    end)
end

-- Opening a book that has a question waiting: ask it there, where the reader is
-- thinking about the book. And if the user earlier chose Hardcover's page for it,
-- offer to jump there.
function HardcoverApp:askAboutOpenBook()
  local file = self.ui.document and self.ui.document.file
  if not file or not self.sync_queue.conflicts then return end

  local resume = self.sync_queue:takeResumePage(file)
  local function offer_jump()
    local target = self:jumpTarget(resume)
    if not target then return end
    StatusDialogs.confirm {
      title = T(_("Jump to page %1?"), resume),
      text = _("Hardcover is further along than this device."),
      ok_text = _("Jump"),
      cancel_text = _("Stay here"),
      ok_callback = function()
        self.ui:handleEvent(Event:new("GotoPage", target))
      end,
    }
  end

  local entry = self.sync_queue:get(file)
  if type(entry) == "table" and entry.conflict then
    require("hardcover/lib/ui/sync_conflict_dialog").show {
      queue = self.sync_queue,
      only = file,
      on_done = function(resolved)
        if resume then offer_jump() end
        if resolved > 0 then self:flushSyncQueue(false) end
      end,
    }
  elseif resume then
    offer_jump()
  end
end

-- Online with the book open, Hardcover has you further along than this device
-- (you read on another device): offer to jump there, once per opening. Skipped
-- when this device has changes waiting (the sync conflict question covers it),
-- when the book is not being read, and after a "Stay here" for that same page.
function HardcoverApp:offerJumpToCloudPage()
  local file = self.ui.document and self.ui.document.file
  if not file or self.state.jump_offered or not NetworkManager:isConnected() then return end
  if self.sync_queue:hasPending(file) then return end

  local status = self.state.book_status
  if not (status and status.id and status.status_id == HARDCOVER.STATUS.READING) then return end
  local reads = status.user_book_reads
  local cloud_page = reads and reads[#reads] and tonumber(reads[#reads].progress_pages)
  local pages = self.settings:pages()
  local document_pages = self.ui.document:getPageCount()
  local current = self.ui.getCurrentPage and self.ui:getCurrentPage()
  if not (cloud_page and pages and current) then return end

  local local_page = self.page_mapper:getMappedPage(current, document_pages, pages)
  local declined = self.settings:readBookSetting(file, "jump_declined_page")
  if not SyncConflicts.shouldOfferJump(cloud_page, local_page, declined, SyncQueue.CONFLICT_PAGES) then return end

  local target = self:jumpTarget(cloud_page)
  if not target then return end
  self.state.jump_offered = true
  StatusDialogs.confirm {
    title = T(_("Jump to page %1?"), cloud_page),
    text = _("Hardcover is further along than this device."),
    ok_text = _("Jump"),
    cancel_text = _("Stay here"),
    ok_callback = function()
      self.ui:handleEvent(Event:new("GotoPage", target))
    end,
    cancel_callback = function()
      self.settings:updateBookSetting(file, { jump_declined_page = cloud_page })
    end,
  }
end

-- Send the goal changes made offline. Returns false when something is still
-- waiting for another try (nothing is lost; held ones wait for the user).
function HardcoverApp:_flushGoals()
  local queue = self.goal_queue
  if not queue or queue:isEmpty() then
    return true
  end

  local sent, archived = {}, {}
  local result = queue:flush(Api, {
    user_id = User:getId(),
    on_saved = function(key, goal) sent[#sent + 1] = { key = key, goal = goal } end,
    on_archived = function(key) archived[#archived + 1] = key end,
  })
  self.dialog_manager:goalsFlushed(sent, archived)

  if result.held > 0 and result.held ~= self.noticed_held_goals then
    StatusDialogs.info(_("A goal change could not be sent. Open Goals to see which, or sign out and back in if it asks."), 5)
  end
  self.noticed_held_goals = result.held
  return not result.stopped and result.waiting == result.held
end

-- Send the ratings set offline. Returns false while any is still waiting.
function HardcoverApp:_flushRatings()
  local queue = self.rating_queue
  if not queue or queue:isEmpty() then
    return true
  end
  local waiting = queue:flush(Api, function(user_book_id, user_book)
    local status = self.state.book_status
    if status and (status.id == user_book_id or (user_book.book_id and status.book_id == user_book.book_id))
      and queue:get(user_book_id, user_book.book_id, User:getId()) == nil then
      -- The first status sync may have replaced the reader's local rating with an older server value.
      status.rating = user_book.rating
    end
    self.dialog_manager:ratingSent(user_book_id, user_book)
  end, User:getId())
  -- (held ones wait for the user, as shelf and list changes do)
  return waiting <= queue:heldCount(User:getId())
end

-- Send the shelf changes made offline. Returns false while any is still waiting for another
-- try (held ones wait for the user).
function HardcoverApp:_flushShelves()
  local queue = self.shelf_queue
  if not queue or queue:isEmpty() then
    return true
  end
  local result = queue:flush(Api, {
    user_id = User:getId(),
    on_sent = function(op, user_book) self.dialog_manager:shelfSent(op, user_book) end,
  })
  self:_noticeHeld("shelf", result.held)
  return not result.stopped and result.waiting == result.held
end

-- Send the list changes made offline (as _flushShelves).
function HardcoverApp:_flushLists()
  local queue = self.list_queue
  if not queue or queue:isEmpty() then
    return true
  end
  local result = queue:flush(Api, {
    user_id = User:getId(),
    on_sent = function(op, answer) self.dialog_manager:listChangeSent(op, answer) end,
  })
  self:_noticeHeld("list", result.held)
  return not result.stopped and result.waiting == result.held
end

-- Send the notes and quotes written offline (as _flushShelves). The dialog manager has nothing
-- to refresh for one: an entry sent is simply gone from the queue.
function HardcoverApp:_flushJournals()
  local queue = self.journal_queue
  if not queue or queue:isEmpty() then
    return true
  end
  local result = queue:flush(Api, { user_id = User:getId(), json = json,
    on_sent = function(op) self.dialog_manager:journalChangeSent(op) end })
  self:_noticeHeld("journal", result.held)
  return not result.stopped and result.waiting == result.held
end

-- Send reviews after shelf changes, resolving the library record for a newly added book.
function HardcoverApp:_flushReviews()
  local queue = self.review_queue
  if not queue or queue:isEmpty() then
    return true
  end
  local waiting = queue:flush(Api, { json = json, user_id = User:getId(),
    on_sent = function(user_book_id, user_book)
      local has = type(user_book) == "table" and user_book.has_review ~= false
      self.dialog_manager:reviewChangeSent(user_book_id, has and user_book.review_raw or nil,
        has and user_book.review_has_spoilers)
    end })
  self:_noticeHeld("review", queue:heldCount(User:getId()))
  return waiting <= queue:heldCount(User:getId())
end

-- Say once when changes are held that Hardcover refused (or that need signing in again).
function HardcoverApp:_noticeHeld(kind, held)
  self.noticed_held = self.noticed_held or {}
  if held > 0 and held ~= self.noticed_held[kind] then
    StatusDialogs.info(kind == "journal" and _("A note could not be sent. Sync shows which.")
      or kind == "review" and _("A review could not be sent. Sync shows which.")
      or _("A shelf or list change could not be sent. Sync shows which."), 5)
  end
  self.noticed_held[kind] = held
end

function HardcoverApp:flushSyncQueue(use_wifi, callback)
  local goals_waiting = (self.goal_queue and not self.goal_queue:isEmpty())
    or (self.rating_queue and not self.rating_queue:isEmpty())
    or (self.shelf_queue and not self.shelf_queue:isEmpty())
    or (self.list_queue and not self.list_queue:isEmpty())
    or (self.journal_queue and not self.journal_queue:isEmpty())
    or (self.review_queue and not self.review_queue:isEmpty())
  if not goals_waiting and (not self.sync_queue or not self.sync_queue:hasPending()) then
    if callback then
      callback(true)
    end
    return
  end

  local run = function()
    -- A flush yields while a request is out, so a second trigger (Sync tap, reconnect,
    -- resume) can arrive meanwhile. The queues answer such a flush "busy", which would
    -- read as a failure; do not start one, and tell the caller what the running one finds.
    if self.flush_running then
      if callback then
        self.flush_waiters = self.flush_waiters or {}
        table.insert(self.flush_waiters, callback)
      end
      return
    end
    self.flush_running = true
    Trapper:wrap(function()
      local flushed, success = pcall(function()
        -- a status changed on both the reader and the details screen: only the newer is sent
        if self.shelf_queue then self.shelf_queue:settleWith(self.sync_queue) end
        local success = self.sync_queue:flush(Api, {
          user_id = User:getId(),
          settings = self.settings,
          current_file = self.ui.document and self.ui.document.file,
          state = self.state,
        })
        -- an empty progress queue flushes to true; a queue with nothing to send for
        -- want of a user id says false, which must not hide the goals
        success = self:_flushGoals() and success
        -- Create/update library records before reviews and ratings look them up.
        success = self:_flushShelves() and success
        success = self:_flushLists() and success
        success = self:_flushJournals() and success
        success = self:_flushReviews() and success
        success = self:_flushRatings() and success

        return success
      end)
      self.flush_running = false -- also after a raise: it must not block every later flush
      if not flushed then error(success, 0) end

      self:_scheduleFlushRetry(success)
      self:_noticeSyncConflicts()
      -- Home's sync box shows what is waiting
      if self.dialog_manager and self.dialog_manager.queueChanged then self.dialog_manager:queueChanged() end

      local waiters = self.flush_waiters
      self.flush_waiters = nil
      if callback then
        callback(success)
      end
      for _, waiting in ipairs(waiters or {}) do waiting(success) end
    end)
  end

  if use_wifi then
    self.wifi:withWifi(function()
      if NetworkManager:isConnected() then
        run()
      elseif callback then
        callback(false)
      end
    end)
  elseif NetworkManager:isConnected() then
    run()
  elseif callback then
    callback(false)
  end
end

-- Write Read for a book that has ended, if the book's status allows it (see BookActions.statusWrite).
-- Decided when the write would happen, not when the book was opened: the status can change in the
-- time between. Every trigger comes through here, so a second one finds the first one's write
-- already counted (the effective status includes a change still waiting in the queue) and does nothing.
-- Returns true when Read was written or queued.
function HardcoverApp:markFinished(file_path, event)
  local decision = BookActions.statusWrite(self:effectiveStatusId(file_path), event)
  if decision == "ask" then
    self:askDidNotFinish(file_path)
    return false
  end
  if decision == "block" then
    return false
  end
  Background.run(function()
    self:finishBook(file_path)
  end)
  return true
end

-- Once the book is Finished page writes are blocked, so the page the reader ended on goes
-- first (offline the queue also sends the page before the status).
function HardcoverApp:finishBook(file_path)
  if self.ui.document and self.ui.document.file == file_path and self:pageWriteDecision(file_path) == "allow" then
    self:updatePageNowForced(file_path)
  end
  self.cache:updateBookStatus(file_path, HARDCOVER.STATUS.FINISHED)
end

function HardcoverApp:markFinishedAndSay(file_path, event)
  if self:markFinished(file_path, event) then
    StatusDialogs.info(_("Hardcover status saved"), 2)
    return true
  end
  return false
end

-- The reader marked this book Finished in KOReader (its pop-up, or the book-status screen): write it.
-- Read from the open book's settings, which hold the answer as soon as it is given.
function HardcoverApp:markIfMarkedFinished(file_path)
  local doc_settings = self.ui and self.ui.doc_settings
  local summary = doc_settings and doc_settings:readSetting("summary")
  if summary and summary.status == "complete" and self:syncFileUpdates(file_path) then
    return self:markFinishedAndSay(file_path, "end_chosen")
  end
  return false
end

function HardcoverApp:onEndOfBook()
  local file_path = self.ui.document.file

  if not self:syncFileUpdates(file_path) then
    return
  end

  local action = G_reader_settings:readSetting("end_document_action")
  local auto_mark = G_reader_settings:isTrue("end_document_auto_mark") or self.settings:endAutoMark()
  local plan = EndOfBook.onEnd(action, auto_mark)

  if plan == "mark" then
    self:markFinishedAndSay(file_path, "end_auto")
  elseif plan == "check_later" then
    -- Wait until KOReader's dialog is gone before reading its answer or asking ours.
    UIManager:unschedule(self.checkEndMenu)
    UIManager:scheduleIn(1, self.checkEndMenu, self)
  end

  -- this plugin's end page, when the reader chose it in KOReader's list of end actions
  if EndOfBook.kind(action) == "hardcover" then
    EndOfBook.once(self.state.end_asked, file_path)
    self.menu:showEndPage()
  end
end

-- The book-status screen closed (see koreader_hooks.lua): if the reader switched the book to
-- Finished there, send it. Whatever they did to the switch is in the book's settings by now.
function HardcoverApp:onHardcoverStatusScreenClosed()
  local file_path = self.ui and self.ui.document and self.ui.document.file
  if file_path then self:markIfMarkedFinished(file_path) end
end

function HardcoverApp:checkLastPage(page)
  local document = self.ui and self.ui.document
  if not document then return end
  local file_path = document.file
  if not EndOfBook.atLastPage(page, self.ui.document:getPageCount()) then return end
  if not self:syncFileUpdates(file_path) then return end
  if self:effectiveStatusId(file_path) == HARDCOVER.STATUS.FINISHED then return end
  if self.settings:endAutoMark() then
    if EndOfBook.once(self.state.end_asked, file_path) then self:markFinishedAndSay(file_path, "end_auto") end
  end
end

function HardcoverApp:checkEndMenu()
  local document = self.ui and self.ui.document
  if not document then return end
  for _, window in ipairs(UIManager._window_stack or {}) do
    if window.widget.name == "end_document" then
      UIManager:scheduleIn(1, self.checkEndMenu, self)
      return
    end
  end
  if self:markIfMarkedFinished(document.file) then return end
  local page = self.ui:getCurrentPage()
  if EndOfBook.atLastPage(page, document:getPageCount())
    and EndOfBook.promptOnLastPage(self.settings:endPrompt(), G_reader_settings:readSetting("end_document_action")) then
    self:askAtLastPage(document.file)
  end
end

function HardcoverApp:askAtLastPage(file_path)
  file_path = file_path or (self.ui and self.ui.document and self.ui.document.file)
  if not file_path or not self:syncFileUpdates(file_path) then return end
  for _, window in ipairs(UIManager._window_stack or {}) do
    if window.widget.name == "end_document" then
      UIManager:scheduleIn(1, self.askAtLastPage, self, file_path)
      return
    end
  end
  if self:markIfMarkedFinished(file_path) then return end
  if self:effectiveStatusId(file_path) == HARDCOVER.STATUS.FINISHED then return end
  if not EndOfBook.once(self.state.end_asked, file_path) then return end
  StatusDialogs.confirm {
    title = _("You've reached the end"),
    text = _("Mark this book as Read on Hardcover?"),
    ok_text = _("Mark as Read"),
    cancel_text = _("Not yet"),
    ok_callback = function() self:markFinishedAndSay(file_path, "end_chosen") end,
  }
end

-- A book marked Did not finish that ends on its own: ask once per book for the session. Either
-- answer is kept for the session, so the question does not come back for the same book.
function HardcoverApp:askDidNotFinish(file_path)
  self.state.did_not_finish_asked = self.state.did_not_finish_asked or {}
  if self.state.did_not_finish_asked[file_path] then
    return
  end
  self.state.did_not_finish_asked[file_path] = true
  StatusDialogs.confirm {
    title = _("You've reached the end"),
    text = _("Hardcover has this as Did not finish. Mark it as Read?"),
    cancel_text = _("Keep as Did not finish"),
    ok_text = _("Mark as Read"),
    ok_callback = function()
      Background.run(function()
        self:finishBook(file_path)
      end)
      StatusDialogs.info(_("Hardcover status saved"), 2)
    end,
  }
end

function HardcoverApp:syncFileUpdates(filename)
  return self.settings:readBookSetting(filename, "book_id") and self.settings:fileSyncEnabled(filename)
end

function HardcoverApp:onDocSettingsItemsChanged(file, doc_settings)
  if not self:syncFileUpdates(file) or not doc_settings then
    return
  end

  local status, event
  if doc_settings.summary.status == "complete" then
    status, event = HARDCOVER.STATUS.FINISHED, "end_auto"
  elseif doc_settings.summary.status == "reading" then
    status, event = HARDCOVER.STATUS.READING, "reading"
  end

  if status and BookActions.statusWrite(self:effectiveStatusId(file), event) == "allow" then
    Background.run(function()
      self.cache:updateBookStatus(file, status)
    end)
    StatusDialogs.info(_("Hardcover status saved"), 2)
  end
end

function HardcoverApp:startReadCache()
  --logger.warn("HARDCOVER start read cache")
  if self.state.read_cache_started then
    --logger.warn("HARDCOVER Cache already started")
    return
  end

  if not self.ui.document then
    --logger.warn("HARDCOVER read cache fired outside of document")
    return
  end

  self.state.read_cache_started = true

  local cancel
  local restart
  local cancelled = false

  -- withRetries dispatches through UIManager:nextTick, so this can in
  -- principle run before withRetries has returned; guard the cancel upvalue
  -- and remember the request so it still takes effect.
  -- `delay` is when to try again; false means "when something changes": no
  -- timer at all, because onNetworkConnected and onResume both start the cache.
  -- Offline with nothing to go on, a timer every minute would only keep waking
  -- the device (and its radio) for nothing.
  restart = function(delay)
    --logger.warn("HARDCOVER restart cache fetch")
    if delay == nil then
      delay = 60
    end
    cancelled = true
    self.state.read_cache_started = false
    if cancel then
      cancel()
    end
    if delay then
      UIManager:scheduleIn(delay, self.startReadCache, self)
    end
  end

  cancel = Scheduler:withRetries(6, 3, function(success, fail)
      Trapper:wrap(function()
        if not self.ui.document then
          -- fail, but cancel retries
          return success()
        end
        local file = self.ui.document.file
        local book_settings = self.settings:readBookSettings(file) or {}
        --logger.warn("HARDCOVER", book_settings)
        if book_settings.book_id then
          if self.state.book_status.id then
            return success()
          end

          -- Offline: rebuild the book status from the last saved snapshot and
          -- start tracking straight away. Page turns are then queued into the
          -- sync queue instead of being dropped, which is the whole point of
          -- offline tracking. Without this the retry loop below would spin
          -- until it gave up and no progress would be recorded at all.
          if not NetworkManager:isConnected() then
            if self.cache:hydrateBookStatus(file) then
              self.state.book_status_fetched = false
              return success()
            end

            -- linked, but nothing cached yet and no network: wait for the
            -- network to come back rather than polling for it
            return restart(false)
          end

          self.wifi:withWifi(function()
            if not NetworkManager:isConnected() then
              return restart(false)
            end

            local err = self.cache:cacheUserBook()
            --if err then
            --logger.warn("HARDCOVER cache error", err)
            --end
            if err and err.completed == false then
              return fail(err)
            end

            success()
          end)
        else
          self.hardcover:tryAutolink()
          if self.settings:bookLinked() and self.settings:syncEnabled() then
            return restart(2)
          end
        end
      end)
    end,

    function()
      if self.settings:syncEnabled() then
        --logger.warn("HARDCOVER enabling page turns")

        self.state.process_page_turns = true
      end
      self:offerJumpToCloudPage()
    end,

    -- a system event, not something the reader did: a plain toast, not a snackbar
    function()
      if NetworkManager:isConnected() then
        UIManager:show(Notification:new {
          text = _("Failed to fetch book information from Hardcover"),
        })
      end
    end)

  -- restart() may have been called before withRetries returned; honour it now
  -- that the cancel handle exists.
  if cancelled then
    cancel()
  end
end

function HardcoverApp:registerHighlight()
  self.ui.highlight:removeFromHighlightDialog(HIGHLIGHT_MENU_NAME)

  if self.enabled and self.settings:bookLinked() then
    self.ui.highlight:addToHighlightDialog(HIGHLIGHT_MENU_NAME, function(this)
      return {
        text_func = function()
          return _("Hardcover quote")
        end,
        callback = function()
          local selected_text = this.selected_text
          local raw_page = selected_text.pos0.page
          if not raw_page then
            raw_page = self.view.document:getPageFromXPointer(selected_text.pos0)
          end
          -- open journal dialog
          self:onHardcoverNote({
            text = selected_text.text,
            page_number = raw_page,
            note_type = "quote"
          })

          this:onClose()
        end,
      }
    end)
  end
end

function HardcoverApp:addToMainMenu(menu_items)
  menu_items.hardcover = self.menu:mainMenu()
end

return HardcoverApp
