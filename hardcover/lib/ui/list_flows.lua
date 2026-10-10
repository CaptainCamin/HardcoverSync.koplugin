-- Lists, as methods of DialogManager: the index of your lists and the ones you follow,
-- one list's books, and keeping every list saved on the device.
--
-- Everything is saved (list_store.lua, book_store.lua) and opens from there at once,
-- offline too. Hardcover is asked only whether the lists changed (Home does it in the
-- request it already makes for the "More lists" tile; the lists screen when Home has
-- not in the last few minutes), and a list is downloaded again only when it did. All
-- list requests go one at a time through one queue (see ListsSync.newQueue).
--
-- Copied onto the class by install(), like book_flows.lua.

local _ = require("gettext")
local T = require("ffi/util").template

local UIManager = require("ui/uimanager")
local Live = require("hardcover/lib/ui/live")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local ListStore = require("hardcover/lib/list_store")
local ListsSync = require("hardcover/lib/lists_sync")
local Network = require("hardcover/lib/network")
local ShelfLoader = require("hardcover/lib/shelf_loader")
local User = require("hardcover/lib/user")

local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local Flows = {}

local function noLists()
  return _("No lists yet. Make one on hardcover.app and it will show up here.")
end

-- The one queue every list request goes through.
function Flows:listsQueue()
  if not self._lists_queue then
    self._lists_queue = ListsSync.newQueue {
      run = Background.run,
      -- the plugin is closing (KOReader is switching between the file browser and a book)
      alive = function() return not self.closed end,
    }
  end
  return self._lists_queue
end

--
-- Download list `row` (an index row) and save it, through the queue. `opts`:
--   front    a screen is waiting: do this next
--   force    download the books in full even if the list is saved (Refresh)
--   on_page  function(entries) while a first download comes in
--   on_done  function(result): see ListsSync.download (nil when it never ran)
--
function Flows:downloadList(row, opts)
  opts = opts or {}
  -- without the stores (a test's manager) the list is still downloaded, just not kept
  local store = self.book_store and self.list_store or nil
  local user_id = User:getId()
  local queue = self:listsQueue()
  local key = "list:" .. tostring(row.id) .. (opts.force and ":refresh" or "")
  queue:wait(key, opts.on_done)
  queue:add({
    key = key,
    work = function()
      return ListsSync.download {
        api = Api,
        lists = store,
        books = self.book_store,
        user_id = user_id,
        row = row,
        alive = function() return not self.closed end,
        sleep = Background.sleep,
        network = Network,
        force = opts.force,
        on_page = opts.on_page,
      }
    end,
  }, opts.front)
  queue:start()
end

-- Queue every list of `index` whose saved copy is missing, incomplete or out of date.
function Flows:queueStaleLists(index)
  local store = self.list_store
  if not store or not index then return end
  local user_id = User:getId()
  local stale = ListsSync.stale(ListStore.allRows(index), function(row)
    return store:contents(user_id, row.id)
  end)
  for _, row in ipairs(stale) do
    self:downloadList(row)
  end
end

-- Fetch the index, save it, and queue the lists that changed. `on_done(result)` with
-- { lists = Lists.normalize's answer } or { failure = why }.
function Flows:refreshLists(on_done)
  local store = self.list_store
  local user_id = User:getId()
  local queue = self:listsQueue()
  queue:wait("index", on_done)
  queue:add({
    key = "index",
    work = function()
      local lists, err = ShelfLoader.patient(function() return Api:getLists() end, Background.sleep)
      if not lists then return { failure = err } end
      if store then
        store:putIndex(user_id, lists)
        self:queueStaleLists(lists)
      end
      return { lists = lists }
    end,
  }, true)
  queue:start()
end

--
-- Home's check: `marks` are the lists' fingerprints from the request Home makes for the
-- tile (Lists.marks). If they match what is saved nothing is fetched but the lists that
-- were never fully saved; otherwise the index comes again and the lists that changed
-- with it. Called at the end of Home's refresh, in the same background block, so the
-- downloads follow Home's own requests instead of running beside them.
--
function Flows:checkLists(marks)
  local store = self.list_store
  if not store or type(marks) ~= "table" then return end
  local user_id = User:getId()
  local saved = store:index(user_id)
  if ListsSync.indexChanged(saved, marks) then
    self:refreshLists()
  else
    store:markChecked(user_id)
    self:queueStaleLists(saved)
  end
end

-- Structural equality of plain data, to leave a screen alone when a refresh changed nothing.
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not same(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function savedDate(saved)
  return os.date("%b %d", saved and (saved.checked_at or saved.saved_at) or os.time())
end

--
-- Your lists and the ones you follow. The saved index is on screen at once (offline,
-- with a note saying when it is from); online it is checked and, if it changed, replaced.
-- A list opens in the shelf screen (showList).
--
function Flows:showLists()
  self:screens():discard("lists")

  local user_id = User:getId()
  local store = self.list_store
  local saved = store and store:index(user_id)
  local online = Network.connected()

  local dialog = require("hardcover/lib/ui/lists_dialog"):new {
    mine = saved and saved.mine or nil,
    following = saved and saved.following or nil,
    message = not saved and (online and _("Loading your lists\226\128\166")
      or _("Lists need an internet connection the first time.")) or nil,
    select_cb = function(row)
      self:showList(row)
    end,
  }
  self:screens():track("lists", dialog)
  UIManager:show(dialog)

  if saved and #saved.mine == 0 and #saved.following == 0 then
    dialog:setMessage(noLists())
  end

  if not online then
    if saved then
      StatusDialogs.info(T(_("Offline: showing your lists as of %1."), savedDate(saved)))
    end
    return
  end

  -- Home asked a moment ago: nothing to ask again (any list not yet saved is fetched)
  if saved and ListsSync.indexFresh(saved, store.now()) then
    self:queueStaleLists(saved)
    return
  end

  self:refreshLists(function(result)
    if not Live.shown(dialog) then return end
    local lists = result and result.lists
    if not lists then
      -- the saved lists are still there: failing to check them is not worth interrupting for
      if saved then return end
      StatusDialogs.retry(result and result.failure, _("Loading your lists"),
        function() self:showLists() end,
        function() UIManager:close(dialog) end)
      return
    end
    if #lists.mine == 0 and #lists.following == 0 then
      dialog:setMessage(noLists())
      return
    end
    if saved and same(saved.mine, lists.mine) and same(saved.following, lists.following) then
      return
    end
    dialog:setLists(lists.mine, lists.following)
  end)
end

--
-- One list's books, in the shelf screen (numbered on a ranked list). The saved copy is
-- on screen at once; if Hardcover's fingerprint for the list is the one it was saved
-- with, nothing is fetched at all. Otherwise the list is downloaded (only the books the
-- device does not have, when it has the list already) and replaces it.
--
function Flows:showList(row)
  local user_id = User:getId()
  local store = self.list_store
  local saved_entries, saved
  if store and self.book_store then saved_entries, saved = store:entries(user_id, row) end

  local dialog
  local refresh

  dialog = require("hardcover/lib/ui/shelf_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = row.name,
    sortable = false,
    entries = {},
    has_more = false,
    offset = 0,
    page_size = ShelfLoader.PAGE_SIZE,
    -- the menu's "Load the rest of the list", after an interrupted first download: the
    -- whole list comes through the queue, and what this screen lacks is appended
    fetch_page = function(offset, _limit, callback)
      if not Network.connected() then
        callback(nil, _("not available offline"))
        return
      end
      self:downloadList(row, {
        front = true,
        on_done = function(result)
          if not (result and result.complete) then
            callback(nil, result and result.failure or _("no response"))
            return
          end
          local rest = {}
          for i = offset + 1, #result.entries do rest[#rest + 1] = result.entries[i] end
          callback(rest, nil, false)
        end,
      })
    end,
    select_entry_cb = function(entry)
      self:showBookDetail(entry.book_id)
    end,
    actions = store and {
      { text = _("Refresh"), callback = function() refresh() end },
    } or nil,
  }
  UIManager:show(dialog)

  local function show(entries, complete)
    if complete and #entries == 0 then
      dialog:setEmptyState(_("No books on this list yet"))
      return
    end
    dialog.offset = #entries
    dialog:setEntries(entries, not complete, true)
  end

  -- download it all again, books included: the escape hatch for anything the
  -- fingerprint did not catch
  refresh = function()
    if not Network.connected() then
      StatusDialogs.info(_("Refreshing needs an internet connection."))
      return
    end
    local loading = StatusDialogs.loading(_("Refreshing the list\226\128\166"))
    self:downloadList(row, {
      front = true,
      force = true,
      on_done = function(result)
        StatusDialogs.close(loading)
        if not Live.shown(dialog) then return end
        if result and result.complete then
          show(result.entries, true)
        else
          StatusDialogs.info(_("Couldn't refresh the list."))
        end
      end,
    })
  end

  if saved_entries then
    show(saved_entries, saved.complete)
  end

  if not Network.connected() then
    if saved then
      StatusDialogs.info(T(_("Offline: showing this list as of %1."), savedDate(saved)))
    else
      StatusDialogs.info(_("Lists need an internet connection the first time."))
      UIManager:close(dialog)
    end
    return
  end

  -- the whole point: a list that has not changed costs no request at all
  if saved and not ListsSync.needsDownload(row, saved) then
    return
  end

  local loading = not saved_entries and StatusDialogs.loading(_("Loading the list\226\128\166")) or nil
  local function stopLoading()
    if loading then
      StatusDialogs.close(loading)
      loading = nil
    end
  end

  self:downloadList(row, {
    front = true,
    -- rows appear as pages arrive when there is nothing saved to show
    on_page = not saved and function(fresh)
      stopLoading()
      if Live.shown(dialog) then
        dialog.offset = #fresh
        dialog:setEntries(fresh, true, true)
      end
    end or nil,
    on_done = function(result)
      stopLoading()
      if not Live.shown(dialog) then return end
      if result and result.complete then
        show(result.entries, true)
        return
      end
      -- a saved copy, or part of the list, is on screen: keep it (the menu can carry on)
      if saved_entries or (result and #(result.entries or {}) > 0) then return end
      StatusDialogs.retry(result and result.failure, _("Loading the list"),
        function()
          UIManager:close(dialog)
          self:showList(row)
        end,
        function() UIManager:close(dialog) end)
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
