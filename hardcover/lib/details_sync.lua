-- Save the details of every linked book on the device, many books to a request.
--
-- Opening a book's details screen saves its details (book_store.lua), so it opens offline
-- afterwards. This does the same for the books that were linked but never opened, so a library
-- linked in one go (bulk_link.lua) is complete offline too. It asks for BATCH books at a time
-- (two requests however many: Api:getBookDetails) and only for books with nothing saved.
--
-- Everything outside the scan is passed in, so it can be driven from a spec: `fetch(batch)` gives
-- the answers for { { book_id, edition_id }, ... } (nil when the request failed), and
-- `save(book_id, edition_id, detail)` saves one (false when it could not).

local DetailsSync = {}

-- Books to a request. Hardcover's limit is on requests, not rows, and 25 books of details are a
-- few hundred kilobytes.
DetailsSync.BATCH = 25

-- Seconds between requests: a batch costs two, and the API allows 60 a minute.
DetailsSync.RATE = 3

-- The most books to fetch in one run. The device keeps this many books' details (see
-- BookStore.OPENED_CAP); fetching more would only push the earliest of them out again.
DetailsSync.MAX = 500

local function key(book_id, edition_id)
  return string.format("%d/%d", book_id, edition_id or 0)
end

-- The books to fetch: `books` is the saved per-book settings (filename -> settings), and
-- `has_detail(book_id, edition_id)` says one is saved already. Each book (and edition) once, in
-- the order of its id.
function DetailsSync.pending(books, has_detail)
  local items, seen = {}, {}
  for _, setting in pairs(books or {}) do
    local book_id = type(setting) == "table" and tonumber(setting.book_id)
    if book_id then
      local edition_id = tonumber(setting.edition_id)
      local k = key(book_id, edition_id)
      if not seen[k] then
        seen[k] = true
        if not has_detail(book_id, edition_id) then
          items[#items + 1] = { book_id = book_id, edition_id = edition_id }
        end
      end
    end
  end
  table.sort(items, function(a, b)
    if a.book_id ~= b.book_id then return a.book_id < b.book_id end
    return (a.edition_id or 0) < (b.edition_id or 0)
  end)
  return items
end

-- A scan over `items`. `deps` is { fetch, save }.
function DetailsSync.new(items, deps)
  local scan_items, left_out = {}, 0
  for i, item in ipairs(items or {}) do
    if i <= DetailsSync.MAX then scan_items[i] = item else left_out = left_out + 1 end
  end
  return {
    items = scan_items,
    deps = deps,
    index = 0,
    cancelled = false,
    saved = 0,
    -- asked for, and Hardcover did not have it
    missing = 0,
    errors = 0,
    left_out = left_out,
  }
end

function DetailsSync.total(scan)
  return #scan.items
end

function DetailsSync.done(scan)
  return scan.cancelled or scan.index >= #scan.items
end

-- Fetch and save the next batch. Returns true when it called Hardcover.
function DetailsSync.step(scan)
  if DetailsSync.done(scan) then return false end
  local first = scan.index + 1
  local last = math.min(scan.index + DetailsSync.BATCH, #scan.items)
  scan.index = last
  local batch = {}
  for i = first, last do batch[#batch + 1] = scan.items[i] end

  -- nil is a failed request (offline, rate limit, expired token), not "Hardcover has none of them"
  local ok, answers = pcall(scan.deps.fetch, batch)
  if not ok or type(answers) ~= "table" then
    scan.errors = scan.errors + #batch
    return true
  end

  local found = {}
  for _, answer in ipairs(answers) do
    if tonumber(answer.book_id) then
      found[key(tonumber(answer.book_id), tonumber(answer.edition_id))] = answer.detail
    end
  end
  for _, item in ipairs(batch) do
    local detail = found[key(item.book_id, item.edition_id)]
    if not detail then
      scan.missing = scan.missing + 1
    else
      -- `save` says false when it could not keep it
      local ok_save, kept = pcall(scan.deps.save, item.book_id, item.edition_id, detail)
      if ok_save and kept ~= false then
        scan.saved = scan.saved + 1
      else
        scan.errors = scan.errors + 1
      end
    end
  end
  return true
end

-- The words for the end of a run (or while it goes: `progress`).
function DetailsSync.progress(scan)
  return string.format("Saving details… %d / %d books\n\n(tap to stop)", scan.index, #scan.items)
end

function DetailsSync.summary(scan)
  local lines = {}
  lines[#lines + 1] = scan.cancelled and "Stopped." or "Details saved."
  lines[#lines + 1] = string.format("Saved: %d", scan.saved)
  if scan.missing > 0 then lines[#lines + 1] = string.format("Not found on Hardcover: %d", scan.missing) end
  if scan.errors > 0 then lines[#lines + 1] = string.format("Could not save: %d (try again later)", scan.errors) end
  if scan.left_out > 0 then
    lines[#lines + 1] = string.format("%d more were left out: the device keeps the details of %d books.",
      scan.left_out, DetailsSync.MAX)
  end
  if scan.cancelled and scan.index < #scan.items then
    lines[#lines + 1] = string.format("%d not tried yet.", #scan.items - scan.index)
  end
  return table.concat(lines, "\n")
end

return DetailsSync
