-- Refreshes the home screen from the network, in two requests.
--
-- The screen is already up with what was saved; this asks Hardcover for the counts,
-- then for the books you are reading, the list count and the goals together (each
-- request forks a process and makes its own TLS round trip, seconds on an e-reader),
-- saves what comes back, and tells the screen only about what changed. A part that
-- does not come back leaves its part of the screen alone, and the screen being closed
-- stops the sequence between requests.
--
-- Pure logic, like shelf_loader.lua: everything it touches is handed in, so it runs
-- under stock Lua in the spec suite. Call it from inside Background.run.

local Home = require("hardcover/lib/home")

local HomeLoader = {}

-- How long to wait before asking for the goals a second time.
HomeLoader.GOALS_RETRY_AFTER = 3

--
-- `opts`:
--   api            getShelfCounts, getHomeSummary, getGoals (the goals' retry)
--   cache          the shelf cache, or nil (nothing is saved then)
--   alive          function() -> true while the home screen is still up
--   sleep          function(seconds), a pause that does not freeze the UI
--   user_id, status_ids
--   saved_counts, saved_reading   what the screen was drawn from, to tell what changed
--   shown_reading  function(entries) -> the cards with offline reading laid over them
--   on_counts(counts), on_prints(fingerprints), on_reading(shown), on_list_count(n, marks),
--   on_goals(goals)
--                  what to do with each answer that changed or is new
--
function HomeLoader.refresh(opts)
  local api, cache, alive = opts.api, opts.cache, opts.alive
  local user_id, ids = opts.user_id, opts.status_ids

  local counts, _err, prints = api:getShelfCounts(user_id, ids)

  -- the shelves' fingerprints, which the caller compares with the saved shelves
  if prints and alive() and opts.on_prints then
    opts.on_prints(prints)
  end

  -- failed or cancelled: the saved numbers are still on screen, leave them
  if counts and alive() then
    if cache then
      cache:putCounts(user_id, counts)
    end
    -- a refresh that changed nothing repaints nothing
    if not Home.sameCounts(counts, opts.saved_counts, ids) then
      opts.on_counts(counts)
    end
  end

  if not alive() then
    return
  end

  -- the books being read, the lists and the goals: one request (see Api:getHomeSummary)
  local summary = api:getHomeSummary(user_id, 5) or {}
  if not alive() then
    return
  end

  local entries = summary.reading
  if entries then
    if cache then
      cache:putReading(user_id, entries)
    end
    -- the saved copy keeps what Hardcover said; the card shows it with the queue over it
    local shown = opts.shown_reading(entries)
    if not Home.sameCards(shown, opts.shown_reading(opts.saved_reading)) then
      opts.on_reading(shown)
    end
  end

  -- the number of lists: yours plus the ones you follow; and each list's
  -- fingerprint, which the caller compares with the saved lists (see list_flows.lua)
  if summary.list_count then
    opts.on_list_count(summary.list_count, summary.list_marks)
  end

  -- the goals: fresh goals replace the saved ones (the Goals tab and offline read them)
  local goals = summary.goals
  if not goals then
    -- refused (rate limit) or cut off: once more shortly, so the card is not left
    -- saying there is no goal when there is one
    opts.sleep(HomeLoader.GOALS_RETRY_AFTER)
    if not alive() then
      return
    end
    goals = api:getGoals()
  end
  if goals and alive() then
    if cache then cache:putGoals(user_id, goals) end
    if opts.on_goals then opts.on_goals(goals) end
  end
end

return HomeLoader
