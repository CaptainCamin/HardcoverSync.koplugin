-- How a book's status reaches Hardcover, for the progress queue (SyncQueue), whether the change was made
-- from the reader or from the book's details. The rules, kept here once:
--
--   * Hardcover logs each step of reading a book, so a book that went through Currently
--     Reading on its way to another status is still sent as started (passThroughReading);
--   * a finish is dated with the day it was made, not the day the connection came back
--     (setStatus puts `finished_date` on the latest read).
--
-- `user_book` is the library record when the caller has it (the change is then made on that
-- record) or nil (the change is made by book, which adds the book to the library if need be).
-- `info`: { book_id, edition_id, privacy_setting_id } (used when there is no record) and `at`, when
-- the change was made (os.time), which Hardcover dates the journal entries it writes with.
--
-- Plain data over the injected `api`, no KOReader requires.

local HARDCOVER = require("hardcover/lib/constants/hardcover")

local StatusSender = {}

local function hasUserBook(user_book)
  return type(user_book) == "table" and user_book.id ~= nil
end

-- Put the book on shelf `status_id`. Returns the library record, or nil and the reason.
function StatusSender.upsert(api, user_book, status_id, info)
  if hasUserBook(user_book) then
    return api:updateUserBookStatus(user_book.id, status_id, nil, info.at)
  end
  return api:updateUserBook(info.book_id, status_id, info.privacy_setting_id, info.edition_id, info.at)
end

-- The step through Currently Reading a change owes. Nothing to do for a record already there.
-- Returns the record to carry on with, or nil and the reason.
function StatusSender.passThroughReading(api, user_book, info)
  if hasUserBook(user_book) and user_book.status_id == HARDCOVER.STATUS.READING then
    return user_book
  end
  return StatusSender.upsert(api, user_book, HARDCOVER.STATUS.READING, info)
end

-- Put the book on `status_id`, then, when `finished_date` is given, that day on the read it
-- finishes (a refusal of the date leaves the finish as sent). Returns the record, or nil and
-- the reason.
function StatusSender.setStatus(api, user_book, status_id, finished_date, info)
  local result, err = StatusSender.upsert(api, user_book, status_id, info)
  if result and finished_date then result = api:setFinishedDate(result, finished_date) or result end
  return result, err
end

return StatusSender
