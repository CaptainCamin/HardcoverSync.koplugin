-- Settings > Download for offline, as methods of DialogManager: every cover of every book
-- on your shelves and lists kept on the device (see cover_download.lua), with an
-- estimate first, a progress window with Stop, the device kept awake while it runs, and
-- Wi-Fi brought up the way Sync does it.
--
-- Copied onto the class by install(), like book_flows.lua.

local _ = require("gettext")
local T = require("ffi/util").template

local UIManager = require("ui/uimanager")

local Background = require("hardcover/lib/background")
local CoverDownload = require("hardcover/lib/cover_download")
local Network = require("hardcover/lib/network")
local User = require("hardcover/lib/user")

local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local Flows = {}

-- How often the progress window is redrawn: every this many covers (and at the end). Each
-- redraw is a refresh of an e-ink panel, so not every cover.
local PROGRESS_EVERY = 10

local function loader()
  return require("hardcover/lib/ui/image_loader")
end

-- What there is to do, from the saved shelves and lists.
function Flows:coverPlan()
  local images = loader()
  local pinned, seen = images:getPinned(), images:getCache()
  local urls = self.book_store and self.book_store:libraryCovers(User:getId()) or {}
  return CoverDownload.plan(urls,
    function(url) return images:fetchUrl(url, "small") end,
    function(key, url) return pinned ~= nil and (pinned:has(key) or pinned:has(url)) end,
    function(key) return seen ~= nil and seen:has(key) end)
end

-- How many covers are not kept for offline yet. Counted once and remembered (the menu
-- asks on every repaint, and counting checks a file per book); forgotten when a download
-- ends or the shelves change.
function Flows:coversMissing()
  if self._covers_missing == nil then
    local ok, plan = pcall(self.coverPlan, self)
    self._covers_missing = ok and CoverDownload.missing(plan) or false
  end
  return self._covers_missing or nil
end

-- The Settings item's text: "Download covers for offline (42 missing)".
function Flows:coversMenuText()
  local missing = self:coversMissing()
  if missing and missing > 0 then
    return T(_("Download covers for offline (%1 missing)"), missing)
  end
  return _("Download covers for offline")
end

-- Tapping Stop, or the device going to sleep: the download stops after the cover it is on.
function Flows:stopCoverDownload()
  self._cover_stop = true
end

local function showProgress(self, text)
  if self._cover_progress then UIManager:close(self._cover_progress) end
  local ButtonDialog = require("ui/widget/buttondialog")
  self._cover_progress = ButtonDialog:new {
    title = text,
    title_align = "center",
    dismissable = false,
    buttons = { { {
      text = _("Stop"),
      callback = function() self:stopCoverDownload() end,
    } } },
  }
  UIManager:show(self._cover_progress)
end

local function closeProgress(self)
  if self._cover_progress then
    UIManager:close(self._cover_progress)
    self._cover_progress = nil
  end
end

-- Run the plan; `turned_on`: the plugin switched Wi-Fi on for this, so it switches it off
-- again after.
local function run(self, plan, turned_on)
  if not Network.connected() then
    StatusDialogs.info(_("Downloading covers needs an internet connection."))
    return
  end
  local images = loader()
  local total = CoverDownload.missing(plan)
  self._cover_stop = false
  self._cover_running = true
  showProgress(self, T(_("Keeping covers for offline: 0 of %1"), total))
  -- a long run must not be cut short by the device dozing off between covers
  local awake = UIManager.preventStandby and pcall(UIManager.preventStandby, UIManager)
  local stopped = function()
    return self._cover_stop or self.closed or not Network.connected()
  end

  Background.run(function()
    local ok, result = pcall(CoverDownload.run, {
      plan = plan,
      copy = function(item) return images:copyForOffline(item.key) end,
      fetch = function(item)
        -- Wi-Fi the plugin switched on would go off 15 seconds after the work began
        if self.wifi and self.wifi.cancelScheduledDisable then self.wifi:cancelScheduledDisable() end
        return images:keepForOffline(item.url, stopped)
      end,
      stopped = stopped,
      progress = function(done, all)
        if done % PROGRESS_EVERY == 0 and done < all and not self._cover_stop then
          showProgress(self, T(_("Keeping covers for offline: %1 of %2"), done, all))
        end
      end,
    })

    if awake then pcall(UIManager.allowStandby, UIManager) end
    self._cover_running = false
    self._covers_missing = nil
    closeProgress(self)
    if turned_on and self.wifi and self.wifi.scheduleDisable then self.wifi:scheduleDisable() end
    if self.closed then return end

    if not ok then
      StatusDialogs.info(_("Could not keep the covers for offline."))
    elseif result.stopped then
      StatusDialogs.info(T(_("Stopped: %1 of %2 covers kept. Run it again to carry on where it stopped."),
        result.copied + result.fetched, total))
    elseif result.failed > 0 then
      StatusDialogs.info(T(_("%1 covers kept for offline. %2 could not be downloaded; run it again to try them."),
        result.copied + result.fetched, result.failed))
    else
      StatusDialogs.info(T(_("Every cover is kept for offline (%1)."), plan.total))
    end
  end)
end

--
-- Settings > Download covers for offline. Says how many and about how much first; the
-- run can be stopped at any time, and running it again carries on where it stopped.
--
function Flows:downloadCoversForOffline()
  if self._cover_running then return end
  local ok, plan = pcall(self.coverPlan, self)
  if not ok then
    StatusDialogs.info(_("Could not look up the covers on this device."))
    return
  end
  self._covers_missing = CoverDownload.missing(plan)
  if plan.total == 0 then
    StatusDialogs.info(_("Your shelves and lists are not saved on this device yet. Open Home once while online, then try again."))
    return
  end
  if self._covers_missing == 0 then
    StatusDialogs.info(T(_("Every cover is already kept for offline (%1)."), plan.total))
    return
  end

  local ConfirmBox = require("ui/widget/confirmbox")
  UIManager:show(ConfirmBox:new {
    text = #plan.fetch == 0
      and T(_("Keep %1 covers for offline? They are all on this device already, so nothing needs downloading."),
        self._covers_missing)
      or T(_("Keep %1 covers for offline? About %2 to download.\n\nYou can stop at any time; running it again carries on where it stopped."),
        self._covers_missing, CoverDownload.size(CoverDownload.estimate(plan))),
    ok_text = _("Download"),
    ok_callback = function()
      if self.wifi and self.wifi.withWifi then
        self.wifi:withWifi(function(turned_on) run(self, plan, turned_on) end)
      else
        run(self, plan, false)
      end
    end,
  })
end

-- Copy the flows onto the class.
local function install(class)
  for name, fn in pairs(Flows) do
    class[name] = fn
  end
end

return { install = install }
