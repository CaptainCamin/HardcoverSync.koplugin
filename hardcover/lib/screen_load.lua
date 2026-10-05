-- The policy shared by the screens that show a saved copy first and refresh it
-- (Goals, Stats; For you in part): what to put on screen at once, and what to do
-- with the answer when it comes.
--
-- Pure logic, no KOReader requires. The wording differs per screen, so this only
-- says which case applies; the screen picks its own words.

local ScreenLoad = {}

--
-- What to show before the network answers.
--   "saved"          the saved copy, as it is
--   "saved_offline"  the saved copy, with a note that the device is offline
--   "loading"        nothing saved: a loading line
--   "needs_network"  nothing saved and no connection: say so
--
function ScreenLoad.start(saved, online)
  if saved then
    return online and "saved" or "saved_offline"
  end
  return online and "loading" or "needs_network"
end

--
-- What to do with the answer. `fresh` is what arrived (nil when the request failed),
-- `saved` the saved copy that is on screen, if any.
--   "fresh"  show it (the screen also saves it)
--   "stale"  the request failed but a saved copy is there: keep it, with a note
--   "retry"  the request failed and there is nothing to show: offer to try again
--
function ScreenLoad.finish(fresh, saved)
  if fresh then return "fresh" end
  if saved then return "stale" end
  return "retry"
end

return ScreenLoad
