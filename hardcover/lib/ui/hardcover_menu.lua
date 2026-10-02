local DataStorage = require("datastorage")
local Device = require("device")
local _ = require("gettext")
local math = require("math")
local os = require("os")
local logger = require("logger")

local T = require("ffi/util").template

local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local Github = require("hardcover/lib/github")
local Updater = require("hardcover/lib/updater")
local User = require("hardcover/lib/user")
local _t = require("hardcover/lib/table_util")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local ICON = require("hardcover/lib/constants/icons")
local SETTING = require("hardcover/lib/constants/settings")
local VERSION = require("hardcover_version")
local SyncConflicts = require("hardcover/lib/sync_conflicts")

local HardcoverMenu = {}
HardcoverMenu.__index = HardcoverMenu

function HardcoverMenu:new(o)
  return setmetatable(o or {
    enabled = true
  }, self)
end

-- Run a dialog-opening action immediately, arranging wifi around it.
--
-- This exists because running the action from inside an AutoWifi callback made
-- it conditional: on several paths (airplane mode, a pending connection, a
-- device that cannot restore wifi) that callback never fired and the tapped
-- menu item did nothing at all. On e-ink that reads as a screen that never
-- updates.
--
-- zlibrary.koplugin avoids this by showing every dialog directly in the menu
-- callback and dealing with connectivity separately. Do the same here: the user
-- asked for a screen, so open it. If it turns out wifi is needed, the fetch
-- fails and the dialog reports that; the wifi prompt is a convenience layered
-- on top, never a gate in front of the UI.
--
-- `needs_wifi` is false for actions that work from local data and so should
-- never prompt at all.
function HardcoverMenu:withWifiThen(action, needs_wifi)
  if not needs_wifi then
    action(false)
    return
  end

  -- Open the screen first. If wifi is already up this is the whole story.
  if NetworkMgr:isWifiOn() then
    action(false)
    return
  end

  -- Wifi is down. Show the dialog regardless, then try to bring the connection
  -- up so the fetch inside it can succeed.
  action(false)

  self.wifi:wifiPrompt(function(wifi_enabled)
    if wifi_enabled then
      UIManager:nextTick(function()
        self.wifi:wifiDisablePrompt()
      end)
    end
  end)
end

local privacy_labels = {
  [HARDCOVER.PRIVACY.PUBLIC] = "Public",
  [HARDCOVER.PRIVACY.FOLLOWS] = "Follows",
  [HARDCOVER.PRIVACY.PRIVATE] = "Private"
}

function HardcoverMenu:mainMenu()
  -- In the file browser (no book open) the entry is not a menu: it opens the home
  -- screen, which holds everything else (Sync, Account, Settings and About are
  -- behind its cog). In the reader it is the tracking menu for the open book.
  if not (self.ui and self.ui.document) then
    return {
      text = _("Hardcover"),
      enabled_func = function()
        return self.enabled
      end,
      callback = function()
        self.dialog_manager:showHome()
      end,
    }
  end

  return {
    enabled_func = function()
      return self.enabled
    end,
    text_func = function()
      return self.settings:bookLinked() and _("Hardcover: " .. ICON.LINK) or _("Hardcover")
    end,
    sub_item_table_func = function()
      local has_book = self.ui.document and true or false
      return self:getSubMenuItems(has_book)
    end,
  }
end

-- The panel for the open book (see ui/reader_panel.lua). It is the same actions
-- the reader menu has, reached from big buttons: each one runs the menu item it
-- stands for, handed a stand-in menu whose updateItems redraws the panel, so the
-- panel and the menu cannot disagree about what an action does.
local STATUS_LABELS = {
  [HARDCOVER.STATUS.TO_READ] = "Want to Read",
  [HARDCOVER.STATUS.READING] = "Currently Reading",
  [HARDCOVER.STATUS.FINISHED] = "Read",
  [HARDCOVER.STATUS.DNF] = "Did Not Finish",
}

local function findItem(items, prefix)
  for _, item in ipairs(items) do
    local text = item.text or (item.text_func and item.text_func())
    if type(text) == "string" and text:find(prefix, 1, true) == 1 then return item end
  end
end

function HardcoverMenu:showReaderPanel()
  if not (self.ui and self.ui.document) then
    UIManager:show(InfoMessage:new { text = _("Open a book first.") })
    return
  end

  local panel
  local shim = { updateItems = function() if panel then panel:render() end end }

  -- run a menu item: a list opens as a settings-style screen, anything else is
  -- called as the menu would
  local function run(item)
    if not item then return end
    local children = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
    if children then
      local text = item.text or (item.text_func and item.text_func()) or ""
      require("hardcover/lib/ui/settings_dialog").show {
        title = (text:gsub("[:%s]+$", "")),
        items = children,
        on_close = function() shim.updateItems() end,
      }
    elseif item.callback then
      item.callback(shim)
    end
  end

  local function enabled(item)
    if not item then return false end
    if item.enabled_func then return item.enabled_func() and true or false end
    return true
  end

  local function model()
    local linked = self.settings:bookLinked()
    local status = self.state.book_status or {}
    local doc_title = self.ui.doc_props and self.ui.doc_props.display_title
    local title = (linked and self.settings:getLinkedTitle()) or doc_title or _("This book")

    local view = self:getSubMenuItems(true)
    local status_items = self:getStatusSubMenuItems()
    local pages_item = findItem(status_items, "Update page")
    local note_item = findItem(status_items, "Add a note")
    local rating_item = findItem(status_items, "Update rating") or findItem(status_items, "Set rating")
    local settings_item = findItem(view, "Settings")
    local link_item = findItem(view, "Linked book") or findItem(view, "Link book")
    local edition_item = findItem(view, "Change edition")
    -- just the statuses (and Remove); page, note and rating have buttons of their own
    local status_item = findItem(view, "Update status") and {
      text = _("Update status"),
      enabled_func = function() return self.enabled and self.settings:bookLinked() end,
      sub_item_table_func = function()
        local all = self:getStatusSubMenuItems()
        return { all[1], all[2], all[3], all[4], all[5] }
      end,
    }

    local pills = {}
    if not linked then
      pills[1] = { text = _("Not linked to Hardcover") }
    elseif status.status_id and STATUS_LABELS[status.status_id] then
      pills[1] = { text = _(STATUS_LABELS[status.status_id]), filled = true }
    end

    local bits = {}
    local reads = status.user_book_reads
    local read = reads and reads[#reads]
    local pages = self.settings:pages()
    if linked and pages then
      bits[#bits + 1] = T(_("Page %1 of %2"), read and read.progress_pages or 0, pages)
    end
    if status.rating then
      bits[#bits + 1] = T(_("Rated %1"), tostring(status.rating))
    end

    local actions = {}
    local function add(text, item, extra)
      local action = { text = text, enabled = enabled(item), run = function() run(item) end }
      for k, v in pairs(extra or {}) do action[k] = v end
      actions[#actions + 1] = action
    end

    if linked then
      add(_("Status"), status_item)
      add(_("Set page"), pages_item)
      add(_("Rating"), rating_item)
      add(_("Add a note"), note_item)
      actions[#actions + 1] = {
        text = _("Details"), enabled = self.enabled,
        run = function()
          self:withWifiThen(function()
            self.dialog_manager:showBookDetail(self.settings:getLinkedBookId(), self.settings:getLinkedEditionId())
          end, true)
        end,
      }
      actions[#actions + 1] = {
        text = _("Reviews"), enabled = self.enabled,
        run = function()
          self:withWifiThen(function()
            self.dialog_manager:showReviews(self.settings:getLinkedBookId())
          end, true)
        end,
      }
      add(_("Change edition"), edition_item)
      add(_("Settings"), settings_item)
    else
      add(_("Link this book"), link_item, { primary = true, wide = true })
      add(_("Settings"), settings_item, { wide = true })
    end

    return {
      title = title,
      linked = linked,
      pills = pills,
      line = #bits > 0 and table.concat(bits, "  \194\183  ") or nil,
      track = linked and {
        checked = self.settings:syncEnabled(),
        toggle = function() self.settings:setSync(not self.settings:syncEnabled()) end,
      } or nil,
      actions = actions,
    }
  end

  if self.settings:bookLinked() then self.cache:cacheUserBook() end
  panel = require("hardcover/lib/ui/reader_panel").show { model = model }
  return panel
end

-- Two menus from one definition, because the reader and the file browser have
-- different jobs.
--
--   * In the reader (book_view): tracking and information about the book that is
--     open -- linking, progress, status, rating, notes, details, sync, and the
--     tracking settings. Nothing that is about the rest of your library.
--   * In the file browser: the home screen first (your shelves), then sync,
--     account, settings and about.
--
-- Items are gated with `book_view and {...}` / `not book_view and {...}`; the
-- falsy ones are filtered out at the end.
function HardcoverMenu:getSubMenuItems(book_view)
  local menu_items = {
    book_view and {
      text_func = function()
        if self.settings:bookLinked() then
          -- need to show link information somehow. Maybe store title
          local title = self.settings:getLinkedTitle()
          if not title then
            title = self.settings:getLinkedBookId()
          end
          return _("Linked book: " .. title)
        else
          return _("Link book")
        end
      end,
      enabled_func = function()
        -- leave button enabled to allow clearing local link when api disabled
        return self.enabled or self.settings:bookLinked()
      end,
      hold_callback = function(menu_instance)
        if self.settings:bookLinked() then
          self.settings:updateBookSetting(
            self.ui.document.file,
            {
              _delete = { 'book_id', 'edition_id', 'edition_format', 'pages', 'title' }
            }
          )

          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        if not self.enabled then
          return
        end

        local force_search = self.settings:bookLinked()

        self.hardcover:showLinkBookDialog(force_search, function()
          menu_instance:updateItems()
        end)
      end,
    },
    book_view and {
      text_func = function()
        local edition_format = self.settings:getLinkedEditionFormat()
        local title = "Change edition"

        if edition_format then
          title = title .. ": " .. edition_format
        elseif self.settings:getLinkedEditionId() then
          return title .. ": physical book"
        end

        return _(title)
      end,
      enabled_func = function()
        return self.enabled and self.settings:bookLinked()
      end,
      callback = function(menu_instance)
        -- Show the dialog before listing editions. This fetch used to run here,
        -- so tapping "Change edition" did nothing for the length of a request
        -- (up to six seconds with no route to the API), which on e-ink is
        -- indistinguishable from a crash. The dialog opens on a loading list and
        -- fills in from the callback.
        self.dialog_manager:buildLoadingSearchDialog(
          _("Select edition"),
          function(callback)
            Api:findEditionsAsync(self.settings:getLinkedBookId(), User:getId(), callback)
          end,
          {
            edition_id = self.settings:getLinkedEditionId()
          },
          function(book)
            Background.run(function()
              self.hardcover:linkBook(book)
              menu_instance:updateItems()
            end)
          end
        )
      end,
      keep_menu_open = true,
      separator = true
    },
    book_view and {
      text = _("Automatically track progress"),
      checked_func = function()
        return self.settings:syncEnabled()
      end,
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      callback = function()
        local sync = not self.settings:syncEnabled()
        self.settings:setSync(sync)
      end,
    },
    book_view and {
      text = _("Update status"),
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      sub_item_table_func = function()
        self.cache:cacheUserBook()

        return self:getStatusSubMenuItems()
      end,
      separator = true
    },
    book_view and {
      text = _("Book details"),
      enabled_func = function()
        return self.enabled and self.settings:bookLinked()
      end,
      callback = function()
        self:withWifiThen(function()
          self.dialog_manager:showBookDetail(
            self.settings:getLinkedBookId(),
            self.settings:getLinkedEditionId()
          )
        end, true)
      end,
      keep_menu_open = true,
      separator = true
    },
    self:getSyncMenuItem(),
    self:conflictCount() > 0 and self:getSyncConflictsMenuItem(),
    -- OAuth sign-in/out. Only offered when hardcover_config.lua supplies a
    -- client_id; with a static API key there is nothing to sign in to.
    -- In the file browser always; in the reader only when there is something to do
    -- (signed out), since tracking cannot work without it.
    self.auth and self.auth:usingOAuth() and (not book_view or self.auth:needsReauth()) and self:getAccountMenuItem(),
    {
      text = _("Settings"),
      sub_item_table_func = function()
        if book_view then
          -- the reader menu already has Sync, and shows the account itself when
          -- you are signed out; signed in, the account (to sign out) lives here
          return self:getHomeSettingsItems({ sync = false, account = not (self.auth and self.auth:needsReauth()) })
        end
        return self:getSettingsSubMenuItems()
      end,
    },
  }
  return _t.filter(menu_items, function(v)
    return v
  end)
end

-- Updates: look for a newer release and install it. The result of the daily
-- background check (see DialogManager:checkForUpdate) is remembered in the
-- settings, so the row says so without asking GitHub again.
function HardcoverMenu:installUpdate(release)
  local dir = Updater.pluginDir()
  if not dir then
    UIManager:show(InfoMessage:new { text = _("Can't tell where the plugin is installed.") })
    return
  end
  local progress = InfoMessage:new { text = _("Downloading the update…"), timeout = 120 }
  UIManager:show(progress)
  UIManager:nextTick(function()
    local ok, installed, err = pcall(Updater.install, release, dir)
    UIManager:close(progress)
    if not ok then installed, err = false, installed end
    if not installed then
      UIManager:show(InfoMessage:new { text = T(_("The update failed: %1"), tostring(err)) })
      return
    end
    self.settings:updateSetting(SETTING.UPDATE_AVAILABLE, false)
    if Device:canRestart() then
      UIManager:show(ConfirmBox:new {
        text = T(_("Hardcover Sync %1 is installed. Restart KOReader to use it?"), release.version),
        ok_text = _("Restart"),
        ok_callback = function() UIManager:restartKOReader() end,
      })
    else
      UIManager:show(InfoMessage:new {
        text = T(_("Hardcover Sync %1 is installed. Restart KOReader to use it."), release.version),
      })
    end
  end)
end

function HardcoverMenu:showRelease(release)
  if not release.version then
    UIManager:show(InfoMessage:new {
      text = T(_("Hardcover Sync is up to date (v%1)."), table.concat(VERSION, ".")),
    })
    return
  end
  local notes = release.notes and release.notes ~= "" and ("\n\n" .. release.notes:sub(1, 600)) or ""
  UIManager:show(ConfirmBox:new {
    text = T(_("Version %1 is available (you have v%2).%3"), release.version, table.concat(VERSION, "."), notes),
    ok_text = release.zip_url and _("Install") or _("OK"),
    cancel_text = _("Later"),
    ok_callback = function()
      if release.zip_url then self:installUpdate(release) end
    end,
  })
end

function HardcoverMenu:getUpdateMenuItems()
  return {
    {
      text_func = function()
        local found = Updater.available(self.settings, VERSION)
        if found then return T(_("Update available: v%1"), found.version) end
        return _("Check for updates")
      end,
      callback = function()
        local checking = InfoMessage:new { text = _("Checking for updates…"), timeout = 10 }
        UIManager:show(checking)
        Github:latestReleaseAsync(function(release)
          UIManager:close(checking)
          if not release then
            UIManager:show(InfoMessage:new { text = _("Couldn't reach GitHub. Try again when you're online.") })
            return
          end
          Updater.remember(self.settings, release)
          self:showRelease(release)
        end)
      end,
      keep_menu_open = true,
    },
    {
      text = _("Check for updates automatically"),
      checked_func = function()
        return self.settings:readSetting(SETTING.UPDATE_CHECK) ~= false
      end,
      callback = function()
        self.settings:updateSetting(SETTING.UPDATE_CHECK,
          self.settings:readSetting(SETTING.UPDATE_CHECK) == false)
      end,
      keep_menu_open = true,
    },
  }
end

-- About: version, project, settings file. Lives in the settings screen, which is
-- where the file browser's Hardcover entry (it opens Home) puts everything that
-- used to be the first menu screen.
function HardcoverMenu:getAboutMenuItem()
  return {
    text = _("About"),
    callback = function()
      local version = table.concat(VERSION, ".")
      local settings_file = DataStorage:getSettingsDir() .. "/" .. "hardcoversync_settings.lua"

      -- Build the text with a placeholder for the "latest release" note, show
      -- the box straight away, and fill the note in if GitHub answers.
      --
      -- This used to call Github:newestRelease() BEFORE showing anything, and
      -- that request had no timeout. With no route to api.github.com it
      -- blocked for a long time, so the About box never appeared at all --
      -- indistinguishable on e-ink from a screen that failed to refresh.
      -- Showing first and asking second makes the screen's appearance
      -- independent of the network.
      local LATEST_MARK = " \u{25CB} checking for a newer release\u{2026}"

      local function about_text(latest)
        local new_release_str = ""
        if latest then
          new_release_str = " (latest v" .. latest .. ")"
        end

        return [[
Hardcover plugin
v]] .. version .. new_release_str .. [[


Updates book progress and status on Hardcover.app

Project:
github.com/CaptainCamin/HardcoverSync.koplugin
(a fork of github.com/billiam/hardcoverapp.koplugin)

Settings:
]] .. settings_file
      end

      local message = InfoMessage:new {
        text = about_text(nil),
        face = Font:getFace("cfont", 18),
        show_icon = false,
      }

      UIManager:show(message)

      -- Update in place once the answer arrives, if the box is still up.
      Github:newestReleaseAsync(function(new_release)
        if not new_release then
          if message.text and message.text:find(LATEST_MARK, 1, true) then
            message.text = message.text:gsub(LATEST_MARK:gsub("(%W)", "%%%1"), "")
          end
          return
        end

        if message.text and message.text:find(LATEST_MARK, 1, true) then
          message.text = message.text:gsub(LATEST_MARK:gsub("(%W)", "%%%1"),
            " (latest v" .. new_release .. ")")
          UIManager:setDirty(message, "ui")
        end
      end)
    end,
    keep_menu_open = true
  }
end

-- The Sync item's sibling: shown only while a book's offline progress disagrees
-- with Hardcover and the user has not yet said which to keep.
-- everything waiting to be sent: progress and status changes, and goal changes
function HardcoverMenu:pendingTotal()
  return self.sync_queue:pendingCount() + (self.goal_queue and self.goal_queue:count() or 0)
end

function HardcoverMenu:conflictCount()
  return self.sync_queue and self.sync_queue.conflictCount and self.sync_queue:conflictCount() or 0
end

function HardcoverMenu:getSyncConflictsMenuItem()
  return {
    text_func = function()
      return SyncConflicts.menuText(self.sync_queue:conflictCount())
    end,
    enabled_func = function()
      return self.enabled and self.sync_queue:conflictCount() > 0
    end,
    callback = function(menu_instance)
      -- loaded here, not at the top: the dialog pulls in the whole picker and theme
      require("hardcover/lib/ui/sync_conflict_dialog").show {
        queue = self.sync_queue,
        on_done = function(resolved)
          if menu_instance and menu_instance.updateItems then menu_instance:updateItems() end
          -- answers are only useful once they are sent
          if resolved > 0 then
            self:withWifiThen(function() self.on_flush_sync_queue() end, true)
          end
        end,
      }
    end,
    keep_menu_open = true,
    tile = _("Conflicts"),
  }
end

-- Sync now / pending changes: one definition for the menu and the home screen's
-- settings.
function HardcoverMenu:getSyncMenuItem()
  return {
    text_func = function()
      local pending = self:pendingTotal()
      if pending > 0 then
        return T(_("Sync pending changes (%1)"), pending)
      end
      return _("Sync now")
    end,
    -- Greyed out when there is nothing to send. Offline with changes queued it
    -- stays enabled: tapping it is how the user learns they are saved and
    -- will sync later.
    enabled_func = function()
      return self.enabled and (self.sync_queue:hasPending() or self:pendingTotal() > 0)
    end,
    callback = function()
      -- Syncing genuinely needs a connection, but the confirmation message
      -- must still appear when it cannot be sent -- otherwise the menu item
      -- looks dead. withWifiThen reports the outcome either way.
      self:withWifiThen(function()
        self.on_flush_sync_queue()
      end, true)
    end,
    hold_callback = function(menu_instance)
      -- long press discards anything queued, for when a queued change is
      -- wrong and the user would rather retype it than push it
      local count = self.sync_queue:pendingCount()
      if count == 0 then
        return
      end

      self.dialog_manager:maybeConfirm({
        text = T(_("Discard %1 pending changes?"), count),
        ok_callback = function()
          self.sync_queue:clearAll()
          menu_instance:updateItems()
        end,
        no_confirm_callback = function()
          menu_instance:updateItems()
        end
      })
    end,
    keep_menu_open = true,
    separator = true,
    -- the settings screen shows this one as a tile at the top
    tile = _("Sync"),
  }
end

-- The account item: who you are signed in as, and signing in or out. One
-- definition for the menu and the home screen's settings.
function HardcoverMenu:getAccountMenuItem()
  return {
    text_func = function()
      return T(_("Account: %1"), self.auth:statusText())
    end,
    sub_item_table_func = function()
      local items = {}

      if self.auth:needsReauth() then
        table.insert(items, {
          text = _("Sign in to Hardcover"),
          enabled_func = function()
            return self.enabled
          end,
          callback = function(menu_instance)
            self.on_sign_in()
            if menu_instance then
              menu_instance:updateItems()
            end
          end,
          keep_menu_open = true,
        })
      else
        table.insert(items, {
          text = _("Sign in again"),
          enabled_func = function()
            return self.enabled
          end,
          callback = function()
            self.on_sign_in()
          end,
          keep_menu_open = true,
        })
        table.insert(items, {
          text = _("Sign out"),
          enabled_func = function()
            return self.enabled
          end,
          callback = function(menu_instance)
            self.dialog_manager:maybeConfirm({
              text = _("Sign out of Hardcover?"),
              ok_callback = function()
                self.on_sign_out()
                if menu_instance then
                  menu_instance:updateItems()
                end
              end,
              no_confirm_callback = function()
                if menu_instance then
                  menu_instance:updateItems()
                end
              end,
            })
          end,
          keep_menu_open = true,
        })
      end

      return items
    end,
    separator = true,
    tile = _("Account"),
  }
end

-- Everything the home screen's settings screen lists: sync, the account (when
-- the plugin signs in with OAuth), the settings, then About.
function HardcoverMenu:getHomeSettingsItems(opts)
  opts = opts or {}
  local items = {}
  if opts.sync ~= false then
    items[1] = self:getSyncMenuItem()
    if self:conflictCount() > 0 then
      items[#items + 1] = self:getSyncConflictsMenuItem()
    end
  end
  if opts.account ~= false and self.auth and self.auth:usingOAuth() then
    local account = self:getAccountMenuItem()
    account.separator = true
    items[#items + 1] = account
  end
  for _, item in ipairs(self:getSettingsSubMenuItems()) do
    items[#items + 1] = item
  end
  for _, item in ipairs(self:getUpdateMenuItems()) do
    items[#items + 1] = item
  end
  if opts.about ~= false then
    local about = self:getAboutMenuItem()
    about.keep_menu_open = nil
    items[#items + 1] = about
  end
  return items
end

function HardcoverMenu:getVisibilitySubMenuItems()
  return {
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.PUBLIC]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.PUBLIC
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.PUBLIC)
      end,
      radio = true,
    },
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.FOLLOWS]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.FOLLOWS
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.FOLLOWS)
      end,
      radio = true
    },
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.PRIVATE]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.PRIVATE
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.PRIVATE)
      end,
      radio = true
    },
  }
end

-- The actions below talk to Hardcover and are reached from menu callbacks, which
-- run outside Trapper:wrap, so each does its work inside Background.run: the
-- request then forks and yields instead of freezing KOReader until it returns.

function HardcoverMenu:setStatus(status)
  Background.run(function()
    self.cache:updateBookStatus(self.ui.document.file, status)
  end)
end

function HardcoverMenu:removeCurrentRead(menu_instance)
  Background.run(function()
    local result = Api:removeRead(self.state.book_status.id)
    if result and result.id then
      -- the book is off the shelf: a queued page or status must not put it back
      if self.sync_queue and self.ui and self.ui.document then
        self.sync_queue:clear(self.ui.document.file)
      end
      self.state.book_status = {}
      menu_instance:updateItems()
    end
  end)
end

function HardcoverMenu:savePage(current_read, edition_page, menu_instance)
  Background.run(function()
    local result

    if current_read then
      result = Api:updatePage(current_read.id, current_read.edition_id, edition_page,
        current_read.started_at)
    else
      local start_date = os.date("%Y-%m-%d")
      result = Api:createRead(self.state.book_status.id, self.state.book_status.edition_id, edition_page,
        start_date)
    end

    if result then
      -- the page just set supersedes any older page still queued
      if self.sync_queue and self.ui and self.ui.document then
        local queued = self.sync_queue:get(self.ui.document.file)
        if type(queued) == "table" then
          queued.mapped_page = nil
          queued.page_updated_at = nil
          self.sync_queue:save(self.ui.document.file, queued)
        end
      end
      self.state.book_status = result
      menu_instance:updateItems()
    else
      -- A failed page write used to be invisible, so a reader who set the page
      -- and saw nothing happen could not tell a rejected write from a working
      -- one; the progress would simply re-sync from the server later, looking
      -- like the change had been lost.
      self.dialog_manager:showError(_("Page could not be saved"))
    end
  end)
end

-- `quiet` is the clear-rating long press: no error when it fails, as before.
function HardcoverMenu:saveRating(value, menu_instance, quiet)
  Background.run(function()
    local result = Api:updateRating(self.state.book_status.id, value)
    if result then
      self.state.book_status = result
      menu_instance:updateItems()
    elseif not quiet then
      self.dialog_manager:showError(_("Rating could not be saved"))
    end
  end)
end

function HardcoverMenu:getStatusSubMenuItems()
  return {
    {
      text = _(ICON.BOOKMARK .. " Want To Read"),
      enabled_func = function()
        return self.enabled
      end,
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.TO_READ
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Want To Read?",
          ok_callback = function()
            self:setStatus(HARDCOVER.STATUS.TO_READ)
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.OPEN_BOOK .. " Currently Reading"),
      enabled_func = function()
        return self.enabled
      end,
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.READING
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Currently Reading?",
          ok_callback = function()
            self:setStatus(HARDCOVER.STATUS.READING)
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.CHECKMARK .. " Read"),
      enabled_func = function()
        return self.enabled
      end,
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.FINISHED
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Read?",
          ok_callback = function()
            self:setStatus(HARDCOVER.STATUS.FINISHED)
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.STOP_CIRCLE .. " Did Not Finish"),
      enabled_func = function()
        return self.enabled
      end,
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.DNF
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Did Not Finish?",
          ok_callback = function()
            self:setStatus(HARDCOVER.STATUS.DNF)
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true,
    },
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self.enabled and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            self:removeCurrentRead(menu_instance)
          end
        })
      end,
      keep_menu_open = true,
      separator = true
    },
    {
      text_func = function()
        local reads = self.state.book_status.user_book_reads
        local current_page = reads and reads[#reads] and reads[#reads].progress_pages or 0
        local max_pages = self.settings:pages()

        if not max_pages then
          max_pages = "???"
        end

        return T(_("Update page: %1 of %2"), current_page, max_pages)
      end,
      enabled_func = function()
        return self.enabled and self.state.book_status.status_id == HARDCOVER.STATUS.READING and self.settings:pages()
      end,
      callback = function(menu_instance)
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local last_hardcover_page = current_read and current_read.progress_pages or 0

        local document_page = self.ui:getCurrentPage()
        local document_pages = self.ui.document:getPageCount()

        local remote_pages = self.settings:pages()
        local mapped_page = self.page_mapper:getMappedPage(document_page, document_pages, remote_pages)

        local left_text = "Edition"
        if last_hardcover_page > 0 then
          left_text = left_text .. ": was " .. last_hardcover_page
        end

        local UpdateDoubleSpinWidget = require("hardcover/lib/ui/update_double_spin_widget")
        local spinner = UpdateDoubleSpinWidget:new {
          ok_always_enabled = true,

          left_text = left_text,
          left_value = mapped_page,
          left_min = 0,
          left_max = remote_pages,
          left_step = 1,
          left_hold_step = 20,

          right_text = "Local page",
          right_value = document_page,
          right_min = 0,
          right_max = document_pages,
          right_step = 1,
          right_hold_step = 20,

          update_callback = function(new_edition_page, new_document_page, edition_page_changed)
            if edition_page_changed then
              local new_mapped_page = self.page_mapper:getUnmappedPage(new_edition_page, document_pages, remote_pages)
              return new_edition_page, new_mapped_page
            else
              local new_mapped_page = self.page_mapper:getMappedPage(new_document_page, document_pages, remote_pages)
              return new_mapped_page, new_document_page
            end
          end,
          ok_text = _("Set page"),
          title_text = _("Set current page"),

          callback = function(edition_page, _document_page)
            self:savePage(current_read, edition_page, menu_instance)
          end
        }
        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = _("Add a note"),
      enabled_func = function()
        return self.enabled and self.state.book_status.id ~= nil
      end,
      callback = function()
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local current_page = current_read and current_read.progress_pages or 0

        -- allow premapped page
        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          current_page,
          "note"
        )
      end,
      keep_menu_open = true
    },
    {
      text_func = function()
        local text
        if self.state.book_status.rating then
          text = "Update rating"
          local whole_star = math.floor(self.state.book_status.rating)
          local star_string = string.rep(ICON.STAR, whole_star)
          if self.state.book_status.rating - whole_star > 0 then
            star_string = star_string .. ICON.HALF_STAR
          end
          text = text .. ": " .. star_string
        else
          text = "Set rating"
        end

        return _(text)
      end,
      enabled_func = function()
        return self.enabled and self.state.book_status.id ~= nil
      end,
      callback = function(menu_instance)
        local rating = self.state.book_status.rating

        local spinner = SpinWidget:new {
          ok_always_enabled = rating == nil,
          value = rating or 2.5,
          value_min = 0,
          value_max = 5,
          value_step = 0.5,
          value_hold_step = 2,
          precision = "%.1f",
          ok_text = _("Save"),
          title_text = _("Set Rating"),
          callback = function(spin)
            self:saveRating(spin.value, menu_instance)
          end
        }
        UIManager:show(spinner)
      end,
      hold_callback = function(menu_instance)
        self:saveRating(0, menu_instance, true)
      end,
      keep_menu_open = true,
      separator = true
    },
    {
      text = _("Set status visibility"),
      enabled_func = function()
        return self.enabled and self.state.book_status.id ~= nil
      end,
      sub_item_table_func = function()
        return self:getVisibilitySubMenuItems()
      end,
    },
  }
end

function HardcoverMenu:getTrackingSubMenuItems()
  return {
    {
      text = "Update periodically",
      radio = true,
      checked_func = function()
        return self.settings:trackByTime()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.FREQUENCY)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackFrequency() .. " minutes"
      end,
      enabled_func = function()
        return self.settings:trackByTime()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackFrequency(),
          value_min = 1,
          value_max = 120,
          value_step = 1,
          value_hold_step = 6,
          ok_text = _("Save"),
          title_text = _("Set track frequency"),
          callback = function(spin)
            self.settings:updateSetting(SETTING.TRACK_FREQUENCY, spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = "Update by progress",
      radio = true,
      checked_func = function()
        return self.settings:trackByProgress()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.PROGRESS)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackPercentageInterval() .. " percent completed"
      end,
      enabled_func = function()
        return self.settings:trackByProgress()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackPercentageInterval(),
          value_min = 1,
          value_max = 50,
          value_step = 1,
          value_hold_step = 10,
          ok_text = _("Save"),
          title_text = _("Set track progress"),
          callback = function(spin)
            self.settings:changeTrackPercentageInterval(spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
  }
end

function HardcoverMenu:getSettingsSubMenuItems()
  return {
    {
      text = "Automatically link by ISBN",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_ISBN) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_ISBN) == true
        self.settings:updateSetting(SETTING.LINK_BY_ISBN, not setting)
      end
    },
    {
      text = "Automatically link by Hardcover identifiers",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) == true
        self.settings:updateSetting(SETTING.LINK_BY_HARDCOVER, not setting)
      end
    },
    {
      text = "Automatically link by title and author",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_TITLE) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_TITLE) == true
        self.settings:updateSetting(SETTING.LINK_BY_TITLE, not setting)
      end,
      separator = true
    },
    {
      text_func = function()
        return "Track progress settings: " .. ""
      end,
      sub_item_table_func = function()
        return self:getTrackingSubMenuItems()
      end,
    },
    {
      text = "Always track progress by default",
      checked_func = function()
        return self.settings:readSetting(SETTING.ALWAYS_SYNC) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.ALWAYS_SYNC) == true
        self.settings:updateSetting(SETTING.ALWAYS_SYNC, not setting)
      end,
    },
    {
      text = "Enable wifi on demand",
      checked_func = function()
        return self.settings:readSetting(SETTING.ENABLE_WIFI) == true
      end,
      enabled_func = function()
        return Device:hasWifiRestore()
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.ENABLE_WIFI) == true
        self.settings:updateSetting(SETTING.ENABLE_WIFI, not setting)
      end
    },
    {
      text = "Confirm changes to book read status",
      checked_func = function()
        return self.settings:menuConfirm()
      end,
      callback = function()
        local setting = self.settings:menuConfirm() == true
        self.settings:setMenuConfirm(not setting)
      end
    },
    {
      text = "Compatibility mode",
      checked_func = function()
        return self.settings:compatibilityMode()
      end,
      callback = function()
        local setting = self.settings:compatibilityMode()
        self.settings:updateSetting(SETTING.COMPATIBILITY_MODE, not setting)
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Disable fancy menu for book and edition search results.

May improve compatibility for some versions of KOReader]],
        })
      end
    }
  }
end

return HardcoverMenu