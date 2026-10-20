-- BUG: one offline rating that Hardcover refused stopped every rating queued after it,
-- on every flush, forever. The shelf and list queues count a refusal and hold the change
-- after three; the rating queue had no such rule (and the API call hid the reason).
--
-- Expected: a refused rating is counted, held after the third refusal (kept, shown as
-- refused, retried when the user presses Sync), and the ratings after it still go. An
-- answer that never came (no response, a busy server) stops the flush without counting.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
local RatingQueue = require("hardcover/lib/rating_queue")

local function api(refuse)
  local a = { sent = {} }
  function a:updateRating(id, rating)
    if refuse[id] == "refused" then return nil, "not allowed" end
    if refuse[id] == "down" then return nil, { error = "no_response" } end
    self.sent[#self.sent + 1] = id
    return { id = id, rating = rating }
  end
  return a
end

local function queue()
  local q = RatingQueue:new { settings = KB.fakeSettings() }
  q:queue(1, 4, "A")
  q:queue(2, 5, "B")
  return q
end

print("\n== a refused offline rating ==")

KB.check("the ratings after a refused one are still sent", function()
  local q, a = queue(), api({ [1] = "refused" })
  q:flush(a)
  KB.eq(a.sent[1], 2, "second rating sent")
  KB.eq(q:count(), 1, "left waiting")
end)

KB.check("the third refusal holds it; held ones are not sent again until retried", function()
  local q, a = queue(), api({ [1] = "refused" })
  for _ = 1, 3 do q:flush(a) end
  KB.eq(q:heldCount(), 1, "held")
  q:flush(a)
  KB.eq(q:heldCount(), 1, "still held")
  q:retryHeld()
  KB.eq(q:heldCount(), 0, "retry lets it try again")
end)

KB.check("no answer stops the flush and counts nothing", function()
  local q, a = queue(), api({ [1] = "down" })
  for _ = 1, 4 do q:flush(a) end
  KB.eq(q:heldCount(), 0, "held")
  KB.eq(#a.sent, 0, "sent")
  KB.eq(q:count(), 2, "still waiting")
end)

KB.finish("a refused rating must not block the ratings after it")
