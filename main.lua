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

local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local _t = require("hardcover/lib/table_util")
local Api = require("hardcover/lib/hardcover_api")
local Auth = require("hardcover/lib/auth")
local AutoWifi = require("hardcover/lib/auto_wifi")
local Background = require("hardcover/lib/background")
local Cache = require("hardcover/lib/cache")
local Config = require("hardcover/lib/config")
local debounce = require("hardcover/lib/debounce")
local Hardcover = require("hardcover/lib/hardcover")
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local PageMapper = require("hardcover/lib/page_mapper")
local Scheduler = require("hardcover/lib/scheduler")
local ShelfCache = require("hardcover/lib/shelf_cache")
local SyncQueue = require("hardcover/lib/sync_queue")
local GoalQueue = require("hardcover/lib/goal_queue")
local RatingQueue = require("hardcover/lib/rating_queue")
local SyncConflicts = require("hardcover/lib/sync_conflicts")
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
    page_update_pending = false
  }
  --logger.warn("HARDCOVER app init")
  self.settings = HardcoverSettings:new(
    ("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_settings.lua"),
    self.ui
  )
  self.settings:subscribe(function(field, change, original_value) self:onSettingsChanged(field, change, original_value) end)

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

  self.sync_queue = SyncQueue:new {
    settings = LuaSettings:open(("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_queue.lua"))
  }

  -- goal changes made offline wait in the same file as the progress queue
  self.goal_queue = GoalQueue:new { settings = self.sync_queue.settings }
  -- so are ratings set offline from the book details screen
  self.rating_queue = RatingQueue:new { settings = self.sync_queue.settings }

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
      UIManager:show(InfoMessage:new {
        text = "Your Hardcover API key is not valid or has expired. Please update it and restart",
        icon = "notice-warning",
      })
    end
  end

  self.cache = Cache:new {
    settings = self.settings,
    state = self.state,
    sync_queue = self.sync_queue
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
    -- books finished offline, for the reading goal's number
    sync_queue = self.sync_queue,
    -- goals made or changed offline, and the way to send them
    goal_queue = self.goal_queue,
    rating_queue = self.rating_queue,
    flush_goals = function() self:flushSyncQueue(false) end,
    -- the settings, for the home screen's Settings button; read when asked, as
    -- the menu is built after this
    settings_items = function()
      return self.menu and self.menu:getHomeSettingsItems() or {}
    end,
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
    cache = self.cache,
    dialog_manager = self.dialog_manager,
    hardcover = self.hardcover,
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    sync_queue = self.sync_queue,
    goal_queue = self.goal_queue,
    rating_queue = self.rating_queue,
    ui = self.ui,
    wifi = self.wifi,
    on_flush_sync_queue = function() self:on_flush_sync_queue() end,
    on_sign_in = function() self:signIn() end,
    on_sign_out = function()
      -- the cache holds this account's library, so it goes with the sign in
      self.shelf_cache:clear()
      self.auth:signOut()
    end,
  }

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
function HardcoverApp:signIn()
  if not self.auth or not self.auth:usingOAuth() then
    return
  end

  if not NetworkManager:isConnected() then
    UIManager:show(InfoMessage:new {
      text = _("Connect to the internet to sign in"),
      icon = "notice-warning",
      timeout = 3,
    })
    return
  end

  -- Show a "signing in" indicator straight away, before the network call.
  --
  -- beginDeviceFlow() is a blocking HTTPS request, and it used to run before
  -- anything was displayed. When it stalled, the screen simply never changed,
  -- which on e-ink looks identical to a refresh failure. The indicator means
  -- there is always something on screen, and it is replaced by the code entry
  -- dialog or by an error.
  local working = UIManager:show(InfoMessage:new {
    text = _("Contacting Hardcover\u{2026}"),
    icon = "handshake",
    timeout = nil,
  })

  -- UIManager:show only queues the widget; nothing is drawn until the event
  -- loop runs, which the blocking call below prevents. Paint it now.
  UIManager:forceRePaint()

  local device, err = self.auth:beginDeviceFlow()

  UIManager:close(working)

  if not device then
    local message = "Could not start sign in"
    if err and err.error == "timeout" then
      message = "Sign in timed out. Please try again."
    end

    UIManager:show(InfoMessage:new {
      text = _(message),
      icon = "notice-warning",
      timeout = 3,
    })
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
  self.hardcover:showLinkBookDialog(false, function(book)
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
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
  self.settings:setSync(true)
  UIManager:nextTick(function()
    UIManager:show(Notification:new {
      text = _("Progress tracking enabled")
    })
  end)
end

function HardcoverApp:onHardcoverStopTrack()
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Progress tracking disabled")
  })
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
          UIManager:show(Notification:new {
            text = text
          })
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
    UIManager:show(InfoMessage:new {
      text = error_message,
      icon = "notice-warning",
    })
  end
end

function HardcoverApp:onSettingsChanged(field, change, original_value)
  if field == SETTING.BOOKS then
    local book_settings = change.config
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
  elseif field == SETTING.TRACK_METHOD then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.LINK_BY_HARDCOVER or field == SETTING.LINK_BY_ISBN or field == SETTING.LINK_BY_TITLE then
    if change then
      self.hardcover:tryAutolink()
    end
  end
end

function HardcoverApp:effectiveStatusId(filename)
  local pending = self.sync_queue:get(filename)
  if pending and pending.status_id then
    return pending.status_id
  end
  return self.state.book_status and self.state.book_status.status_id
end

function HardcoverApp:_handlePageUpdate(filename, mapped_page, immediate, callback)
  --logger.warn("HARDCOVER: Throttled page update", mapped_page)
  self.page_update_pending = false

  if not self:syncFileUpdates(filename) then
    return
  end

  local status_id = self:effectiveStatusId(filename)
  if status_id and status_id ~= HARDCOVER.STATUS.READING then
    return
  end

  local immediate_update = function()
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

  HardcoverApp.onPageUpdate, HardcoverApp._cancelPageUpdateEvent = debounce(2, HardcoverApp.pageUpdateEvent)
end

function HardcoverApp:pageUpdateEvent(page)
  self.state.last_page = self.state.page
  self.state.page = page

  if not self.settings:syncEnabled() then
    return
  end
  if not (self.state.book_status.id or self.settings:bookLinked()) then
    return
  end
  --logger.warn("HARDCOVER page update event pending")
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

  if self.ui.document and (self.settings:syncEnabled() or (not self.settings:bookLinked() and self.settings:autolinkEnabled())) then
    UIManager:scheduleIn(2, self.startReadCache, self)
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

function HardcoverApp:onDocumentClose()
  UIManager:unschedule(self.startReadCache)
  UIManager:unschedule(self.askAboutOpenBook)

  local had_pending = self.page_update_pending
  self:cancelPendingUpdates()
  self.state.read_cache_started = false

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

function HardcoverApp:onSuspend()
  local had_pending = self.page_update_pending
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
  local pending = self.sync_queue:pendingCount() + (self.goal_queue and self.goal_queue:count() or 0)
    + (self.rating_queue and self.rating_queue:count() or 0)

  if pending == 0 then
    UIManager:show(InfoMessage:new {
      text = _("Nothing to sync"),
      timeout = 2,
    })
    return
  end

  if not NetworkManager:isConnected() then
    UIManager:show(InfoMessage:new {
      text = T(_("%1 change(s) saved. They will sync when you are online."), pending),
      timeout = 3,
    })
    return
  end

  local done = function(success)
    if success then
      UIManager:show(InfoMessage:new {
        text = _("Progress synced"),
        timeout = 2,
      })
    else
      UIManager:show(InfoMessage:new {
        text = _("Sync failed. Changes are saved and will retry."),
        icon = "notice-warning",
        timeout = 3,
      })
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
    UIManager:show(InfoMessage:new {
      text = SyncConflicts.notice(count),
      timeout = 5,
    })
  end
  self.noticed_conflicts = count
end

-- Opening a book that has a question waiting: ask it there, where the reader is
-- thinking about the book. And if the user earlier chose Hardcover's page for it,
-- offer to jump there.
function HardcoverApp:askAboutOpenBook()
  local file = self.ui.document and self.ui.document.file
  if not file or not self.sync_queue.conflicts then return end

  local resume = self.sync_queue:takeResumePage(file)
  local function offer_jump()
    local target = SyncConflicts.documentPage(resume, self.settings:pages(), self.ui.document:getPageCount())
    if not target then return end
    UIManager:show(ConfirmBox:new {
      text = T(_("Hardcover is at page %1. Jump there?"), resume),
      ok_text = _("Jump"),
      ok_callback = function()
        self.ui:handleEvent(Event:new("GotoPage", target))
      end,
    })
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

-- Send the goal changes made offline. Returns false when something is still
-- waiting for another try (nothing is lost; held ones wait for the user).
function HardcoverApp:_flushGoals()
  local queue = self.goal_queue
  if not queue or queue:isEmpty() then
    return true
  end

  local sent, archived = {}, {}
  local result = queue:flush(Api, {
    on_saved = function(key, goal) sent[#sent + 1] = { key = key, goal = goal } end,
    on_archived = function(key) archived[#archived + 1] = key end,
  })
  self.dialog_manager:goalsFlushed(sent, archived)

  if result.held > 0 and result.held ~= self.noticed_held_goals then
    UIManager:show(InfoMessage:new {
      text = _("A goal change could not be sent. Open Goals to see which, or sign out and back in if it asks."),
      timeout = 5,
    })
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
    self.dialog_manager:ratingSent(user_book_id, user_book)
  end)
  return waiting == 0
end

function HardcoverApp:flushSyncQueue(use_wifi, callback)
  local goals_waiting = (self.goal_queue and not self.goal_queue:isEmpty())
    or (self.rating_queue and not self.rating_queue:isEmpty())
  if not goals_waiting and (not self.sync_queue or not self.sync_queue:hasPending()) then
    if callback then
      callback(true)
    end
    return
  end

  local run = function()
    Trapper:wrap(function()
      local success = self.sync_queue:flush(Api, {
        user_id = User:getId(),
        settings = self.settings,
        current_file = self.ui.document and self.ui.document.file,
        state = self.state,
      })
      -- an empty progress queue flushes to true; a queue with nothing to send for
      -- want of a user id says false, which must not hide the goals
      success = self:_flushGoals() and success
      success = self:_flushRatings() and success

      self:_scheduleFlushRetry(success)
      self:_noticeSyncConflicts()

      if callback then
        callback(success)
      end
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

function HardcoverApp:onEndOfBook()
  local file_path = self.ui.document.file

  if not self:syncFileUpdates(file_path) then
    return
  end

  local mark_read = false
  if G_reader_settings:isTrue("end_document_auto_mark") then
    mark_read = true
  end

  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"

    if action == "pop-up" then
      mark_read = 'later'
    end
  end

  if not mark_read then
    return
  end

  local marker = function()
    Background.run(function()
      self.cache:updateBookStatus(file_path, HARDCOVER.STATUS.FINISHED)
    end)
  end

  if mark_read == 'later' then
    UIManager:scheduleIn(30, function()
      local status = "reading"
      if DocSettings:hasSidecarFile(file_path) then
        local summary = DocSettings:open(file_path):readSetting("summary")
        if summary and summary.status and summary.status ~= "" then
          status = summary.status
        end
      end
      if status == "complete" then
        marker()
      end
    end)
  else
    marker()
    UIManager:show(InfoMessage:new {
      text = _("Hardcover status saved"),
      timeout = 2
    })
  end
end

function HardcoverApp:syncFileUpdates(filename)
  return self.settings:readBookSetting(filename, "book_id") and self.settings:fileSyncEnabled(filename)
end

function HardcoverApp:onDocSettingsItemsChanged(file, doc_settings)
  if not self:syncFileUpdates(file) or not doc_settings then
    return
  end

  local status
  if doc_settings.summary.status == "complete" then
    status = HARDCOVER.STATUS.FINISHED
  elseif doc_settings.summary.status == "reading" then
    status = HARDCOVER.STATUS.READING
  end

  if status then
    Background.run(function()
      self.cache:updateBookStatus(file, status)
    end)
    UIManager:show(InfoMessage:new {
      text = _("Hardcover status saved"),
      timeout = 2
    })
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
    end,

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