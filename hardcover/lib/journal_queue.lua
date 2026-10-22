-- Notes and quotes written for a book, kept until Hardcover has them.
--
-- The journal form used to save with a blocking request, which failed with no connection and
-- lost the text. Saving now puts the entry here and returns at once; it is sent when the
-- connection is there (see HardcoverApp:_flushJournals).
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite. It lives in
-- the same settings file as the progress queue (SyncQueue).
--
-- Unlike a rating or a shelf change, every entry counts: two notes on one book are two ops, kept
-- in the order they were written. Each op carries the user it was written for; a flush sends only
-- the signed-in user's.
--
-- Hardcover has no way to say "this entry is already there", so an entry whose answer was lost
-- (sent, but the connection dropped before the reply) is sent again at the next flush and shows
-- up twice. The op is removed as soon as the reply arrives, which keeps that window small.

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local OfflineQueue = require("hardcover/lib/offline_queue")

local JournalQueue = OfflineQueue.extend({})
JournalQueue.store_key = "journal_ops"

local EVENTS = { note = true, quote = true }

local function valid(op)
  return type(op) == "table" and op.book_id ~= nil and EVENTS[op.event] == true and type(op.id) == "string"
end

function JournalQueue:valid(op)
  return valid(op)
end

-- waiting entries by id, as stored
function JournalQueue:ops()
  return self:store()
end

function JournalQueue:isEmpty()
  return not self:hasPending()
end

local function copyStrings(list)
  local out = {}
  for _, value in ipairs(type(list) == "table" and list or {}) do
    if type(value) == "string" and value ~= "" then out[#out + 1] = value end
  end
  return out
end

--
-- Keep an entry to send. `entry`: { user_id, book_id, edition_id, event ("note" or "quote"),
-- text, privacy_setting_id, page, pages, tags, hidden_tags (lists of strings), title }.
-- Returns the id it is kept under, or nil when it is not an entry (no book, no kind).
--
function JournalQueue:queue(entry)
  if type(entry) ~= "table" or entry.book_id == nil or not EVENTS[entry.event] then return nil end
  local ops = self:ops()
  local seq = 0
  for _, op in pairs(ops) do
    if type(op) == "table" and (tonumber(op.seq) or 0) > seq then seq = tonumber(op.seq) end
  end
  seq = seq + 1
  local id = string.format("%d-%d", os.time(), seq)
  ops[id] = {
    id = id, seq = seq, at = os.time(),
    user_id = entry.user_id, book_id = tonumber(entry.book_id) or entry.book_id,
    edition_id = tonumber(entry.edition_id), event = entry.event, text = entry.text or "",
    privacy_setting_id = tonumber(entry.privacy_setting_id) or HARDCOVER.PRIVACY.PUBLIC,
    page = tonumber(entry.page), pages = tonumber(entry.pages),
    tags = copyStrings(entry.tags), hidden_tags = copyStrings(entry.hidden_tags),
    title = entry.title,
  }
  self:persist()
  return id
end

--
-- What Hardcover's insert_reading_journal takes for a waiting entry. `json` is KOReader's, for
-- the empty list that must go out as [] and not {}; the specs pass a stand-in.
--
function JournalQueue.object(op, json)
  local tags = {}
  if json and json.util and json.util.InitArray then tags = json.util.InitArray(tags) end
  for _, tag in ipairs(op.tags or {}) do
    tags[#tags + 1] = { category = HARDCOVER.CATEGORY.TAG, tag = tag, spoiler = false }
  end
  for _, tag in ipairs(op.hidden_tags or {}) do
    tags[#tags + 1] = { category = HARDCOVER.CATEGORY.TAG, tag = tag, spoiler = true }
  end
  local object = {
    book_id = op.book_id,
    event = op.event,
    entry = op.text,
    edition_id = op.edition_id,
    privacy_setting_id = op.privacy_setting_id,
    tags = tags,
  }
  if op.page then
    object.metadata = { position = { type = "pages", value = op.page, possible = op.pages } }
  end
  return object
end

-- every waiting entry in the order it was written
function JournalQueue:list()
  local out = {}
  for _, op in pairs(self:ops()) do
    if valid(op) then out[#out + 1] = op end
  end
  table.sort(out, function(a, b) return (tonumber(a.seq) or 0) < (tonumber(b.seq) or 0) end)
  return out
end

function JournalQueue:cancel(id)
  local ops = self:ops()
  local had = ops[id] ~= nil
  ops[id] = nil
  self:persist()
  return had
end

--
-- Send what is waiting, one request each, oldest first. An entry Hardcover did not answer for
-- stays queued and stops the flush (the next ones would wait for the same connection). One it
-- refused is counted and the rest go on; the third refusal in a row holds it until the user
-- presses Sync (retryHeld).
--
-- opts: { user_id (only this user's entries are sent; without one nothing is), json (KOReader's),
-- on_sent(op, entry) }. Returns { waiting, held, stopped } counting this user's entries only: one
-- written under another account stays (it is text somebody typed) but is not this flush's to wait on.
--
function JournalQueue:flush(api, opts)
  opts = opts or {}
  local function mine(op)
    return op.user_id == nil or tonumber(op.user_id) == tonumber(opts.user_id)
  end
  local function tally(stopped)
    local waiting, held = 0, 0
    for _, op in ipairs(self:list()) do
      if mine(op) then
        waiting = waiting + 1
        if op.held then held = held + 1 end
      end
    end
    return { waiting = waiting, held = held, stopped = stopped }
  end
  if opts.user_id == nil then return tally(true) end

  return self:withFlushLock(function() return tally(true) end, function()
    local ops = self:ops()
    for key, op in pairs(ops) do
      if not valid(op) then ops[key] = nil end
    end
    local stopped = false
    for _, op in ipairs(self:list()) do
      if mine(op) and not op.held then
        local entry, err = api:createJournalEntry(JournalQueue.object(op, opts.json))
        if entry then
          ops[op.id] = nil
          self:persist()
          if opts.on_sent then opts.on_sent(op, entry) end
        elseif OfflineQueue.transient(err) then
          stopped = true
          break
        else
          OfflineQueue.reject(op, err)
          self:persist()
        end
      end
    end
    return tally(stopped)
  end)
end

-- Let held entries try again (pressing Sync).
function JournalQueue:retryHeld()
  for _, op in pairs(self:ops()) do
    if type(op) == "table" then op.held, op.failures, op.reason = nil, nil, nil end
  end
  self:persist()
end

return JournalQueue
