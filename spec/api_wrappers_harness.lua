-- The "...Async" wrappers on the API: which exist, that each hands its arguments to the
-- blocking call it is named for (holes and all) and the callback the answer, and that a
-- call that raises still reaches the callback. They are generated from one list, so this
-- is the contract that list must keep.
--
-- Unlike api_async_harness this does not need LuaJIT: Trapper:wrap here just runs the
-- function, since what is checked is the wiring, not that the UI is not blocked.
--
-- Run with:  lua spec/api_wrappers_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

local ticks = {}
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) fn() end }
end
package.preload["ui/uimanager"] = function()
  return {
    show = function() end, setDirty = function() end, scheduleIn = function() end,
    unschedule = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
end
package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["ffi"] = function() return {} end
package.preload["ffi/pointer"] = function() return {} end
package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
package.preload["blitbuffer"] = function() return {} end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end

local Api = require("hardcover/lib/hardcover_api")
Api.auth = nil

local r = support.reporter()
local check = r.test

local function deliver_ticks()
  while #ticks > 0 do table.remove(ticks, 1)() end
end

-- the wrappers the screens rely on, with how many arguments the blocking call takes
local WRAPPERS = {
  saveGoal = 2, archiveGoal = 1, getGoals = 0, getLists = 0, getBookLists = 1, addToList = 3,
  removeFromList = 1, getListCount = 0, getShelf = 4, getShelfCounts = 2, getStats = 1, getBooksByIds = 1,
  getVibes = 1, getForYou = 0, me = 0, getSimilarBooks = 3, getBookDetail = 3, getReviews = 3, getJournal = 1,
  updateUserBook = 4, removeUserBook = 1, findBooks = 3, findEditions = 2,
  findDefaultEdition = 2, findBookByIdentifiers = 2,
}

print("\n== which wrappers exist ==")

for name in pairs(WRAPPERS) do
  check(name .. "Async exists and " .. name .. " is a real method", function()
    assert(type(Api[name .. "Async"]) == "function", "no " .. name .. "Async")
    assert(type(Api[name]) == "function", "no " .. name .. " to wrap")
  end)
end

check("no wrapper exists that is not in the contract", function()
  for key, value in pairs(Api) do
    local base = type(key) == "string" and key:match("^(.+)Async$")
    if base and type(value) == "function" then
      assert(WRAPPERS[base] ~= nil, key .. " is not in the list of wrappers this checks")
    end
  end
end)

print("\n== what they pass on ==")

for name, arity in pairs(WRAPPERS) do
  check(name .. "Async passes its arguments, then delivers the answer", function()
    local original = Api[name]
    local seen
    Api[name] = function(self, ...)
      seen = { self = self, n = select("#", ...), ... }
      return "answer", "extra"
    end
    local args = {}
    for i = 1, arity do args[i] = "arg" .. i end
    local got
    args[#args + 1] = function(...) got = { n = select("#", ...), ... } end
    Api[name .. "Async"](Api, unpack(args))
    Api[name] = original
    deliver_ticks()
    assert(seen and seen.self == Api, "the blocking call did not get the API as self")
    assert(seen.n == arity, "arguments passed: " .. tostring(seen.n) .. ", expected " .. arity)
    for i = 1, arity do assert(seen[i] == "arg" .. i, "argument " .. i .. " changed") end
    assert(got and got.n == 2 and got[1] == "answer" and got[2] == "extra", "answer not delivered intact")
  end)
end

check("a nil in the middle of the arguments stays where it is", function()
  local original = Api.getBookDetail
  local seen
  Api.getBookDetail = function(_, book_id, user_id, edition_id) seen = { book_id, user_id, edition_id } end
  Api:getBookDetailAsync(7, nil, 3, function() end)
  Api.getBookDetail = original
  assert(seen[1] == 7 and seen[2] == nil and seen[3] == 3)
end)

check("a trailing nil argument is passed as nil, not dropped into the callback's place", function()
  local original = Api.getShelf
  local seen_n
  Api.getShelf = function(_, ...) seen_n = select("#", ...) end
  local called = false
  Api:getShelfAsync(1, 3, 0, nil, function() called = true end)
  Api.getShelf = original
  deliver_ticks()
  assert(seen_n == 4, "arguments: " .. tostring(seen_n))
  assert(called)
end)

check("the callback is not run inline, only on the next tick", function()
  local original = Api.getGoals
  Api.getGoals = function() return "goals" end
  local got
  Api:getGoalsAsync(function(g) got = g end)
  Api.getGoals = original
  assert(got == nil, "ran before the next tick")
  deliver_ticks()
  assert(got == "goals")
end)

check("the method is looked up when called, so a replaced one is the one that runs", function()
  local original = Api.getLists
  Api.getLists = function() return "first" end
  local got
  Api:getListsAsync(function(v) got = v end)
  deliver_ticks()
  assert(got == "first")
  Api.getLists = function() return "second" end
  Api:getListsAsync(function(v) got = v end)
  deliver_ticks()
  Api.getLists = original
  assert(got == "second")
end)

check("a call that raises still reaches the callback, with no results", function()
  local original = Api.getForYou
  Api.getForYou = function() error("boom") end
  local called, first = false, "unset"
  Api:getForYouAsync(function(v) called = true; first = v end)
  Api.getForYou = original
  deliver_ticks()
  assert(called and first == nil)
end)

check("findUserBook selects updated_at for abandon approval freshness", function()
  local original = Api.query
  local seen
  Api.query = function(_, query)
    seen = query
    return { user_books = { { id = 70, book_id = 7, status_id = 2,
      updated_at = "2026-11-18T10:00:00+00:00" } } }
  end
  local found = Api:findUserBook(7, 1)
  Api.query = original
  assert(seen and seen:find("updated_at", 1, true), "the lookup omitted updated_at")
  assert(found and found.updated_at == "2026-11-18T10:00:00+00:00")
end)

check("findUserBook selects each read's edition, the way the book details lookup does", function()
  local original = Api.query
  local seen
  Api.query = function(_, query)
    seen = query
    return { user_books = { { id = 70, book_id = 7, status_id = 2,
      user_book_reads = { { id = 10, started_at = "2019-03-01", edition_id = 3,
        edition = { id = 3, pages = 304, edition_format = "Paperback", reading_format_id = 1 } } } } } }
  end
  local found = Api:findUserBook(7, 1)
  Api.query = original
  local reads = seen and seen:match("user_book_reads%(order_by: %{id: asc%}%) {(.-)\n  }")
  assert(reads and reads:find("edition {", 1, true), "the read's own edition was not asked for")
  for _, field in ipairs({ "pages", "edition_format", "reading_format_id", "audio_seconds" }) do
    assert(reads:find(field, 1, true), "the read's edition omitted " .. field)
  end
  assert(found and found.user_book_reads[1].edition.pages == 304)
end)

check("findUserBooks asks once for every book and answers each, false when not on the shelf", function()
  local original = Api.query
  local seen_query, seen, asked = nil, nil, 0
  Api.query = function(_, query, vars)
    asked = asked + 1
    seen_query, seen = query, vars
    return { user_books = { { id = 70, book_id = 7, status_id = 2 }, { id = 90, book_id = 9, status_id = 3 } } }
  end
  local found = Api:findUserBooks({ 7, 8, 9 }, 1)
  assert(asked == 1, "one request")
  assert(seen.userId == 1 and #seen.ids == 3, "the user and every id are sent")
  assert(seen_query:find("_in", 1, true) and seen_query:find("UserBookParts", 1, true))
  assert(found["7"].id == 70 and found["9"].id == 90, "records keyed by book id")
  assert(found["8"] == false, "a book not on the shelf is false, not missing")
  Api.query = function() return nil, { status = 503 } end
  local none, err = Api:findUserBooks({ 7, 8 }, 1)
  assert(none == nil and err.status == 503, "a failure is told apart from an empty shelf")
  Api.query = function() return nil end
  none, err = Api:findUserBooks({ 7 }, 1)
  Api.query = original
  assert(none == nil and err, "offline still answers an error")
end)

check("createJournalEntry says why it failed, and answers the entry when it worked", function()
  local original = Api.query
  Api.query = function() return nil, { status = 503 } end
  local entry, err = Api:createJournalEntry({ book_id = 1, event = "note", privacy_setting_id = 3, tags = {} })
  assert(entry == nil and err and err.status == 503, "the queue needs the reason to tell a busy server from a refusal")
  Api.query = function() return { insert_reading_journal = { reading_journal = { id = 9 } } } end
  entry = Api:createJournalEntry({ book_id = 1, event = "note", privacy_setting_id = 3, tags = {} })
  assert(entry and entry.id == 9)
  Api.query = function() return { insert_reading_journal = {} } end
  entry = Api:createJournalEntry({ book_id = 1, event = "note", privacy_setting_id = 3, tags = {} })
  Api.query = original
  assert(entry == nil, "an answer without an entry is not a saved entry")
end)

check("updateJournalEntry sends only the new text for the entry, and says why it failed", function()
  local original = Api.query
  local seen_query, seen
  Api.query = function(_, query, vars)
    seen_query, seen = query, vars
    return { update_reading_journal = { id = 41 } }
  end
  local done = Api:updateJournalEntry("41", "better")
  assert(done and done.id == 41)
  assert(seen.id == 41 and seen.object.entry == "better", "the id goes as a number, the text as entry")
  local fields = 0
  for _ in pairs(seen.object) do fields = fields + 1 end
  assert(fields == 1, "privacy, tags and page must not be sent: they would be overwritten")
  assert(seen_query:find("update_reading_journal", 1, true))
  Api.query = function() return nil, { status = 503 } end
  local entry, err = Api:updateJournalEntry(41, "better")
  Api.query = original
  assert(entry == nil and err.status == 503)
end)

check("deleteJournalEntry deletes by id, and says why it failed", function()
  local original = Api.query
  local seen_query, seen
  Api.query = function(_, query, vars)
    seen_query, seen = query, vars
    return { delete_reading_journal = { id = 41 } }
  end
  assert(Api:deleteJournalEntry(41))
  assert(seen.id == 41 and seen_query:find("delete_reading_journal", 1, true))
  Api.query = function() return { delete_reading_journal = {} } end
  assert(Api:deleteJournalEntry(41), "an answer is the entry gone, whatever it says of the id")
  Api.query = function() return nil, { errors = { { message = "not yours" } } } end
  local entry, err = Api:deleteJournalEntry(41)
  Api.query = original
  assert(entry == nil and err.errors)
end)

check("updateReview sends the text as a Slate document with the spoiler flag, and says why it failed", function()
  local original = Api.query
  local seen
  Api.query = function(_, _, vars)
    seen = vars
    return { update_user_book = { user_book = { id = 5, review_raw = "hello", has_review = true } } }
  end
  local ub = Api:updateReview(5, "hello\nthere", true)
  assert(ub and ub.review_raw == "hello")
  assert(seen.id == 5 and seen.object.review_has_spoilers == true)
  local children = seen.object.review_slate.document.children
  assert(#children == 2 and children[2].children[1].text == "there")
  Api:updateReview(5, "", false)
  assert(seen.object.review_has_spoilers == false and #seen.object.review_slate.document.children == 1)
  Api.query = function() return { update_user_book = { error = "not allowed" } } end
  local none, err = Api:updateReview(5, "x", false)
  assert(none == nil and err == "not allowed", "a refusal is the reason as a string")
  Api.query = function() return nil, { status = 503 } end
  none, err = Api:updateReview(5, "x", false)
  Api.query = original
  assert(none == nil and err.status == 503)
end)

check("rating uses the library record's current server status, including on a clear", function()
  local original = Api.query
  local json = require("json")
  local original_util = json.util
  json.util = { null = {} }
  local status, writes = 2, {}
  Api.query = function(_, query, vars)
    if query:find("user_books(where", 1, true) then
      assert(vars.id == 91)
      return { user_books = { { id = 91, status_id = status } } }
    end
    assert(query:find("status_id: $statusId", 1, true))
    writes[#writes + 1] = vars
    return { update_user_book = { user_book = { id = 91, status_id = vars.statusId } } }
  end
  assert(Api:updateRating(91, 4).status_id == 2)
  status = 1
  assert(Api:updateRating(91, 0).status_id == 1)
  assert(writes[1].rating == 4 and writes[1].statusId == 2 and writes[2].statusId == 1)
  Api.query = function() return nil, { status = 503 } end
  local result, err = Api:updateRating(91, 3)
  Api.query = original
  json.util = original_util
  assert(result == nil and err.status == 503, "failed lookup must not send a rating")
end)

check("a page is sent with the time it was read only when there is one", function()
  local original = Api.query
  local seen
  Api.query = function(_, query, variables) seen = { query = query, variables = variables } return {} end
  Api:updatePage(7, 3, 40, "2026-10-01")
  assert(not seen.query:find("action_at", 1, true) and not seen.query:find("actionAt", 1, true),
    "no time: the field is left out, since a missing variable would clear it")
  Api:updatePage(7, 3, 40, "2026-10-01", "2026-10-23T18:04:11Z")
  assert(seen.query:find("$actionAt: timestamptz", 1, true) and seen.query:find("action_at: $actionAt", 1, true))
  assert(seen.variables.actionAt == "2026-10-23T18:04:11Z")
  Api:createRead(9, 3, 12, "2026-10-01")
  assert(not seen.query:find("actionAt", 1, true), "a new read without a time has no time")
  Api:createRead(9, 3, 12, "2026-10-01", "2026-10-23T18:04:11Z")
  assert(seen.query:find("$actionAt: timestamptz", 1, true) and seen.query:find("action_at: $actionAt", 1, true))
  assert(seen.variables.actionAt == "2026-10-23T18:04:11Z")
  Api.query = original
end)

check("a failed page update distinguishes a transient outage from a refusal", function()
  local original = Api.query
  Api.query = function() return nil, { status = 503 } end
  local result, err = Api:updatePage(7, 3, nil, "2026-10-01", "2026-10-01T12:00:00Z")
  Api.query = function() return { update_user_book_read = { error = "Read not found" } } end
  local refused, refusal = Api:updatePage(7, 3, 40)
  Api.query = original
  assert(result == nil and err and err.status == 503, "outages must remain retryable")
  assert(refused == nil and refusal == "Read not found", "a refusal keeps its reason")
end)

check("a date correction targets one read without sending stale progress or edition fields", function()
  local original = Api.query
  local seen
  Api.query = function(_, query, vars)
    seen = { query = query, vars = vars }
    return { update_user_book_read = { user_book_read = { id = 7, started_at = "2026-10-01",
      progress_pages = 89, edition_id = 3, user_book = { id = 91, status_id = 2 } } } }
  end
  local result = Api:updateReadDates(7, { started_at = "2026-10-01" })
  Api.query = function() return nil, { status = 503 } end
  local failed, err = Api:updateReadDates(7, { finished_at = "2026-10-25" })
  Api.query = original
  assert(seen.query:find("object: $fields", 1, true) and seen.vars.id == 7)
  local fields = 0
  for field in pairs(seen.vars.fields) do
    fields = fields + 1
    assert(field == "started_at", "a date correction resent " .. field)
  end
  assert(fields == 1 and result.user_book_reads[1].progress_pages == 89, "newer progress must be preserved")
  assert(failed == nil and err.status == 503, "a date failure must remain retryable")
end)

check("updateRead sends exactly the fields it was given, a clear included", function()
  local original = Api.query
  local json = require("json")
  local original_util = json.util
  local null = {}
  json.util = { null = null }
  local seen
  Api.query = function(_, query, vars)
    seen = { query = query, vars = vars }
    return { update_user_book_read = { user_book_read = { id = 7, started_at = "2026-10-01",
      finished_at = nil, finished_at_precision = 2, edition_id = 3, progress_pages = 89,
      user_book = { id = 91, status_id = 2 } } } }
  end
  local result = Api:updateRead(7, { finished_at = null, finished_at_precision = 2 })
  Api.query = original
  json.util = original_util
  assert(seen.query:find("object: $fields", 1, true) and seen.vars.id == 7)
  assert(seen.vars.fields.finished_at == null and seen.vars.fields.finished_at_precision == 2)
  local fields = 0
  for _ in pairs(seen.vars.fields) do fields = fields + 1 end
  assert(fields == 2, "a broad payload would reset progress set on another device")
  assert(result.user_book_reads[1].progress_pages == 89, "the read's progress must come back")
end)

check("addRead inserts one read on the library record, and says why it failed", function()
  local original = Api.query
  local seen
  Api.query = function(_, query, vars)
    seen = { query = query, vars = vars }
    return { insert_user_book_read = { id = 77, user_book_read = { id = 77,
      started_at = "2019-03-01", finished_at = "2019-03-31", finished_at_precision = 2,
      edition_id = 3, progress_pages = 300, user_book = { id = 91, status_id = 3 } } } }
  end
  local result = Api:addRead(91, { started_at = "2019-03-01", finished_at = "2019-03-31",
    finished_at_precision = 2 })
  Api.query = function() return { insert_user_book_read = { error = "not allowed" } } end
  local refused, reason = Api:addRead(91, { started_at = "2019-03-01" })
  Api.query = original
  assert(seen.query:find("insert_user_book_read", 1, true) and seen.vars.id == 91)
  assert(seen.vars.read.finished_at_precision == 2 and seen.vars.read.started_at == "2019-03-01")
  local fields = 0
  for _ in pairs(seen.vars.read) do fields = fields + 1 end
  assert(fields == 3, "only the fields the form set")
  assert(result and result.user_book_reads[1].id == 77, "the new read comes back with its id")
  assert(refused == nil and reason == "not allowed")
end)

check("deleteRead removes one read, never the whole library record", function()
  local original = Api.query
  local original_remove = Api.removeRead
  local removed = 0
  Api.removeRead = function() removed = removed + 1 end
  local seen_query, seen
  Api.query = function(_, query, vars)
    seen_query, seen = query, vars
    return { delete_user_book_read = { id = 77 } }
  end
  local deleted = Api:deleteRead(77)
  assert(deleted and deleted.id == 77)
  assert(seen_query:find("delete_user_book_read", 1, true) and seen.id == 77)
  assert(not seen_query:find("delete_user_book(", 1, true), "the whole library record must not be deleted")
  Api.query = function() return { delete_user_book_read = { error = "not yours" } } end
  local refused, reason = Api:deleteRead(77)
  Api.query = function() return nil, { status = 503 } end
  local failed, err = Api:deleteRead(77)
  Api.query = original
  Api.removeRead = original_remove
  assert(removed == 0, "removeRead deletes the library record and must never be used for a read")
  assert(refused == nil and reason == "not yours")
  assert(failed == nil and err.status == 503, "an outage must remain retryable")
end)

check("findEditions can include audiobooks, with their length", function()
  local original = Api.query
  local seen
  Api.query = function(_, query)
    seen = query
    return { editions = { { id = 3, book = { book_id = 7, title = "Dune" }, pages = 300,
      edition_format = "Audiobook", reading_format_id = 2, audio_seconds = 31288 } } }
  end
  local editions = Api:findEditions(7, 1, true)
  Api.query = original
  assert(seen:find("_neq: 2", 1, true) == nil, "the audiobook filter was kept")
  assert(editions[1].audio_seconds == 31288 and editions[1].reading_format_id == 2)
  assert(editions[1].edition_format == "Audiobook")
end)

check("getBookDetail brings the book's reads in Hardcover's order, and nil off the shelf", function()
  local original = Api.query
  local seen_query
  Api.query = function(_, query)
    seen_query = query
    return { books = { { book_id = 7, title = "Dune", user_books = { { id = 91, status_id = 2,
      rating = 4, review_raw = "My review", review_has_spoilers = true, reviewed_at = "2026-03-01T09:12:00Z",
      user_book_reads = {
        { id = 10, started_at = "2019-03-01", finished_at = "2019-03-31", finished_at_precision = 2,
          progress_pages = 300, edition_id = 3,
          edition = { id = 3, pages = 304, edition_format = "Paperback", reading_format_id = 1 } },
        { id = 11, started_at = "2026-11-03", progress_pages = 40, edition_id = 3,
          edition = { id = 3, pages = 304, edition_format = "Paperback", reading_format_id = 1 } },
      } } } } } }
  end
  local detail = Api:getBookDetail(7, 1)
  assert(seen_query:find("user_book_reads(order_by: {id: asc})", 1, true))
  assert(seen_query:find("finished_at_precision", 1, true) and seen_query:find("audio_seconds", 1, true),
    "the query must ask for precision and the edition's own fields")
  assert(seen_query:find("reviewed_at", 1, true), "the query must ask when the review was posted")
  assert(detail.reads and #detail.reads == 2, "reads missing from the detail")
  assert(detail.reads[1].id == 10 and detail.reads[2].id == 11, "Hardcover's order was changed")
  assert(detail.reads[1].finished_at_precision == 2)
  assert(detail.reads[1].edition.pages == 304 and detail.reads[1].edition.edition_format == "Paperback")
  assert(detail.user_review == "My review" and detail.review_spoilers == true)
  assert(detail.review_posted_at == "2026-03-01T09:12:00Z" and detail.review_id == 91)
  assert(detail.rating_known == true and detail.review_known == true)

  Api.query = function() return { books = { { book_id = 8, title = "Not shelved" } } } end
  local unshelved = Api:getBookDetail(8, 1)
  Api.query = original
  assert(unshelved.reads == nil, "a book not on a shelf has no history, not an empty one")
end)

r.finish()
