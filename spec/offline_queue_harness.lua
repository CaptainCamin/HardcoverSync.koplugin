-- What the three offline queues share: the interface a caller can rely on whichever
-- queue it holds, and the flush lock that is always released. The queues' own rules
-- are covered by their own harnesses; this checks the common part, once.
--
-- Run with:  lua spec/offline_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local OfflineQueue = require("hardcover/lib/offline_queue")
local SyncQueue = require("hardcover/lib/sync_queue")
local GoalQueue = require("hardcover/lib/goal_queue")
local RatingQueue = require("hardcover/lib/rating_queue")

-- Settings that hand out the stored table, as LuaSettings does, and count flushes.
local function settings()
  local data = {}
  return {
    data = data, flushes = 0,
    readSetting = function(_, k) return data[k] end,
    saveSetting = function(_, k, v) data[k] = v end,
    flush = function(self) self.flushes = self.flushes + 1 end,
  }
end

local QUEUES = {
  { name = "SyncQueue", class = SyncQueue, key = "pending" },
  { name = "GoalQueue", class = GoalQueue, key = "goal_ops" },
  { name = "RatingQueue", class = RatingQueue, key = "rating_ops" },
}

print("\n== every queue answers the same questions ==")

for _, q in ipairs(QUEUES) do
  check(q.name .. " is a queue, empty to begin with", function()
    local queue = q.class:new { settings = settings() }
    assert(queue:count() == 0, "count")
    assert(queue:hasPending() == false, "hasPending")
    assert(queue:heldCount() == 0, "heldCount")
    queue:retryHeld() -- must exist, and must not raise, on every queue
  end)

  check(q.name .. " keeps its data under its own settings key, made on first use", function()
    local s = settings()
    local queue = q.class:new { settings = s }
    assert(s.data[q.key] == nil)
    local store = queue:store()
    assert(type(store) == "table" and s.data[q.key] == store, "the stored table itself")
  end)

  check(q.name .. " persists through the settings' flush", function()
    local s = settings()
    local queue = q.class:new { settings = s }
    queue:persist()
    assert(s.flushes == 1)
  end)

  check(q.name .. " starts with its flush lock free", function()
    assert(q.class:new { settings = settings() }.flushing == false)
  end)
end

print("\n== counting what is waiting, held or not ==")

check("SyncQueue counts books with something queued, and the held ones among them", function()
  local queue = SyncQueue:new { settings = settings() }
  queue:enqueuePage("/a.epub", { book_id = 1, mapped_page = 10 })
  queue:enqueuePage("/b.epub", { book_id = 2, mapped_page = 20 })
  assert(queue:count() == 2 and queue:hasPending(), "count " .. queue:count())
  assert(queue:count() == queue:pendingCount(), "same as pendingCount")
  queue:get("/a.epub").failures = SyncQueue.MAX_REJECTIONS
  assert(queue:heldCount() == 1)
  queue:retryHeld()
  assert(queue:heldCount() == 0, "held ones try again")
end)

check("SyncQueue ignores a malformed entry in its count", function()
  local s = settings()
  local queue = SyncQueue:new { settings = s }
  queue:store()["/junk.epub"] = "garbage"
  assert(queue:count() == 0 and not queue:hasPending())
end)

check("GoalQueue counts its list of ops, and the held ones among them", function()
  local queue = GoalQueue:new { settings = settings() }
  local ops = queue:ops()
  ops[1] = { kind = "save", key = "local:1", form = {} }
  ops[2] = { kind = "archive", key = 7, form = {}, held = true }
  ops[3] = { kind = "nonsense", key = 8 } -- not a well-formed op
  assert(queue:count() == 2, "count " .. queue:count())
  assert(queue:heldCount() == 1)
  assert(queue:hasPending() and not queue:isEmpty())
  queue:retryHeld()
  assert(queue:heldCount() == 0)
end)

check("RatingQueue counts ratings and never holds any", function()
  local queue = RatingQueue:new { settings = settings() }
  queue:queue(5, 4.5, "A book")
  queue:queue(6, 0, "Another")
  assert(queue:count() == 2 and queue:hasPending() and not queue:isEmpty())
  assert(queue:heldCount() == 0)
end)

check("isEmpty() on the goal and rating queues is the whole queue; hasPending() is the safe call on any", function()
  local g, ra = GoalQueue:new { settings = settings() }, RatingQueue:new { settings = settings() }
  assert(g:isEmpty() and ra:isEmpty())
  for _, q in ipairs({ SyncQueue:new { settings = settings() }, g, ra }) do
    assert(q:hasPending() == false)
  end
end)

print("\n== the flush lock ==")

check("a flush that returns releases the lock and passes its result on", function()
  local q = RatingQueue:new { settings = settings() }
  local got = q:withFlushLock("busy", function() return "done" end)
  assert(got == "done" and q.flushing == false)
end)

check("a flush that raises releases the lock and passes the error on", function()
  local q = RatingQueue:new { settings = settings() }
  local ok, err = pcall(q.withFlushLock, q, "busy", function() error("boom", 0) end)
  assert(not ok and err == "boom", tostring(err))
  assert(q.flushing == false, "left locked: every later flush would be refused")
end)

check("a flush that starts while one is running gets the busy answer, and does not run", function()
  local q = RatingQueue:new { settings = settings() }
  local ran = false
  local inner
  q:withFlushLock("busy", function()
    inner = q:withFlushLock("busy", function() ran = true; return "no" end)
    return "outer"
  end)
  assert(inner == "busy" and not ran)
end)

check("the busy answer can be worked out when asked", function()
  local q = RatingQueue:new { settings = settings() }
  local inner
  q:withFlushLock(nil, function()
    inner = q:withFlushLock(function() return "computed" end, function() end)
  end)
  assert(inner == "computed")
end)

print("\n== the queues' flushes use it ==")

check("a second rating flush while one is out sends nothing twice", function()
  local q = RatingQueue:new { settings = settings() }
  q:queue(5, 4, "A book")
  local sent, second = 0, nil
  local api = {}
  function api:updateRating()
    sent = sent + 1
    -- the first request is out; a second flush starts meanwhile
    if sent == 1 then second = q:flush(api) end
    return { id = 5 }
  end
  local waiting = q:flush(api)
  assert(sent == 1, "sent " .. sent)
  assert(second == 1, "the second flush reports what is still waiting: " .. tostring(second))
  assert(waiting == 0)
end)

check("a goal flush whose callback raises does not wedge the queue", function()
  local q = GoalQueue:new { settings = settings() }
  q:ops()[1] = { kind = "save", key = 3, form = { name = "g", metric = "book", target = 5,
    start_date = "2026-01-01", end_date = "2026-12-31" } }
  local api = { saveGoal = function() return { id = 3 } end }
  local ok = pcall(q.flush, q, api, { on_saved = function() error("screen gone") end })
  assert(not ok)
  assert(q.flushing == false, "locked for good after a raising callback")
end)

check("a goal flush that is already running reports itself as stopped", function()
  local q = GoalQueue:new { settings = settings() }
  q.flushing = true
  local result = q:flush({})
  assert(result.stopped == true and result.sent == 0)
end)

r.finish()
