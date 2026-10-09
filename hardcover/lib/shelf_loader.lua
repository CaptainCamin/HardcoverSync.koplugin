-- Loads a whole shelf, a page at a time, and says how it ended.
--
-- Pure logic (gettext is the only KOReader require): the API, the connectivity
-- check, the pause and the "is the screen still there" test are all handed in, so
-- this runs under stock Lua in the spec suite and a screen (dialog_manager.lua)
-- only draws what it reports. Call it from inside Background.run: each request
-- yields to the UI and `sleep` waits without freezing it.

local _ = require("gettext")

local unpack = unpack or table.unpack -- luacheck: ignore (5.1 and LuaJIT have it bare)

local ShelfLoader = {}

-- How many books each request asks for. The loop keeps asking until a page comes
-- back empty rather than until one comes back short, so a server that returns fewer
-- than requested still yields the whole shelf.
--
-- 100, not 50: a 600-book shelf is 7 requests instead of 13. Hardcover allows
-- 10 requests back to back and then one a second (60 a minute), and a quick
-- connection loading page after page uses the burst up -- seen against the real
-- API, where the later pages came back 429. The API accepts far more per request
-- (500 was fine) but each book carries its description for the offline copy, so
-- a page is already 70-140 KB.
ShelfLoader.PAGE_SIZE = 100

-- A tap cancels a request in flight (KOReader's rule for a dismissable
-- subprocess). Loading a long shelf takes several requests, and the reader will
-- tap while it runs, so a cancelled page is asked for again this many times
-- before the load gives up.
ShelfLoader.PAGE_RETRIES = 3

-- A shelf this long is not being loaded to be read; stop rather than loop.
ShelfLoader.MAX_PAGES = 200

-- Told to slow down (HTTP 429): wait, then ask for the same page again. The
-- bucket refills at one request a second, so a couple of seconds is enough; a
-- load that is still refused after this many waits gives up like any failure.
ShelfLoader.RATE_LIMIT_WAITS = 5

--
-- Load the whole list, a page at a time. `opts`:
--   fetch       function(offset, limit) -> entries | nil, err [, has_more]
--   alive       function() -> true while the screen that asked is still up
--   sleep       function(seconds), a pause that does not freeze the UI
--   network     optional, has connected(): checked before each request
--   dedupe      true to drop a book seen twice (a shelf can change while it loads,
--               shifting later rows into earlier pages)
--   use_has_more  true when `fetch` says whether more follows (a list does); the
--               load then ends on "no more" instead of waiting for an empty page
--   page_size   how many rows each request asks for (PAGE_SIZE when not given)
--   on_page     function(fresh): called after each page that had books and more
--               to come, with everything loaded so far (a list the loader keeps
--               appending to)
--
-- Returns nil when the screen went away (nothing is left to update), otherwise
-- { entries = the whole list, complete = reached the end, failure = why not }.
--
function ShelfLoader.load(opts)
  local network = opts.network
  local fresh, seen = {}, {}
  local offset, retries, pages, rate_waits = 0, 0, 0, 0
  local complete, failure = false, nil

  while true do
    -- closed while loading: nothing left to update
    if not opts.alive() then
      return nil
    end

    if network and not network.connected() then
      failure = _("no internet connection")
      break
    end

    local entries, err, has_more = opts.fetch(offset, opts.page_size or ShelfLoader.PAGE_SIZE)

    if not opts.alive() then
      return nil
    end

    if entries == nil then
      if type(err) == "table" and err.completed == false and retries < ShelfLoader.PAGE_RETRIES then
        retries = retries + 1
      elseif type(err) == "table" and err.status == 429 and rate_waits < ShelfLoader.RATE_LIMIT_WAITS then
        rate_waits = rate_waits + 1
        opts.sleep(2 * rate_waits)
      else
        failure = err
        break
      end
    else
      retries = 0
      pages = pages + 1
      offset = offset + #entries

      for _i, entry in ipairs(entries) do
        local id = opts.dedupe and (entry.user_book_id or entry.book_id) or nil
        if id == nil or not seen[id] then
          if id ~= nil then seen[id] = true end
          fresh[#fresh + 1] = entry
        end
      end

      if #entries == 0 or (opts.use_has_more and not has_more) then
        complete = true
        break
      end

      if opts.on_page then
        opts.on_page(fresh)
      end

      if pages >= ShelfLoader.MAX_PAGES then
        break
      end
    end
  end

  return { entries = fresh, complete = complete, failure = failure }
end

--
-- What the screen should do with how a load ended. `had_saved` is whether a saved
-- copy of the shelf was already on screen.
--
--   "replace"  the whole shelf arrived: save it, show it (the empty state when empty)
--   "keep"     it did not, but the saved copy is still right there; failing to
--              refresh it is not worth interrupting for
--   "partial"  it did not, nothing was saved, some books arrived: save what came
--              and leave the reload icon so the reader can carry on
--   "retry"    nothing arrived and nothing was saved: offer the retry
--
--
-- Make one request, waiting and asking again while Hardcover says to slow down (HTTP
-- 429), as load() does for pages. `call()` returns what the request returns; `sleep`
-- pauses without freezing the UI. Gives up after RATE_LIMIT_WAITS waits.
--
function ShelfLoader.patient(call, sleep)
  local waits = 0
  while true do
    local results = { call() }
    local err = results[2]
    if results[1] ~= nil or not (type(err) == "table" and err.status == 429)
        or waits >= ShelfLoader.RATE_LIMIT_WAITS then
      return unpack(results, 1, 3)
    end
    waits = waits + 1
    if sleep then sleep(2 * waits) end
  end
end

function ShelfLoader.plan(result, had_saved)
  if result.complete then return "replace" end
  if had_saved then return "keep" end
  if #result.entries > 0 then return "partial" end
  return "retry"
end

return ShelfLoader
