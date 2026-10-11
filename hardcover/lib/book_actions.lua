-- The decisions behind the actions on a book's details screen, apart from drawing
-- anything: what a change of shelf asks for, which saved shelves it makes wrong, how a
-- rating waiting to be sent shows, and whether rating is possible at all. The screen
-- flows (ui/book_detail_flows.lua) act on the answers.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite.

local HARDCOVER = require("hardcover/lib/constants/hardcover")

local BookActions = {}

--
-- What to send for moving the book on screen to `status_id`.
--
-- The edition is only passed when the book is new to the library: for a book already on
-- a shelf, the upsert must not switch the edition it is read in.
--
function BookActions.shelfRequest(detail, status_id)
  local in_library = detail.user_book_id ~= nil or detail.status_id ~= nil
  return {
    book_id = detail.book.book_id,
    status_id = status_id,
    edition_id = (not in_library) and detail.book.edition_id or nil,
  }
end

-- The saved shelves (and their counts) that a change of status makes wrong: the one the
-- book left and the one it joined. Either may be nil (new to the library, or removed).
function BookActions.staleShelves(old_status_id, new_status_id)
  local ids = {}
  if old_status_id then ids[#ids + 1] = old_status_id end
  if new_status_id then ids[#ids + 1] = new_status_id end
  return ids
end

-- A rating set offline and not yet sent shows in place of the one on record. `waiting` is
-- the queued rating (0 = a clear), or nil. Returns the detail.
function BookActions.withPendingRating(detail, waiting)
  if detail and waiting then
    detail.user_rating = waiting > 0 and waiting or nil
  end
  return detail
end

-- A shelf change made offline and not yet sent shows in place of the one on record.
-- `op` is the shelf queue's waiting op for the book (ShelfQueue:get), or nil. Returns the
-- detail.
function BookActions.withPendingShelf(detail, op)
  if not (detail and op) then return detail end
  if op.kind == "remove" then
    detail.status_id, detail.user_book_id, detail.user_rating = nil, nil, nil
  else
    detail.status_id = op.status_id
    detail.user_book_id = tonumber(op.user_book_id) or detail.user_book_id
  end
  return detail
end

--
-- Whether the book on screen can be rated.
--   "ok"           yes
--   "no_book"      nothing is on screen to rate
--   "needs_shelf"  the book is not in the library yet: put it on a shelf first
--   "unsent"       it is on a shelf, but the change has not reached Hardcover, so
--                  there is no library record to rate yet
--
function BookActions.ratingGate(detail, has_queue)
  if not (detail and detail.book) then return "no_book" end
  if detail.status_id ~= nil and not detail.user_book_id and has_queue then return "unsent" end
  if not (detail.user_book_id and has_queue) then return "needs_shelf" end
  return "ok"
end

--
-- Whether a status write the reader did not ask for may go ahead, and how it is asked for.
--   `status_id`  the book's effective status (a queued change counts), or nil if unknown
--   `event`      how the change came about:
--                "end_auto"    the book reached its end and the plugin marks it on its own
--                              (KOReader's auto-mark or its "mark as read" end action)
--                "end_chosen"  the reader chose "Mark as finished" in KOReader's own dialog
--                "reading"     the book's status was set to reading
--   "allow"  write it
--   "block"  leave Hardcover as it is
--   "ask"    ask the reader first
--
-- Finished is never written over. Did not finish is the reader's decision: an automatic end
-- asks, and a choice the reader made in KOReader is applied.
--
function BookActions.statusWrite(status_id, event)
  if status_id == HARDCOVER.STATUS.FINISHED then return "block" end
  if status_id == HARDCOVER.STATUS.DNF then
    if event == "end_auto" then return "ask" end
    if event == "end_chosen" then return "allow" end
    return "block"
  end
  return "allow"
end

--
-- What a page turn does to Hardcover, given the book's effective status.
--   `status_id`  the status (a queued change counts), or nil if not known
--   "allow"  Currently Reading: send the page
--   "ask"    Want to Read, on no shelf, or not known: send nothing yet. After a few pages the reader
--            is asked whether to start the book (see StartReading); a status is never guessed
--   "block"  Finished, Did not finish, or any other status: send nothing, and never ask
--
function BookActions.pageWrite(status_id)
  if status_id == HARDCOVER.STATUS.READING then return "allow" end
  if status_id == nil or status_id == HARDCOVER.STATUS.TO_READ then return "ask" end
  return "block"
end

--
-- Whether the reader panel offers the "Update Hardcover as I read" switch. It is offered for a book
-- being read, and also while it is off (so a book whose tracking was turned off can always be turned
-- back on); for any other book reading asks first, and a switch there would promise what does not happen.
--
function BookActions.offerTrackSwitch(status_id, sync_on)
  return status_id == HARDCOVER.STATUS.READING or not sync_on
end

return BookActions
