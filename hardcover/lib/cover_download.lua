-- Settings > Download for offline: every cover of every book on your shelves and lists,
-- kept on the device so a shelf browsed offline is not a page of blank boxes.
--
-- Covers are otherwise kept only once they have been on screen, and the oldest go when
-- the cover space is full. These are kept in a folder of their own that the limit does
-- not touch (see ImageLoader:getPinned). A cover already on the device is copied, not
-- downloaded; one already downloaded for offline is skipped, so stopping and running it
-- again carries on where it stopped.
--
-- Pure logic: what to do is planned from functions handed in, and the run takes the
-- downloading, the saving and the "stop?" question as functions too.

local CoverDownload = {}

-- What one cover costs at the small size (measured: twelve covers of a real shelf came
-- to 327 KB, about 27 KB each), for the estimate shown before starting.
CoverDownload.AVERAGE_BYTES = 30 * 1024

--
-- What to do for `urls` (covers as uploaded). `key_of(url)` is the address the cover is
-- kept under (the small size); `has_pinned(key)` and `has_seen(key)` say whether it is
-- already downloaded for offline, or on the device from being seen. Returns
-- { fetch = { { url, key } }, copy = { { url, key } }, done = n already kept, total }.
--
function CoverDownload.plan(urls, key_of, has_pinned, has_seen)
  local plan = { fetch = {}, copy = {}, done = 0, total = 0 }
  for _, url in ipairs(urls or {}) do
    local key = key_of(url)
    if key then
      plan.total = plan.total + 1
      if has_pinned(key) then
        plan.done = plan.done + 1
      elseif has_seen(key) then
        plan.copy[#plan.copy + 1] = { url = url, key = key }
      else
        plan.fetch[#plan.fetch + 1] = { url = url, key = key }
      end
    end
  end
  return plan
end

-- How many covers are not kept for offline yet.
function CoverDownload.missing(plan)
  return #plan.fetch + #plan.copy
end

-- About how much the downloads take, in bytes.
function CoverDownload.estimate(plan)
  return #plan.fetch * CoverDownload.AVERAGE_BYTES
end

-- "22 MB", "under 1 MB"
function CoverDownload.size(bytes)
  local mb = bytes / (1024 * 1024)
  if mb < 1 then return "under 1 MB" end
  return string.format("%d MB", math.floor(mb + 0.5))
end

--
-- Do it. Call from inside Background.run (each download waits for its request). `opts`:
--   plan       from plan()
--   copy(item)    keep a cover already on the device; true when done
--   fetch(item)   download and keep one; true when done
--   stopped()     true to stop (Stop was tapped, the device is going to sleep)
--   progress(done, total)   after each cover
--
-- Returns { copied, fetched, failed, stopped }.
--
function CoverDownload.run(opts)
  local plan = opts.plan
  local result = { copied = 0, fetched = 0, failed = 0, stopped = false }
  local total = #plan.copy + #plan.fetch
  local done = 0
  local function step(ok, field)
    done = done + 1
    if ok then result[field] = result[field] + 1 else result.failed = result.failed + 1 end
    if opts.progress then opts.progress(done, total) end
  end
  -- copies first: no network, and they make the count drop at once
  for _, item in ipairs(plan.copy) do
    if opts.stopped() then result.stopped = true return result end
    step(opts.copy(item), "copied")
  end
  for _, item in ipairs(plan.fetch) do
    if opts.stopped() then result.stopped = true return result end
    step(opts.fetch(item), "fetched")
  end
  return result
end

return CoverDownload
