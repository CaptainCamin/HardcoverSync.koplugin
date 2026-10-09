-- Refreshes the home screen from the network, one request after another.
--
-- The screen is already up with what was saved; this asks Hardcover for the counts,
-- the books you are reading, the list count and the goals, saves what comes back,
-- and tells the screen only about what changed. Each request is independent of the
-- others' outcome, and the screen being closed stops the sequence between requests.
--
-- Pure logic, like shelf_loader.lua: everything it touches is handed in, so it runs
-- under stock Lua in the spec suite. Call it from inside Background.run.

local Home = require("hardcover/lib/home")

local HomeLoader = {}

-- How long to wait before asking for the goals a second time.
HomeLoader.GOALS_RETRY_AFTER = 3

--
-- `opts`:
--   api            getShelfCounts, getCurrentlyReading, getListCount, getGoals
--   cache          the shelf cache, or nil (nothing is saved then)
--   alive          function() -> true while the home screen is still up
--   sleep          function(seconds), a pause that does not freeze the UI
--   user_id, status_ids
--   saved_counts, saved_reading   what the screen was drawn from, to tell what changed
--   shown_reading  function(entries) -> the cards with offline reading laid over them
--   on_counts(counts), on_reading(shown), on_list_count(n, marks), on_goals(goals)
--                  what to do with each answer that changed or is new
--
function HomeLoader.refresh(opts)
  local api, cache, alive = opts.api, opts.cache, opts.alive
  local user_id, ids = opts.user_id, opts.status_ids

  local counts = api:getShelfCounts(user_id, ids)

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

  local entries = api:getCurrentlyReading(user_id, 5)
  if not alive() then
    return
  end

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

  -- the "More lists" tile's number: yours plus the ones you follow; and each list's
  -- fingerprint, which the caller compares with the saved lists (see list_flows.lua)
  local list_count, list_marks = api:getListCount()
  if list_count and alive() then
    opts.on_list_count(list_count, list_marks)
  end

  -- the goal card: fresh goals replace the saved ones
  if alive() then
    local goals = api:getGoals()
    if not goals and alive() then
      -- refused (rate limit) or cut off: once more shortly, so the card is not left
      -- saying there is no goal when there is one
      opts.sleep(HomeLoader.GOALS_RETRY_AFTER)
      if alive() then goals = api:getGoals() end
    end
    if goals and alive() then
      if cache then cache:putGoals(user_id, goals) end
      opts.on_goals(goals)
    end
  end
end

return HomeLoader
