-- Keeping the saved lists right: deciding which lists have changed, downloading one,
-- and doing every list download one after another.
--
-- A list is downloaded again only when its fingerprint (Lists.fingerprint) is not the
-- one saved with it, or the saved copy is incomplete. The first download of a list is
-- its books, a page at a time. Later ones fetch only which books the list holds now,
-- then just the books the device does not have yet: a list that gained one book costs
-- that book, not the whole list again.
--
-- Pure logic, like shelf_loader.lua: the API, the stores and the way to run a block in
-- the background are handed in, so this runs under stock Lua in the spec suite.

local Lists = require("hardcover/lib/lists")
local ShelfLoader = require("hardcover/lib/shelf_loader")

local ListsSync = {}

-- How long Hardcover's word that the lists are as saved holds: a screen opened within
-- this of a check (on Home, or the lists screen itself) does not ask again.
ListsSync.FRESH_FOR = 300

-- Books asked for in one request when a list gained books the device does not have.
ListsSync.BOOKS_PER_REQUEST = 100

-- Does the saved copy of list `row` (ListStore:contents) need downloading?
function ListsSync.needsDownload(row, saved)
  if type(saved) ~= "table" or not saved.complete then return true end
  local fingerprint = Lists.fingerprint(row)
  return fingerprint == nil or saved.fingerprint ~= fingerprint
end

-- The rows of `rows` whose saved copy needs downloading; `lookup(row)` is the saved
-- copy (or nil).
function ListsSync.stale(rows, lookup)
  local out = {}
  for _, row in ipairs(rows or {}) do
    if ListsSync.needsDownload(row, lookup(row)) then out[#out + 1] = row end
  end
  return out
end

--
-- Is the saved index (ListStore:index) out of date, given Home's marks (Lists.marks)?
-- Yes when nothing is saved, a list came or went, or any list's fingerprint moved: the
-- index then has to be fetched again, as a list's name, count and covers come with it.
--
function ListsSync.indexChanged(index, marks)
  if type(index) ~= "table" or type(marks) ~= "table" then return true end
  local saved, n = {}, 0
  for _, group in ipairs({ index.mine or {}, index.following or {} }) do
    for _, row in ipairs(group) do
      saved[tostring(row.source) .. ":" .. tostring(row.id)] = row
      n = n + 1
    end
  end
  if n ~= #marks then return true end
  for _, mark in ipairs(marks) do
    local row = saved[tostring(mark.source) .. ":" .. tostring(mark.id)]
    if not row or mark.fingerprint == nil or Lists.fingerprint(row) ~= mark.fingerprint then
      return true
    end
  end
  return false
end

-- Was the saved index checked recently enough to trust without asking (FRESH_FOR)?
-- A clock that went backwards counts as not recent.
function ListsSync.indexFresh(index, now)
  local checked = type(index) == "table" and tonumber(index.checked_at)
  if not checked then return false end
  local age = (now or os.time()) - checked
  return age >= 0 and age < ListsSync.FRESH_FOR
end

--
-- Download list `row` and save it. Call from inside Background.run. `opts`:
--   api        getListBooks, getListMembers, getBooksByIds
--   lists      the list store; books: the book store (both nil: nothing is saved, the
--              list is just downloaded, as before lists were kept)
--   user_id, row
--   alive      function() -> false to stop (the plugin is closing)
--   sleep, network   as for ShelfLoader.load
--   force      true to download the books in full even when the list is saved (Refresh)
--   on_page    function(entries), for a first download: the books so far
--
-- Returns nil when stopped, otherwise { complete, entries (the list as saved, when
-- complete), failure }.
--
function ListsSync.download(opts)
  local api, lists, books, row = opts.api, opts.lists, opts.books, opts.row
  local saved = not opts.force and lists and lists:contents(opts.user_id, row.id) or nil

  if not saved then
    local result = ShelfLoader.load {
      fetch = function(offset, limit)
        return api:getListBooks(row.id, row.source, row.ranked, offset, limit, true)
      end,
      use_has_more = true,
      alive = opts.alive,
      sleep = opts.sleep,
      network = opts.network,
      on_page = opts.on_page,
    }
    if not result then return nil end
    -- a partial list is saved (and marked so), unless it would replace a whole one
    if lists then
      local had = opts.force and lists:contents(opts.user_id, row.id)
      if result.complete or (#result.entries > 0 and not (had and had.complete)) then
        lists:putEntries(opts.user_id, row, result.entries, result.complete)
      end
      if result.complete then
        result.entries = lists:entries(opts.user_id, row) or result.entries
      end
    end
    return result
  end

  local result = ShelfLoader.load {
    fetch = function(offset, limit) return api:getListMembers(row.id, row.source, offset, limit) end,
    use_has_more = true,
    alive = opts.alive,
    sleep = opts.sleep,
    network = opts.network,
  }
  if not result then return nil end
  -- the saved copy stays as it is until the new one is whole
  if not result.complete then return result end

  local ids = {}
  for i, m in ipairs(result.entries) do ids[i] = m.book_id end
  local fetched = ListsSync.fetchMissing(opts, ids)
  if fetched ~= true then return fetched end

  lists:putMembers(opts.user_id, row, result.entries, true)
  return { complete = true, entries = lists:entries(opts.user_id, row) or {} }
end

--
-- Fetch and save the books among `ids` the device does not have whole, BOOKS_PER_REQUEST
-- at a time, waiting if Hardcover says to slow down. `opts` as for download (api, books,
-- alive, sleep, network). Returns true when all are saved, nil when stopped, or a
-- download result saying why not.
--
function ListsSync.fetchMissing(opts, ids)
  local missing = opts.books:missing(ids)
  for start = 1, #missing, ListsSync.BOOKS_PER_REQUEST do
    if not opts.alive() then return nil end
    if opts.network and not opts.network.connected() then
      return { complete = false, entries = {}, failure = "no internet connection" }
    end
    local chunk = {}
    for i = start, math.min(start + ListsSync.BOOKS_PER_REQUEST - 1, #missing) do
      chunk[#chunk + 1] = missing[i]
    end
    local fetched, err = ShelfLoader.patient(function() return opts.api:getBooksByIds(chunk) end, opts.sleep)
    if not opts.alive() then return nil end
    if not fetched then
      return { complete = false, entries = {}, failure = err }
    end
    opts.books:saveRows(fetched)
  end
  return true
end

-- ------------------------------------------------------------------ the queue

--
-- Every list request goes through one queue, one at a time: two requests in flight at
-- once have lost one of them before (the similar books strip, 1.3.3). A screen that
-- wants a list that is already queued or downloading waits for that download instead
-- of starting its own.
--
-- `opts.run(fn)` runs fn in the background (Background.run: inline when already inside
-- one, which is how Home's refresh carries straight on into the lists). A job is
-- { key, work = function() -> result }.
--
local Queue = {}
Queue.__index = Queue

function ListsSync.newQueue(opts)
  return setmetatable({
    run = opts.run,
    alive = opts.alive or function() return true end,
    jobs = {},
    waiting = {},
    running = false,
  }, Queue)
end

function Queue:has(key)
  if self.current == key then return true end
  for _, job in ipairs(self.jobs) do
    if job.key == key then return true end
  end
  return false
end

-- Call `fn(result)` when the job `key` is done (result nil if it never ran).
function Queue:wait(key, fn)
  if not fn then return end
  local list = self.waiting[key] or {}
  list[#list + 1] = fn
  self.waiting[key] = list
end

-- Queue a job, unless one with its key is already queued or running. `front` puts it
-- (or the queued one) first: a screen is waiting on it.
function Queue:add(job, front)
  for i, queued in ipairs(self.jobs) do
    if queued.key == job.key then
      if front and i > 1 then
        table.remove(self.jobs, i)
        table.insert(self.jobs, 1, queued)
      end
      return false
    end
  end
  if self.current == job.key then return false end
  if front then
    table.insert(self.jobs, 1, job)
  else
    self.jobs[#self.jobs + 1] = job
  end
  return true
end

local function notify(self, key, result)
  local list = self.waiting[key]
  self.waiting[key] = nil
  for _, fn in ipairs(list or {}) do
    pcall(fn, result)
  end
end

-- Work through the queue, if that is not already happening.
function Queue:start()
  if self.running then return end
  self.running = true
  self.run(function()
    while #self.jobs > 0 and self.alive() do
      local job = table.remove(self.jobs, 1)
      self.current = job.key
      -- a job that raises must not leave the queue stuck as running
      local ok, result = pcall(job.work)
      self.current = nil
      notify(self, job.key, ok and result or nil)
    end
    -- stopped (closing): whoever waits is told nothing will come
    for _, job in ipairs(self.jobs) do notify(self, job.key, nil) end
    if not self.alive() then self.jobs = {} end
    self.running = false
  end)
end

return ListsSync
