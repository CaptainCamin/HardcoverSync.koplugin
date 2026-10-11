-- List changes made from the book details screen while offline: a book put on one of
-- your lists, or taken off it. Shown at once (the picker, the saved list and its size)
-- and sent when the connection is back.
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite. It
-- lives in the same settings file as the progress queue (SyncQueue).
--
-- One op per book and list, and opposite ops cancel: a book put on a list and taken off
-- again before anything was sent leaves nothing, and so does the reverse (taken off and
-- put back: it never left). A remove may not know the list_books row it takes off (the
-- book was put on that list a moment before going offline and the answer did not say
-- which row it made): it is looked up when the change is sent.
--
-- Every op carries the user it was made for; a flush sends only the signed-in user's.

local Lists = require("hardcover/lib/lists")
local OfflineQueue = require("hardcover/lib/offline_queue")

local ListQueue = OfflineQueue.extend({})
ListQueue.store_key = "list_ops"

local function valid(op)
  return type(op) == "table" and op.book_id ~= nil and op.list_id ~= nil and (op.kind == "add" or op.kind == "remove")
end

function ListQueue:valid(op)
  return valid(op)
end

-- waiting ops by "list:book", as stored
function ListQueue:ops()
  return self:store()
end

function ListQueue:isEmpty()
  return not self:hasPending()
end

local function keyOf(list_id, book_id)
  return tostring(tonumber(list_id) or list_id) .. ":" .. tostring(tonumber(book_id) or book_id)
end
ListQueue.keyOf = keyOf

-- the op waiting for this book on this list, or nil
function ListQueue:get(list_id, book_id)
  local op = self:ops()[keyOf(list_id, book_id)]
  if valid(op) then return op end
end

--
-- The book goes on list `list_id`, which holds `count` books now (the end of a ranked
-- list). `info`: { title, list_name }. Returns "queued", or "cancelled" when it
-- undoes a waiting remove.
--
function ListQueue:queueAdd(user_id, book_id, list_id, count, info)
  info = info or {}
  local ops = self:ops()
  local key = keyOf(list_id, book_id)
  local before = self:get(list_id, book_id)
  if before and before.kind == "remove" then
    ops[key] = nil
    self:persist()
    return "cancelled"
  end
  ops[key] = {
    kind = "add", user_id = user_id, book_id = tonumber(book_id), list_id = tonumber(list_id),
    position = tonumber(count) or 0, title = info.title, list_name = info.list_name, at = os.time(),
  }
  self:persist()
  return "queued"
end

--
-- The book comes off the list. `list_book_id` is the row to take off, if known.
-- Returns "queued", or "cancelled" when it undoes a waiting add.
--
function ListQueue:queueRemove(user_id, book_id, list_id, list_book_id, info)
  info = info or {}
  local ops = self:ops()
  local key = keyOf(list_id, book_id)
  local before = self:get(list_id, book_id)
  if before and before.kind == "add" then
    ops[key] = nil
    self:persist()
    return "cancelled"
  end
  ops[key] = {
    kind = "remove", user_id = user_id, book_id = tonumber(book_id), list_id = tonumber(list_id),
    list_book_id = tonumber(list_book_id), title = info.title, list_name = info.list_name, at = os.time(),
  }
  self:persist()
  return "queued"
end

-- every waiting op, in a stable order
function ListQueue:list()
  local out = {}
  for key, op in pairs(self:ops()) do
    if valid(op) then out[#out + 1] = { key = key, op = op } end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  local ops = {}
  for i, entry in ipairs(out) do ops[i] = entry.op end
  return ops
end

-- Cancel the change waiting for one book on one list. Returns true when there was one.
function ListQueue:cancel(list_id, book_id)
  local ops = self:ops()
  local key = keyOf(list_id, book_id)
  local had = ops[key] ~= nil
  ops[key] = nil
  self:persist()
  return had
end

-- Let held changes try again (after signing in again, say).
function ListQueue:retryHeld()
  for _, op in pairs(self:ops()) do
    if type(op) == "table" then op.held, op.failures, op.reason = nil, nil, nil end
  end
  self:persist()
end

-- Throw everything waiting away.
function ListQueue:clear()
  local ops = self:ops()
  for key in pairs(ops) do ops[key] = nil end
  self:persist()
end

--
-- Send what is waiting, one request each. `api` needs addToList(book_id, list_id,
-- position), removeFromList(list_book_id) and, for a remove that does not know its row,
-- getBookLists(book_id); each returning a result, or nil and an error. opts: user_id
-- (required); on_sent(op, result) for each change that went through (`result.id` is the
-- new row's id for an add). Stops at the first failure that says the server could not be
-- asked; one it refused is counted and the rest go on.
-- Returns { sent = n, held = n, waiting = n, stopped = bool }.
--
function ListQueue:flush(api, opts)
  opts = opts or {}
  local busy = function()
    return { sent = 0, held = self:heldCount(), waiting = self:count(), stopped = true }
  end
  return self:withFlushLock(busy, function() return self:_flush(api, opts) end)
end

-- One op's request. Returns result (truthy when done), err.
local function send(api, op)
  if op.kind == "add" then
    return api:addToList(op.book_id, op.list_id, op.position)
  end
  local list_book_id = op.list_book_id
  if not list_book_id then
    local fresh, err = api:getBookLists(op.book_id)
    if not fresh then return nil, err end
    local outcome, found = Lists.resolveLookup(fresh, op.list_id)
    -- off it already, or the list is gone: nothing left to take off
    if outcome == "already_off" or outcome == "not_found" then return { id = false } end
    if outcome ~= "remove" then return nil, "Hardcover did not say which row to remove" end
    list_book_id = found
  end
  return api:removeFromList(list_book_id)
end

function ListQueue:_flush(api, opts)
  local ops = self:ops()
  local sent, stopped = 0, false
  if opts.user_id == nil then
    return { sent = 0, held = self:heldCount(), waiting = self:count(), stopped = true }
  end

  local keys = {}
  for key, op in pairs(ops) do
    if not valid(op) or (op.user_id ~= nil and op.user_id ~= opts.user_id) then
      ops[key] = nil -- junk, or made for an account that is not signed in any more
    else
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)

  for _, key in ipairs(keys) do
    local op = ops[key]
    if op and not op.held then
      local ok, result, err = pcall(send, api, op)
      if not ok then result, err = nil, nil end

      if result then
        sent = sent + 1
        if ops[key] == op then ops[key] = nil end
        self:persist()
        if opts.on_sent then opts.on_sent(op, result) end
      elseif OfflineQueue.transient(err) then
        stopped = true
        break
      else
        OfflineQueue.reject(op, err)
        self:persist()
      end
    end
  end

  return { sent = sent, held = self:heldCount(), waiting = self:count(), stopped = stopped }
end

return ListQueue
