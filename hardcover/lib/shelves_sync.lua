-- Keeping the saved shelves right: deciding which shelves changed and downloading one.
--
-- A shelf is downloaded again only when its fingerprint (Shelf.fingerprint) is not the
-- one saved with it, or the saved copy is incomplete or was changed here. The first
-- download of a shelf is its books, a page at a time. Later ones fetch only which books
-- the shelf holds (about 70 bytes a book), then just the books the device does not have
-- yet: finishing one book costs that book, not the whole Read shelf again.
--
-- Pure logic, like lists_sync.lua, and run through the same queue.

local ListsSync = require("hardcover/lib/lists_sync")
local ShelfLoader = require("hardcover/lib/shelf_loader")

local ShelvesSync = {}

-- How long Hardcover's word that a shelf is as saved holds (as for lists).
ShelvesSync.FRESH_FOR = ListsSync.FRESH_FOR

-- Rows asked for in one request when only the membership is downloaded.
ShelvesSync.MEMBERS_PAGE = 500

-- Does the saved shelf (ShelfStore:meta) need downloading, given Hardcover's fingerprint?
-- An unknown fingerprint on either side means yes.
function ShelvesSync.needsDownload(meta, fingerprint)
  if type(meta) ~= "table" or not meta.complete then return true end
  return fingerprint == nil or meta.fingerprint == nil or meta.fingerprint ~= fingerprint
end

-- Was the shelf checked recently enough to trust without asking? A clock that went
-- backwards counts as not recent.
function ShelvesSync.fresh(meta, now)
  local checked = type(meta) == "table" and tonumber(meta.checked_at)
  if not checked or not meta.complete or meta.fingerprint == nil then return false end
  local age = (now or os.time()) - checked
  return age >= 0 and age < ShelvesSync.FRESH_FOR
end

--
-- What "For you" depends on, from the shelves' fingerprints: how many books are on each
-- and your ratings, but not when they last changed (every page synced moves Currently
-- Reading's time). nil unless every shelf in `status_ids` has a fingerprint.
--
function ShelvesSync.ratingSignature(prints, status_ids)
  if type(prints) ~= "table" then return nil end
  local parts = {}
  for _, status_id in ipairs(status_ids or {}) do
    local fp = prints[status_id]
    if type(fp) ~= "string" then return nil end
    local count, sum = fp:match("^(%d+)|[^|]*|(.*)$")
    if not count then return nil end
    parts[#parts + 1] = tostring(status_id) .. ":" .. count .. ":" .. sum
  end
  return table.concat(parts, ",")
end

--
-- Download shelf `status_id` and save it. Call from inside Background.run. `opts`:
--   api          getShelf, getShelfMembers, getBooksByIds
--   shelves      the shelf store; books: the book store (both nil: nothing is kept)
--   user_id, status_id
--   fingerprint  Hardcover's, from the check just made (nil when not known)
--   alive, sleep, network   as for ShelfLoader.load
--   force        download the books in full even when the shelf is saved (Refresh)
--   on_page      function(entries), for a first download: the books so far
--
-- Returns nil when stopped, otherwise { complete, entries (as saved, when complete),
-- failure }.
--
function ShelvesSync.download(opts)
  local api, shelves = opts.api, opts.shelves
  local user_id, status_id = opts.user_id, opts.status_id
  local saved = not opts.force and shelves and shelves:meta(user_id, status_id) or nil

  if not saved then
    local result = ShelfLoader.load {
      fetch = function(offset, limit) return api:getShelf(user_id, status_id, offset, limit, true) end,
      dedupe = true,
      alive = opts.alive,
      sleep = opts.sleep,
      network = opts.network,
      on_page = opts.on_page,
    }
    if not result then return nil end
    if shelves then
      -- a partial shelf is saved (and marked so), unless it would replace a whole one
      local had = opts.force and shelves:meta(user_id, status_id)
      if result.complete or (#result.entries > 0 and not (had and had.complete)) then
        shelves:putEntries(user_id, status_id, result.entries, result.complete,
          result.complete and opts.fingerprint or nil)
      end
      if result.complete then
        result.entries = shelves:entries(user_id, status_id) or result.entries
      end
    end
    return result
  end

  local result = ShelfLoader.load {
    fetch = function(offset, limit) return api:getShelfMembers(user_id, status_id, offset, limit) end,
    page_size = ShelvesSync.MEMBERS_PAGE,
    dedupe = true,
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

  shelves:putMembers(user_id, status_id, result.entries, true, opts.fingerprint)
  return { complete = true, entries = shelves:entries(user_id, status_id) or {} }
end

return ShelvesSync
