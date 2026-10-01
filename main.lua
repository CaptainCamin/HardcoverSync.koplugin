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

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local _t = require("hardcover/lib/table_util")
local Api = require("hardcover/lib/hardcover_api")
local Auth = require("hardcover/lib/auth")
local AutoWifi = require("hardcover/lib/auto_wifi")
local Cache = require("hardcover/lib/cache")
local Config = require("hardcover/lib/config")
local debounce = require("hardcover/lib/debounce")
local Hardcover = require("hardcover/lib/hardcover")
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local PageMapper = require("hardcover/lib/page_mapper")
local Scheduler = require("hardcover/lib/scheduler")
local SyncQueue = require("hardcover/lib/sync_queue")
local throttle = require("hardcover/lib/throttle")
local User = require("hardcover/lib/user")

local DialogManager = require("hardcover/lib/ui/dialog_manager")
local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
local SignInDialog = require("hardcover/lib/ui/signin_dialog")

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

  Dispatcher:registerAction("hardcover_update_progress", {
    category = "none",
    event = "HardcoverUpdateProgress",
    title = _("Hardcover: Update progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_random_books", {
    category = "none",
    event = "HardcoverSuggestBook",
    title = _("Hardcover: Suggest a book"),
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

  self.sync_queue = SyncQueue:new {
    settings = LuaSettings:open(("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_queue.lua"))
  }

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
    ui = self.ui,
    on_sign_in = function() self:signIn() end,
    on_sign_out = function() self.auth:signOut() end,
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

  local dialog = SignInDialog:new {
    auth = self.auth,
    device = device,
  }

  -- on success, clear any cached user id: a different account may be signed in
  dialog.success_callback = function()
    self.settings:updateSetting(SETTING.USER_ID, nil)
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

function HardcoverApp:onHardcoverSuggestBook()
  self.hardcover:showRandomBookDialog()
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
  UIManager:unschedule(self.startCacheRead)

  local had_pending = self.page_update_pending
  self:cancelPendingUpdates()
  self.state.read_cache_started = false

  if not self.state.book_status.id and not self.settings:syncEnabled() and not self.sync_queue:hasPending() then
    self.process_page_turns = false
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
  end

  self.process_page_turns = false
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
  local mapped_page = self.page_mapper:getMappedPage(
    self.state.page,
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
  local pending = self.sync_queue:pendingCount()

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

function HardcoverApp:flushSyncQueue(use_wifi, callback)
  if not self.sync_queue or not self.sync_queue:hasPending() then
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
    self.cache:updateBookStatus(file_path, HARDCOVER.STATUS.FINISHED)
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
    self.cache:updateBookStatus(file, status)
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

  local restart
  local cancelled = false

  -- withRetries dispatches through UIManager:nextTick, so this can in
  -- principle run before withRetries has returned; guard the cancel upvalue
  -- and remember the request so it still takes effect.
  restart = function(delay)
    --logger.warn("HARDCOVER restart cache fetch")
    delay = delay or 60
    cancelled = true
    self.state.read_cache_started = false
    if cancel then
      cancel()
    end
    UIManager:scheduleIn(delay, self.startReadCache, self)
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

            -- linked, but nothing cached yet and no network: retry later in
            -- case a snapshot appears, but do not treat it as a hard failure
            return restart()
          end

          self.wifi:withWifi(function()
            if not NetworkManager:isConnected() then
              return restart()
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