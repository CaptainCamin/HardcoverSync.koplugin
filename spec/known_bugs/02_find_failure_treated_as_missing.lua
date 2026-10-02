-- BUG: a failed lookup is treated as "this book is not on the shelf".
--
-- HardcoverApi:findUserBook returns `{}, err` on ANY failure (5xx, 429, a null
-- user id, a rejected token), the same shape the queue sees for "no such
-- book". SyncQueue:_flushEntry (hardcover/lib/sync_queue.lua, `if not
-- hasUserBook(user_book)`) then calls updateUserBook(book_id, pending_status or
-- READING) -- insert_user_book -- for a book that IS on the shelf. A Finished
-- book is pushed back to Currently Reading by a queued page, which the
-- "do not quietly reopen it" guard further down exists to prevent.
--
-- It also happens whenever User:getId() returns nil (Api:me() failed), because
-- the flush then sends userId = null for every entry.
--
-- Expected: when the lookup itself failed, keep the entry and send nothing.
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

print("\n== a failed lookup must not look like a missing book ==")

KB.check("a 5xx on the lookup does not create/overwrite the user book", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 7, edition_id = 3 })
  local api = KB.fakeApi({ [7] = { id = 500, book_id = 7, status_id = HARDCOVER.STATUS.FINISHED,
    user_book_reads = { { id = 900, progress_pages = 300 } } } })
  -- what HardcoverApi:findUserBook really returns when the request fails
  api.find_hook = function() return {}, { status = 503 } end
  q:flush(api, { user_id = 1 })
  KB.eq(api:count("updateUserBook"), 0, "insert_user_book calls after a failed lookup")
  KB.eq(api.shelf[7].status_id, HARDCOVER.STATUS.FINISHED, "status of the Finished book")
  KB.eq(q:hasPending("/books/a.epub"), true, "entry kept for a retry")
end)

KB.check("an unknown user id (User:getId() == nil) sends nothing", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 7, edition_id = 3 })
  local api = KB.fakeApi()
  api.find_hook = function(_, user_id)
    if user_id == nil then return {}, { status = 200, errors = { { message = "variable userId is null" } } } end
  end
  q:flush(api, { user_id = nil })
  KB.eq(api:count("findUserBook"), 0, "lookups with a nil user id")
  KB.eq(api:count("updateUserBook"), 0, "writes with a nil user id")
end)

KB.finish("failed findUserBook must not be treated as 'book not on shelf'")
