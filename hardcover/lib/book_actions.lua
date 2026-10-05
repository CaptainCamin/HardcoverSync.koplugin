-- The decisions behind the actions on a book's details screen, apart from drawing
-- anything: what a change of shelf asks for, which saved shelves it makes wrong, how a
-- rating waiting to be sent shows, and whether rating is possible at all. The screen
-- flows (ui/book_detail_flows.lua) act on the answers.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite.

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

--
-- Whether the book on screen can be rated.
--   "ok"           yes
--   "no_book"      nothing is on screen to rate
--   "needs_shelf"  the book is not in the library yet: put it on a shelf first
--
function BookActions.ratingGate(detail, has_queue)
  if not (detail and detail.book) then return "no_book" end
  if not (detail.user_book_id and has_queue) then return "needs_shelf" end
  return "ok"
end

return BookActions
