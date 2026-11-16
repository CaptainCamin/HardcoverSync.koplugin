-- What the book details page says about this book's pending work, in words: the one question
-- waiting (if any), and whether a rating, a review or a read edit is waiting, held or being
-- checked. Pure data over the queues, so the page and its tests share one rule.

local _ = require("gettext")
local SyncConflicts = require("hardcover/lib/sync_conflicts")

local BookSyncState = {}

local function rowFor(rows, user_book_id, book_id)
  for _i, row in ipairs(rows or {}) do
    if (book_id ~= nil and row.book_id ~= nil and tostring(row.book_id) == tostring(book_id))
      or (user_book_id ~= nil and row.user_book_id ~= nil
        and tostring(row.user_book_id) == tostring(user_book_id)) then
      return row
    end
  end
end

local function heldText(row)
  if not row then return _("Waiting to send") end
  if row.parked then return _("Needs your decision") end
  if row.held or row.reason then
    return row.reason == "scope" and _("Sign in again to send it") or _("Hardcover refused it")
  end
  if row.blocked then return _("Waiting for an earlier change") end
  return _("Waiting to send")
end

function BookSyncState.forBook(opts, book_id, user_book_id, user_id)
  opts = opts or {}
  local state = { decision = nil, rating_state = nil, review_state = nil, read_state = nil,
    note_lines = {} }

  local sync = opts.sync_queue
  if sync and sync.decisionForBook then
    state.decision = sync:decisionForBook(book_id, user_id)
  end

  if opts.rating_queue then
    local waiting = opts.rating_queue:get(user_book_id, book_id, user_id)
    if waiting ~= nil then
      state.rating_state = heldText(rowFor(opts.rating_queue:list(user_id), user_book_id, book_id))
    end
  end

  if opts.review_queue then
    local waiting = opts.review_queue:get(user_book_id, book_id, user_id)
    if waiting then
      state.review_state = heldText(rowFor(opts.review_queue:list(user_id), user_book_id, book_id))
    end
  end

  -- A rating or review clash is also a question the book should point at, even when the
  -- reading queue has no question of its own.
  if not state.decision and opts.rating_queue and opts.rating_queue.decisionForBook then
    state.decision = opts.rating_queue:decisionForBook(book_id, user_id, user_book_id)
  end
  if not state.decision and opts.review_queue and opts.review_queue.decisionForBook then
    state.decision = opts.review_queue:decisionForBook(book_id, user_id, user_book_id)
  end

  local actions = opts.read_actions
  if not actions and sync and sync.readActions then actions = sync:readActions(book_id) end
  for _i, action in ipairs(actions or {}) do
    if action.conflict then
      state.read_state = _("Needs your decision")
      break
    elseif action.checking then
      state.read_state = _("Checking what synced")
    elseif action.wait then
      state.read_state = _("Waiting for the current read to finish")
    elseif not state.read_state then
      state.read_state = _("Waiting to send")
    end
  end

  if state.decision then
    local title = state.decision.title or _("This book")
    state.note_lines[1] = SyncConflicts.decisionText(title, state.decision)
    local note = SyncConflicts.decisionNote(state.decision)
    if note then state.note_lines[2] = note end
  end

  return state
end

return BookSyncState
