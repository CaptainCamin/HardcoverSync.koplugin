-- When to offer "Currently Reading" for a book that is being read but is not on that shelf.
-- Pure: no KOReader, no settings, no network, so it can be tested.
--
-- Pages are counted on the device as the reader turns them forward one at a time (a jump to a
-- chapter or a long swipe is not reading). When the count reaches the threshold the reader is
-- asked once; "Not now" is kept for the session, so the question does not come back.
--
--   local state = StartReading.new()
--   StartReading.turn(state, old_page, new_page, threshold)  -> true when it is time to ask
--   StartReading.declined(state)                               -- "Not now"
--   StartReading.reset(state)                                  -- a different book was opened

local StartReading = {}

-- the most pages one turn may move forward and still count as reading
StartReading.MAX_STEP = 3

function StartReading.new()
  return { pages = 0, asked = false }
end

function StartReading.reset(state)
  state.pages, state.asked = 0, false
end

function StartReading.turn(state, old_page, new_page, threshold)
  if state.asked then return false end
  old_page, new_page = tonumber(old_page), tonumber(new_page)
  if not (old_page and new_page) then return false end
  local step = new_page - old_page
  if step >= 1 and step <= StartReading.MAX_STEP then
    state.pages = state.pages + step
  end
  if state.pages >= (tonumber(threshold) or 5) then
    state.asked = true
    return true
  end
  return false
end

-- "Not now": asked stays true for the session, and the count restarts so nothing carries over.
function StartReading.declined(state)
  state.pages, state.asked = 0, true
end

return StartReading
