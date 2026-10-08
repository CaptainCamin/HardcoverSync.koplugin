-- The decisions behind a book's details screen: what a shelf change asks for, which saved
-- shelves it makes wrong, the pending-rating overlay and gate, the lists tick-box state
-- machine, and the similar-books retry policy. Plain data, no KOReader.
--
-- Run with:  lua spec/book_actions_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local BookActions = require("hardcover/lib/book_actions")
local Lists = require("hardcover/lib/lists")
local Recommendations = require("hardcover/lib/recommendations")

print("\n== moving a book to a shelf ==")

check("a book new to the library is sent with its edition", function()
  local req = BookActions.shelfRequest({ book = { book_id = 7, edition_id = 70 } }, 1)
  assert(req.book_id == 7 and req.status_id == 1 and req.edition_id == 70)
end)

check("a book already on a shelf is sent without one, so the edition it is read in stays", function()
  local req = BookActions.shelfRequest({ user_book_id = 5, status_id = 2, book = { book_id = 7, edition_id = 70 } }, 3)
  assert(req.edition_id == nil and req.status_id == 3)
end)

check("a library record with no status still counts as in the library", function()
  assert(BookActions.shelfRequest({ user_book_id = 5, book = { book_id = 7, edition_id = 70 } }, 1).edition_id == nil)
  assert(BookActions.shelfRequest({ status_id = 2, book = { book_id = 7, edition_id = 70 } }, 1).edition_id == nil)
end)

check("a book with no edition on record sends none", function()
  assert(BookActions.shelfRequest({ book = { book_id = 7 } }, 1).edition_id == nil)
end)

print("\n== which saved shelves go stale ==")

check("the shelf it left and the one it joined", function()
  local ids = BookActions.staleShelves(1, 2)
  assert(#ids == 2 and ids[1] == 1 and ids[2] == 2)
end)

check("a book new to the library only makes the shelf it joined stale", function()
  local ids = BookActions.staleShelves(nil, 2)
  assert(#ids == 1 and ids[1] == 2)
end)

check("a book removed only makes the shelf it left stale", function()
  local ids = BookActions.staleShelves(3, nil)
  assert(#ids == 1 and ids[1] == 3)
end)

check("nothing known, nothing stale", function()
  assert(#BookActions.staleShelves(nil, nil) == 0)
end)

print("\n== rating ==")

check("a rating waiting to be sent shows over the one on record", function()
  local d = BookActions.withPendingRating({ user_rating = 3 }, 4.5)
  assert(d.user_rating == 4.5)
end)

check("a waiting clear (0) removes the rating from view", function()
  local d = BookActions.withPendingRating({ user_rating = 3 }, 0)
  assert(d.user_rating == nil)
end)

check("with nothing waiting the detail is left as it is", function()
  local d = { user_rating = 3 }
  assert(BookActions.withPendingRating(d, nil) == d and d.user_rating == 3)
end)

check("no detail is fine", function()
  assert(BookActions.withPendingRating(nil, 4) == nil)
end)

check("a book in the library with a queue can be rated", function()
  assert(BookActions.ratingGate({ book = {}, user_book_id = 9 }, true) == "ok")
end)

check("nothing on screen cannot be rated", function()
  assert(BookActions.ratingGate(nil, true) == "no_book")
  assert(BookActions.ratingGate({}, true) == "no_book")
end)

check("a book not in the library has to be put on a shelf first", function()
  assert(BookActions.ratingGate({ book = {} }, true) == "needs_shelf")
end)

check("without a rating queue there is nowhere to keep the rating", function()
  assert(BookActions.ratingGate({ book = {}, user_book_id = 9 }, false) == "needs_shelf")
end)

print("\n== the lists tick boxes ==")

check("a list the book is not on is added to", function()
  assert(Lists.togglePlan({ on = false }) == "add")
  assert(Lists.togglePlan({}) == "add")
end)

check("a list the book is on, with its row id known, is removed from directly", function()
  assert(Lists.togglePlan({ on = true, list_book_id = 12 }) == "remove")
end)

check("a list the book was just added to, row id unknown, is looked up first", function()
  assert(Lists.togglePlan({ on = true }) == "lookup")
end)

check("a look-up that finds the row says which to remove", function()
  local outcome, id = Lists.resolveLookup({ { id = 1 }, { id = 2, on = true, list_book_id = 99 } }, 2)
  assert(outcome == "remove" and id == 99)
end)

check("a look-up that finds the book already off the list says so", function()
  assert(Lists.resolveLookup({ { id = 2, on = false } }, 2) == "already_off")
end)

check("a look-up that finds the list but no row id says so", function()
  assert(Lists.resolveLookup({ { id = 2, on = true } }, 2) == "no_row_id")
end)

check("a look-up without the list, or that failed, says not found", function()
  assert(Lists.resolveLookup({ { id = 1 } }, 2) == "not_found")
  assert(Lists.resolveLookup({}, 2) == "not_found")
  assert(Lists.resolveLookup(nil, 2) == "not_found")
end)

print("\n== asking for similar books again ==")

check("a request that really failed is tried twice more, then given up", function()
  local failed = { status = 500 }
  assert(Recommendations.retryPolicy(1, failed) == "retry")
  assert(Recommendations.retryPolicy(2, failed) == "retry")
  assert(Recommendations.retryPolicy(3, failed) == "give_up")
end)

check("a cancelled request (the reader touched the screen) is tried many more times", function()
  local cancelled = { completed = false }
  assert(Recommendations.retryPolicy(7, cancelled) == "retry")
  assert(Recommendations.retryPolicy(8, cancelled) == "give_up")
end)

check("an error that is not a table counts as a failure, not a cancel", function()
  assert(Recommendations.retryPolicy(3, "boom") == "give_up")
  assert(Recommendations.retryPolicy(1, nil) == "retry")
end)

r.finish()
