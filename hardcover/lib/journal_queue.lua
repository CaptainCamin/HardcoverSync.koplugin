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
--
-- An entry Hardcover already has can be changed or deleted from the Journal tab, offline too: those
-- wait here as ops with an `action` ("update" with the new text, or "delete") and the entry's
-- `journal_id`. One waiting change per entry: a newer edit replaces an older one, and a delete
-- drops a waiting edit. An entry not sent yet is edited in place (editWaiting) or cancelled.

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local OfflineQueue = require("hardcover/lib/offline_queue")

local JournalQueue = OfflineQueue.extend({})
JournalQueue.store_key = "journal_ops"

local EVENTS = { note = true, quote = true }
local ACTIONS = { update = true, delete = true }

local function valid(op)
  if type(op) ~= "table" or EVENTS[op.event] ~= true or type(op.id) ~= "string" then return false end
  if op.action == nil then return op.book_id ~= nil end
  return ACTIONS[op.action] == true and tonumber(op.journal_id) ~= nil
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
-- the next op's id and place in the order
local function nextId(ops)
  local seq = 0
  for _, op in pairs(ops) do
    if type(op) == "table" and (tonumber(op.seq) or 0) > seq then seq = tonumber(op.seq) end
  end
  seq = seq + 1
  return string.format("%d-%d", os.time(), seq), seq
end

function JournalQueue:queue(entry)
  if type(entry) ~= "table" or entry.book_id == nil or not EVENTS[entry.event] then return nil end
  local ops = self:ops()
  local id, seq = nextId(ops)
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

-- The waiting change to the entry Hardcover has as `journal_id`, or nil.
function JournalQueue:changeFor(journal_id)
  for _, op in pairs(self:ops()) do
    if valid(op) and op.action and tonumber(op.journal_id) == tonumber(journal_id) then return op end
  end
end

--
-- Change or delete an entry Hardcover has. `action`: "update" or "delete". `entry`: { user_id,
-- journal_id, book_id, event ("note" or "quote"), text (the new text, for "update"), title }.
-- It replaces the entry's waiting change, if any. Returns the id it is kept under, or nil.
--
function JournalQueue:change(action, entry)
  if not ACTIONS[action] or type(entry) ~= "table" or tonumber(entry.journal_id) == nil
    or not EVENTS[entry.event] then
    return nil
  end
  if action == "update" and type(entry.text) ~= "string" then return nil end
  local ops = self:ops()
  local before = self:changeFor(entry.journal_id)
  -- the id comes first: it must not repeat the replaced change's, which may be on its way
  local id, seq = nextId(ops)
  if before then ops[before.id] = nil end
  ops[id] = {
    id = id, seq = seq, at = os.time(), action = action,
    user_id = entry.user_id, journal_id = tonumber(entry.journal_id),
    book_id = tonumber(entry.book_id) or entry.book_id, event = entry.event,
    text = action == "update" and entry.text or nil, title = entry.title,
  }
  self:persist()
  return id
end

-- Change the text of an entry that has not been sent yet. Returns whether there was one.
function JournalQueue:editWaiting(id, text)
  local op = self:ops()[id]
  if not (valid(op) and op.action == nil and type(text) == "string") then return false end
  op.text = text
  -- a refused entry gets another chance with its new text
  op.held, op.failures, op.reason = nil, nil, nil
  self:persist()
  return true
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
  -- an entry already on its way will exist on Hardcover: the flush deletes it when it arrives
  if had and ops[id] == self.sending_op and ops[id].action == nil then ops[id].discarded = true end
  ops[id] = nil
  self:persist()
  return had
end

--
-- Send what is waiting, one request each, oldest first (new entries, changes and deletes alike). An entry Hardcover did not answer for
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
      -- an entry cancelled while an earlier request was out is no longer in the queue
      if mine(op) and not op.held and ops[op.id] == op then
        local entry, err
        local sent_text = op.text
        self.sending_op = op
        if op.action == "update" then
          entry, err = api:updateJournalEntry(op.journal_id, op.text)
        elseif op.action == "delete" then
          entry, err = api:deleteJournalEntry(op.journal_id)
        else
          entry, err = api:createJournalEntry(JournalQueue.object(op, opts.json))
        end
        self.sending_op = nil
        if entry and op.discarded then
          if tonumber(entry.id) then
            self:change("delete", { user_id = op.user_id, journal_id = entry.id, book_id = op.book_id,
              event = op.event, title = op.title })
          end
        elseif entry then
          -- edited while it was on its way: the new text goes next, as a change to the entry it made
          local edited = op.action == nil and op.text ~= sent_text and tonumber(entry.id) ~= nil
            and ops[op.id] == op
          -- only this very change: a newer one may have taken its place while it was on its way
          if not edited and ops[op.id] == op then ops[op.id] = nil end
          self:persist()
          if opts.on_sent then opts.on_sent(op, entry) end
          if edited then
            op.action, op.journal_id = "update", tonumber(entry.id)
            self:persist()
          end
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
