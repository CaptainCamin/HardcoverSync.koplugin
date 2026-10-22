-- Live contract check: the plugin's real HardcoverApi against the real Hardcover API.
--
-- The harnesses in spec/ use a fake API, so they cannot notice Hardcover changing its schema.
-- This runs the plugin's own queries and mutations against a throwaway account and fails when
-- Hardcover refuses one (a GraphQL error, a non-2xx answer) or an answer lacks what the plugin
-- reads. It is not in run_all.sh: it needs the network and a token. CI runs it nightly and on
-- demand (.github/workflows/live.yml).
--
-- Run with:  HARDCOVER_DEV_KEY=<token> luajit spec/live/hardcover_live.lua [plugin-root]
--
-- The token is read from the environment only, handed to curl the same way, and never printed.
-- Everything the run adds to the account is removed again, even when a step fails; a leftover
-- from an earlier crashed run is removed first.
--
-- HARDCOVER_LIVE_GOALS=1 also creates and archives a reading goal. Archiving is the only way the
-- plugin can remove one, so each run leaves an archived goal behind; off by default.

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

if (os.getenv("HARDCOVER_DEV_KEY") or "") == "" then
  io.stderr:write("HARDCOVER_DEV_KEY is not set\n")
  os.exit(2)
end

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

-- KOReader's json has json.util (null, InitArray) and writes an empty table as an object; the
-- specs' stand-in has neither, so wrap it: the decoder is theirs, the encoder is this one.
local spec_json = require("json")
local NULL, ARRAY = setmetatable({}, { __tostring = function() return "null" end }), {}
local function encode(v)
  local t = type(v)
  if v == nil or v == NULL then return "null" end
  if t ~= "table" then return spec_json.encode(v) end
  local out = {}
  if getmetatable(v) == ARRAY or #v > 0 then
    for i, item in ipairs(v) do out[i] = encode(item) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  for k, item in pairs(v) do out[#out + 1] = spec_json.encode(tostring(k)) .. ":" .. encode(item) end
  return "{" .. table.concat(out, ",") .. "}"
end
package.loaded["json"] = setmetatable({
  encode = encode,
  util = { null = NULL, InitArray = function(t) return setmetatable(t, ARRAY) end },
}, { __index = spec_json })
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
package.preload["hardcover_version"] = function() return { "0", "0", "0", "live" } end

local json = require("json")
local Api = require("hardcover/lib/hardcover_api")
Api.auth = nil
Api.enabled = true

-- Requests run inline, and go out through curl. The request body and the Authorization header
-- are read by curl from stdin / the environment, so the token is never on a command line.
Api.runtime = { subprocess = function(fn) return true, fn() end }

local Shape = dofile(PLUGIN .. "/spec/live/shape.lua")
local is_null = function(v) return v == NULL end

-- The shape of the first answer each method gives, kept to compare with the emulator's fixtures
-- at the end (see "emulator fixtures match" below). Only types are kept, never values.
local live_shapes = {}
for _, name in ipairs({
  "me", "search", "findBooks", "findEditions", "getBookDetail", "getBooksByIds", "getReviews",
  "getSimilarBooks", "getBookLists", "getLists", "getListCount", "getListBooks", "getListMembers",
  "getShelf", "getShelfCounts", "getCurrentlyReading", "getStats", "getForYou", "getVibes",
  "getGoals", "updateUserBook", "updateRating", "updatePage", "createRead", "createJournalEntry",
  "addToList",
}) do
  local original = Api[name]
  if original then
    Api[name] = function(self, ...)
      local result, a, b = original(self, ...)
      if result ~= nil then live_shapes[name] = Shape.merge(live_shapes[name], Shape.of(result, is_null)) end
      return result, a, b
    end
  end
end

local failures_http = {}
local activity_only = os.getenv("HARDCOVER_LIVE_ACTIVITY_ONLY") == "1"
local request_label = "me"
local API_URL = "https://api.hardcover.app/v1/graphql"
Api.transport = {
  post = function(url, headers, body)
    assert(url == API_URL, "unexpected endpoint " .. tostring(url))
    local agent = (headers["User-Agent"] or "hardcoversync-live-check"):gsub("[^%w%.%-%s%(%)/:]", "")
    agent = tostring(agent)
    local cmd = "curl -sS --max-time 30 -w '\\n%{http_code}'"
      .. " -H 'Content-Type: application/json'"
      .. " -H 'User-Agent: " .. agent .. "'"
      .. " -H \"Authorization: Bearer $(printf %s \"$HARDCOVER_DEV_KEY\" | sed 's/^[[:space:]]*[Bb]earer[[:space:]]*//' | tr -d '[:space:]\"')\""
      .. " --data-binary @- '" .. url .. "'"
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, "w"))
    f:write(json.encode(body))
    f:close()
    local content, code
    -- Hardcover allows 60 requests a minute: keep under it, and wait out a 429 if one comes anyway
    for attempt = 1, 4 do
      os.execute("sleep 1.1")
      local p = assert(io.popen(cmd .. " < " .. tmp, "r"))
      local out = p:read("*a")
      p:close()
      content, code = out:match("^(.*)\n(%d+)$")
      if code ~= "429" then break end
      os.execute("sleep " .. (attempt * 8))
    end
    os.remove(tmp)
    if not code then return "0:" end
    if not code:match("^2") then
      failures_http[#failures_http + 1] = code
    end
    if activity_only then
      print("    " .. request_label .. ": HTTP " .. code)
      local ok, response = pcall(json.decode, content or "")
      if ok and type(response) == "table" then
        -- Only error details, never the token or returned account/feed content.
        if type(response.error) == "string" then print("    error: " .. response.error) end
        if type(response.error_description) == "string" then
          print("    description: " .. response.error_description)
        end
      elseif not code:match("^2") then
        print("    non-JSON error response (body omitted)")
      end
    end
    return code .. ":" .. content
  end,
}

-- every GraphQL error counts, even in a call whose wrapper would swallow it
local graphql_errors = {}
Api.on_error = function(e)
  graphql_errors[#graphql_errors + 1] = type(e) == "table" and (e.message or json.encode(e)) or tostring(e)
end

local r = support.reporter()
local cleanup = {}

local function step(label, fn)
  local before = #graphql_errors
  local ok, err = pcall(fn)
  if #graphql_errors > before then
    local seen = "GraphQL error: " .. graphql_errors[before + 1]
    ok, err = false, ok and seen or (tostring(err) .. " (" .. seen .. ")")
  end
  r.check(label, ok, err)
  return ok
end

local function need(value, what)
  if value == nil then error("no " .. what .. " in the answer", 0) end
  return value
end

local function is_table(value, what)
  if type(value) ~= "table" then error(what .. " is not a table (" .. type(value) .. ")", 0) end
  return value
end

local ctx = {}
local today = os.date("!%Y-%m-%d")

step("me: id and username", function()
  local me = is_table(Api:me(), "me")
  ctx.user_id = need(tonumber(me.id), "id")
  need(me.username, "username")
  if me.account_privacy_setting_id == nil then error("no account_privacy_setting_id", 0) end
end)

if not ctx.user_id then
  -- say what shape the token has, never what it is
  local key = os.getenv("HARDCOVER_DEV_KEY")
  print(string.format("  token shape: %d characters, %d dots, %s a Bearer prefix, %s surrounding whitespace or quotes",
    #key, select(2, key:gsub("%.", "")), key:match("^%s*[Bb]earer") and "has" or "no",
    (key:match("^[%s\"']") or key:match("[%s\"']$")) and "has" or "no"))
  print("cannot continue without a user (is the token valid?)")
  r.finish()
end

-- A targeted diagnostic for the Activity screen. Return before any mutation or
-- exploratory probe below; this mode only reads the account and feed.
if activity_only then
  local Feed = require("hardcover/lib/feed")
  local followed
  request_label = "followed readers"
  step("getFollowedIds", function()
    followed = is_table(Api:getFollowedIds(), "followed ids")
    print("    followed readers: " .. #followed)
  end)
  for _, mode in ipairs({ "full", "status", "note", "quote", "review" }) do
    request_label = mode .. " activity"
    step(request_label, function()
      local page = is_table(Api:getFeed({
        me_id = ctx.user_id, user_ids = followed or {}, limit = Feed.PAGE_SIZE,
        kinds = mode ~= "full" and { mode } or nil,
      }), "activity page")
      print(string.format("    entries=%d, more=%s, page size=%d",
        #page.entries, tostring(page.more), Feed.PAGE_SIZE))
    end)
  end
  step("no HTTP refusals", function()
    if #failures_http > 0 then error(table.concat(failures_http, ","), 0) end
  end)
  r.finish()
  return
end

-- Catalogue: reads only
step("search: a well-known title finds books", function()
  local books = is_table(Api:search("Dune", "Frank Herbert", ctx.user_id), "search result")
  if #books == 0 then error("no results for Dune", 0) end
  local book = books[1]
  ctx.book_id = need(tonumber(book.book_id), "book_id")
  need(book.title, "title")
end)

step("findEditions: a book has editions", function()
  local editions = is_table(Api:findEditions(need(ctx.book_id, "book id from search"), ctx.user_id), "editions")
  if #editions == 0 then error("no editions", 0) end
  ctx.edition_id = need(tonumber(editions[1].edition_id or editions[1].id), "edition id")
end)

step("getBookDetail", function()
  local detail = Api:getBookDetail(need(ctx.book_id, "book id"), ctx.user_id, ctx.edition_id)
  is_table(detail, "book detail")
end)

step("findBooksByIdentifiers: edition, ISBN and slug in one batch", function()
  local detail = is_table(Api:getBookDetail(need(ctx.book_id, "book id"), ctx.user_id, ctx.edition_id), "book detail")
  local isbn = detail.book.isbn_13 or detail.book.isbn_10
  local list = {
    { edition_id = need(ctx.edition_id, "edition id") },
    { isbn_13 = "9780000000009" },       -- a wrong check digit: no edition has it
    { book_slug = "dune" },
  }
  if isbn then list[#list + 1] = detail.book.isbn_13 and { isbn_13 = isbn } or { isbn_10 = isbn } end
  local answers = is_table(Api:findBooksByIdentifiers(list, ctx.user_id), "answers")
  if #answers ~= #list then error("expected " .. #list .. " answers, got " .. #answers, 0) end
  if not (answers[1] and tonumber(answers[1].edition_id) == ctx.edition_id) then
    error("the edition was not found by its id", 0)
  end
  if answers[2] ~= false then
    error("an unknown ISBN was matched: " .. tostring(type(answers[2]) == "table" and answers[2].title), 0)
  end
  if isbn and not (answers[4] and answers[4].book_id) then error("the edition's own ISBN was not found", 0) end
end)

step("findBooksByTitles: an exact title and an unknown one in one batch", function()
  local detail = is_table(Api:getBookDetail(need(ctx.book_id, "book id"), ctx.user_id, ctx.edition_id), "book detail")
  local title = need(detail.book.title, "title")
  local found = is_table(Api:findBooksByTitles({ title, "No Such Book Title 9780000000009" }, ctx.user_id), "titles")
  local books = is_table(found[title], "books with that title")
  local ours
  for _, book in ipairs(books) do if tonumber(book.book_id) == ctx.book_id then ours = book end end
  if not ours then error("the book was not among the books with its own title", 0) end
  if found["No Such Book Title 9780000000009"] ~= nil then error("an unknown title was matched", 0) end
  is_table(ours.contributions, "contributions (the author, for the match)")
end)

step("getBookDetails: a book and an edition in one batch", function()
  local answers = is_table(Api:getBookDetails({
    { book_id = need(ctx.book_id, "book id") },
    { book_id = ctx.book_id, edition_id = need(ctx.edition_id, "edition id") },
  }, ctx.user_id), "answers")
  if #answers ~= 2 then error("expected 2 answers, got " .. #answers, 0) end
  for _, answer in ipairs(answers) do
    is_table(answer.detail, "detail")
    need(answer.detail.book.title, "title")
    if answer.detail.book.editions_count == nil then error("no editions_count in the answer", 0) end
  end
end)

step("findDefaultEdition", function()
  is_table(Api:findDefaultEdition(need(ctx.book_id, "book id"), ctx.user_id), "default edition")
end)

step("getBooksByIds", function()
  is_table(Api:getBooksByIds({ need(ctx.book_id, "book id") }), "books")
end)

step("getReviews", function()
  is_table(Api:getReviews(need(ctx.book_id, "book id"), 5, 0), "reviews")
end)

step("getSimilarBooks", function()
  is_table(Api:getSimilarBooks(need(ctx.book_id, "book id"), 5, ctx.user_id), "similar books")
end)

-- The library: a book added, read, rated, journalled, and removed again
step("clear a leftover from an earlier run", function()
  local leftover = Api:findUserBook(need(ctx.book_id, "book id"), ctx.user_id)
  if type(leftover) == "table" and leftover.id then
    is_table(Api:removeUserBook(leftover.id), "removal of the leftover")
  end
end)

local added = false
step("updateUserBook: add a book as currently reading", function()
  local ub = is_table(Api:updateUserBook(need(ctx.book_id, "book id"), 2, nil, ctx.edition_id), "user book")
  ctx.user_book_id = need(tonumber(ub.id), "user book id")
  added = true
  if ub.status_id ~= 2 then error("status_id is " .. tostring(ub.status_id), 0) end
end)
if added then
  cleanup[#cleanup + 1] = function() return Api:removeUserBook(ctx.user_book_id) end
end

step("findUserBook: the added book is found", function()
  local ub = is_table(Api:findUserBook(ctx.book_id, ctx.user_id), "user book")
  if ub.id ~= ctx.user_book_id then error("a different user book came back", 0) end
end)

step("createRead and updatePage", function()
  -- Hardcover starts a read itself when a book becomes "currently reading"; the plugin only
  -- creates one when there is none, so do the same (see how book_actions finds it)
  local ub = is_table(Api:findUserBook(ctx.book_id, ctx.user_id), "user book")
  local reads = is_table(ub.user_book_reads, "reads")
  if #reads == 0 then
    local read = is_table(Api:createRead(ctx.user_book_id, ctx.edition_id, 10, today), "created read")
    reads = is_table(read.user_book_reads, "created read's reads")
  end
  ctx.read_id = need(tonumber(reads[#reads].id), "read id")
  local updated = is_table(Api:updatePage(ctx.read_id, ctx.edition_id, 25, today), "updated read")
  -- updatePage answers with the user book (see normalizeUserBookRead), the read inside it
  local pages = is_table(updated.user_book_reads, "reads of the updated book")[1]
  if tonumber(pages and pages.progress_pages) ~= 25 then
    error("progress_pages is " .. tostring(pages and pages.progress_pages), 0)
  end
end)

step("setFinishedDate: a book finished earlier keeps that day, and the read keeps its page and start", function()
  local finished = is_table(Api:updateUserBook(need(ctx.book_id, "book id"), 3, nil, ctx.edition_id), "finished user book")
  -- (Hardcover itself moves a finished read to the last page, and dates it today)
  local before = is_table(finished.user_book_reads, "reads of the finished book")
  before = need(before[#before], "read")
  local dated = is_table(Api:setFinishedDate(finished, "2026-01-02"), "user book with a finish date")
  local read = is_table(dated.user_book_reads, "reads")[1]
  if not read or read.finished_at ~= "2026-01-02" then
    error("finished_at is " .. tostring(read and read.finished_at), 0)
  end
  if tonumber(read.progress_pages) ~= tonumber(before.progress_pages) then
    error("progress_pages went from " .. tostring(before.progress_pages) .. " to " .. tostring(read.progress_pages), 0)
  end
  if read.started_at ~= before.started_at then
    error("started_at went from " .. tostring(before.started_at) .. " to " .. tostring(read.started_at), 0)
  end
  local again = is_table(Api:findUserBook(ctx.book_id, ctx.user_id), "user book read back")
  local last = again.user_book_reads[#again.user_book_reads]
  if last.finished_at ~= "2026-01-02" then error("not kept: finished_at is " .. tostring(last.finished_at), 0) end
end)

step("updateRating, then clear it", function()
  local rated = is_table(Api:updateRating(need(ctx.user_book_id, "user book"), 4), "rated user book")
  if tonumber(rated.rating) ~= 4 then error("rating is " .. tostring(rated.rating), 0) end
  is_table(Api:updateRating(ctx.user_book_id, 0), "cleared user book")
end)

-- Journal writes. The create path is inherited from the original plugin; these steps are what
-- proves it works against the real API: each entry is read back, not just acknowledged. Entries
-- are private (privacy_setting_id 3). They are deleted again when Hardcover has a delete for
-- them (see the probe below); otherwise a private entry is left behind.
local JOURNAL_FIELDS = "id event entry privacy_setting_id book_id edition_id metadata"

local function readJournal(id)
  -- the id goes into the text: its column type (Int or bigint) is not known, a literal fits either
  local query = [[
    query {
      reading_journals(where: { id: { _eq: ]] .. math.floor(id) .. [[ } }) { ]] .. JOURNAL_FIELDS .. [[ }
    }
  ]]
  -- a read straight after the write can miss it (seen once in three runs): look again
  for attempt = 1, 4 do
    local rows = Api:query(query)
    local row = rows and rows.reading_journals and rows.reading_journals[1]
    if row then return row, attempt end
    os.execute("sleep 2")
  end
end

local function createJournal(event, text, extra)
  local object = {
    book_id = need(ctx.book_id, "book id"),
    event = event,
    entry = text,
    edition_id = ctx.edition_id,
    privacy_setting_id = 3,
    tags = json.util.InitArray({}),
  }
  for k, v in pairs(extra or {}) do object[k] = v end
  local entry = is_table(Api:createJournalEntry(object), "journal entry")
  ctx.journal_ids = ctx.journal_ids or {}
  ctx.journal_ids[#ctx.journal_ids + 1] = need(tonumber(entry.id), "journal entry id")
  return tonumber(entry.id)
end

step("createJournalEntry: a note, read back", function()
  local id = createJournal("note", "hardcoversync live check: note")
  local row, attempt = readJournal(id)
  is_table(row, "the note read back")
  if attempt > 1 then print("    (the note showed up on read " .. attempt .. ")") end
  if row.event ~= "note" then error("event is " .. tostring(row.event), 0) end
  if row.entry ~= "hardcoversync live check: note" then error("entry is " .. tostring(row.entry), 0) end
  if tonumber(row.privacy_setting_id) ~= 3 then error("privacy is " .. tostring(row.privacy_setting_id), 0) end
  if tonumber(row.book_id) ~= ctx.book_id then error("book_id is " .. tostring(row.book_id), 0) end
end)

step("createJournalEntry: a quote with a page and tags, read back", function()
  local id = createJournal("quote", "hardcoversync live check: quote", {
    metadata = { position = { type = "pages", value = 12, possible = 400 } },
    tags = {
      { category = "Tag", tag = "live check", spoiler = false },
      { category = "Tag", tag = "live check hidden", spoiler = true },
    },
  })
  local row = is_table(readJournal(id), "the quote read back")
  if row.event ~= "quote" then error("event is " .. tostring(row.event), 0) end
  local position = is_table(is_table(row.metadata, "metadata").position, "metadata.position")
  if tonumber(position.value) ~= 12 or tonumber(position.possible) ~= 400 then
    error("position is " .. json.encode(position), 0)
  end
end)

-- The activity feed, as the plugin asks for it (HardcoverApi:getFeed): your own private note comes
-- back in a note-only feed, and the full feed of you and the readers you follow pages cleanly.
step("getFeed: your note, then the full feed and its next page", function()
  local id = createJournal("note", "hardcoversync live check: feed note")
  local found
  for _ = 1, 4 do
    local page = is_table(Api:getFeed({ me_id = ctx.user_id, mine = true, kinds = { "note" }, limit = 10 }), "the feed")
    for _, e in ipairs(page.entries) do
      if e.kind == "note" and e.text == "hardcoversync live check: feed note" then found = e end
    end
    if found then break end
    os.execute("sleep 2")
  end
  if not found then error("the new note (journal " .. id .. ") is not in the feed", 0) end
  if found.title == "A book" then error("the entry has no book title", 0) end

  local followed = is_table(Api:getFollowedIds(), "followed ids")
  local first = is_table(Api:getFeed({ me_id = ctx.user_id, user_ids = followed, limit = 5 }), "the full feed")
  print(string.format("    full feed: %d entries, %d readers followed, more=%s", #first.entries, #followed, tostring(first.more)))
  for i = 2, #first.entries do
    if first.entries[i - 1].at < first.entries[i].at then error("the feed is not newest first", 0) end
  end
  if first.cursor then
    local second = is_table(Api:getFeed({ me_id = ctx.user_id, user_ids = followed, limit = 5, before = first.cursor }), "the next page")
    local Feed = require("hardcover/lib/feed")
    local all, added = Feed.append(first.entries, second.entries)
    print(string.format("    next page: %d entries, %d new", #second.entries, added))
    if #all < #first.entries then error("paging lost entries", 0) end
  end
end)

-- Exploratory, never fails the run: what Hardcover calls the things the plugin does not use yet
-- (journal reads and deletes, the review fields, an activity feed). Each answer is printed so the
-- run's log is the record, and docs/hardcover-journal-api.md is written from it. A refused
-- query is expected here, so the error hook is switched off while a probe runs.
local function probe(label, query, variables)
  local saved = Api.on_error
  Api.on_error = function() end
  local ok, result, err = pcall(function() return Api:query(query, variables) end)
  Api.on_error = saved
  if not ok then
    print("  probe " .. label .. ": raised " .. tostring(result))
  elseif result == nil then
    print("  probe " .. label .. ": refused " .. (type(err) == "table" and json.encode(err) or tostring(err)))
  else
    print("  probe " .. label .. ": " .. json.encode(result))
  end
  return ok and result or nil
end

local function typeFields(name)
  return probe("type " .. name, [[
    query ($name: String!) {
      __type(name: $name) {
        name kind
        fields { name type { kind name ofType { kind name ofType { kind name } } } }
        inputFields { name type { kind name ofType { kind name ofType { kind name } } } }
      }
    }
  ]], { name = name })
end

step("probe: the schema around journals, reviews and activity (prints only)", function()
  local roots = probe("roots", [[
    { __schema {
        queryType { fields { name } }
        mutationType { fields { name args { name type { kind name ofType { kind name ofType { kind name } } } } } }
    } }
  ]])
  local names = {}
  if roots then
    for _, f in ipairs(roots.__schema.queryType.fields) do names[#names + 1] = f.name end
    print("  query roots: " .. table.concat(names, " "))
    for _, f in ipairs(roots.__schema.mutationType.fields) do
      if f.name:find("journal") or f.name:find("user_book") or f.name:find("activit") or f.name:find("review") then
        print("  mutation " .. f.name .. ": " .. json.encode(f.args))
      end
    end
  end
  for _, name in ipairs({
    "UserBookUpdateInput", "UserBookCreateInput", "activities_bool_exp", "BasicTag",
  }) do
    typeFields(name)
  end
end)

step("probe: reading the journal for this book (prints only)", function()
  probe("reading_journals mine", [[
    query ($bookId: Int!, $userId: Int!) {
      reading_journals(
        where: { book_id: { _eq: $bookId }, user_id: { _eq: $userId } }
        order_by: { id: desc }
        limit: 5
      ) { ]] .. JOURNAL_FIELDS .. [[ created_at action_at }
    }
  ]], { bookId = ctx.book_id, userId = ctx.user_id })
  probe("me.reading_journals", [[
    { me { reading_journals(limit: 5, order_by: { id: desc }) { ]] .. JOURNAL_FIELDS .. [[ } } }
  ]])
end)

step("probe: activity feed shapes (prints only)", function()
  -- the shape of each kind of activity: its event, object type and the keys of its data
  local function summarize(label, where, vars, decl)
    local saved = Api.on_error
    Api.on_error = function() end
    local result, err = Api:query("query (" .. decl .. ") { activities(where: " .. where
      .. ", order_by: { id: desc }, limit: 40) { id event object_type user_id book_id created_at data } }", vars)
    Api.on_error = saved
    if not result then
      print("  probe " .. label .. ": refused " .. (type(err) == "table" and json.encode(err) or tostring(err)))
      return
    end
    local seen = {}
    for _, a in ipairs(result.activities) do
      local keys = {}
      for k in pairs(type(a.data) == "table" and a.data or {}) do keys[#keys + 1] = k end
      table.sort(keys)
      local inner = {}
      local ub = type(a.data) == "table" and a.data.userBook
      for k in pairs(type(ub) == "table" and ub or {}) do inner[#inner + 1] = k end
      table.sort(inner)
      local shape = a.event .. " data={" .. table.concat(keys, ",") .. "}"
        .. (#inner > 0 and (" userBook={" .. table.concat(inner, ",") .. "}") or "")
      seen[shape] = (seen[shape] or 0) + 1
    end
    for shape, n in pairs(seen) do print("  probe " .. label .. ": " .. n .. "x " .. shape) end
  end
  summarize("activities mine", "{ user_id: { _eq: $userId } }", { userId = ctx.user_id }, "$userId: Int!")
  local followed = probe("me.followed_users", [[{ me { followed_users { followed_user_id } } }]])
  local ids = {}
  for _, f in ipairs(followed and followed.me and followed.me[1] and followed.me[1].followed_users or {}) do
    ids[#ids + 1] = tonumber(f.followed_user_id)
  end
  if #ids > 0 then
    summarize("activities followed", "{ user_id: { _in: $ids } }", { ids = ids }, "$ids: [Int!]")
  end
  -- quotes and notes are not activities: they are reading_journals, public ones of readers you follow
  if #ids > 0 then
    probe("followed readers' public quotes and notes", [[
      query ($ids: [Int!]) {
        reading_journals(
          where: { user_id: { _in: $ids }, privacy_setting_id: { _eq: 1 }, event: { _in: ["quote", "note"] } }
          order_by: { id: desc }
          limit: 2
        ) { id event entry privacy_setting_id book_id action_at metadata user { username name } book { title slug } }
      }
    ]], { ids = ids })
    probe("followed readers' reviews", [[
      query ($ids: [Int!]) {
        user_books(
          where: { user_id: { _in: $ids }, has_review: { _eq: true } }
          order_by: { reviewed_at: desc_nulls_last }
          limit: 2
        ) { id rating review_raw review_has_spoilers reviewed_at user { username name } book { title slug } }
      }
    ]], { ids = ids })
  end
  
end)

step("probe: a review written and cleared on the user book (prints only)", function()
  local ub = need(ctx.user_book_id, "user book")
  local function review(label, object)
    probe(label, [[
      mutation ($id: Int!, $object: UserBookUpdateInput!) {
        update_user_book(id: $id, object: $object) {
          error user_book { id review_raw review_has_spoilers has_review reviewed_at }
        }
      }
    ]], { id = ub, object = object })
  end
  review("set review_markdown", { review_markdown = "hardcoversync live check", review_has_spoilers = true })
  review("clear with empty review_markdown", { review_markdown = "", review_has_spoilers = false })
  review("set review_slate", { review_slate = { document = { object = "document", children = {
    { object = "block", type = "paragraph", data = {}, children = {
      { object = "text", text = "hardcoversync live check", marks = {} } } } } } } })
  review("clear with null review_slate", { review_slate = json.util.null })
  review("change with review_markdown", { review_markdown = "hardcoversync live check, second text" })
  review("change with review_slate", { review_slate = { document = { object = "document", children = {
    { object = "block", type = "paragraph", data = {}, children = {
      { object = "text", text = "third text from slate", marks = {} } } } } } } })
  review("clear with a blank review_markdown", { review_markdown = " " })
  review("clear with an empty slate paragraph", { review_slate = { document = { object = "document", children = {
    { object = "block", type = "paragraph", data = {}, children = { { object = "text", text = "", marks = {} } } } } } } })
  review("clear with an empty slate document", { review_slate = { document = { object = "document", children = {} } } })
  probe("reviewed_at after the clear attempts", [[
    query ($id: Int!) { user_books(where: { id: { _eq: $id } }) { id has_review review_raw reviewed_at } }
  ]], { id = ub })
end)

-- Writing a review, as the plugin does it (HardcoverApi:updateReview): read back, changed, cleared.
step("updateReview: two paragraphs, read back, changed and cleared", function()
  local ub = need(ctx.user_book_id, "user book")
  local function readReview()
    -- a read just after a write can show the old row: look again for up to eight seconds
    return function(want)
      local row
      for _ = 1, 4 do
        local rows = Api:query([[query ($id: Int!) { user_books(where: { id: { _eq: $id } }) {
          id has_review review_raw review_has_spoilers } }]], { id = ub })
        row = rows and rows.user_books and rows.user_books[1]
        if row and want(row) then return row end
        os.execute("sleep 2")
      end
      return row
    end
  end
  local await = readReview()

  local set = is_table(Api:updateReview(ub, "hardcoversync live check\nsecond paragraph", true), "the review as written")
  local row = is_table(await(function(r) return r.has_review == true end), "the review read back")
  if not tostring(row.review_raw):find("hardcoversync live check", 1, true)
      or not tostring(row.review_raw):find("second paragraph", 1, true) then
    error("review_raw is " .. tostring(row.review_raw), 0)
  end
  if row.review_has_spoilers ~= true then error("spoilers is " .. tostring(row.review_has_spoilers), 0) end
  need(set.id, "user book id in the answer")

  is_table(Api:updateReview(ub, "changed", false), "the review changed")
  row = is_table(await(function(r) return r.review_raw == "changed" end), "the changed review read back")
  if row.review_raw ~= "changed" then error("review_raw is " .. tostring(row.review_raw), 0) end
  if row.review_has_spoilers ~= false then error("spoilers is " .. tostring(row.review_has_spoilers), 0) end

  is_table(Api:updateReview(ub, "", false), "the review cleared")
  row = is_table(await(function(r) return r.has_review == false end), "the cleared review read back")
  if row.has_review ~= false then error("the review is still there: " .. tostring(row.review_raw), 0) end
end)

step("probe: deleting and updating a journal entry (prints only)", function()
  local id = createJournal("note", "hardcoversync live check: to delete")
  probe("update_reading_journal", [[
    mutation {
      update_reading_journal(id: ]] .. math.floor(id) .. [[, object: { entry: "changed" }) { id }
    }
  ]])
  local deleted = probe("delete_reading_journal", [[
    mutation { delete_reading_journal(id: ]] .. math.floor(id) .. [[) { id } }
  ]])
  ctx.can_delete_journal = deleted ~= nil
end)

-- leave nothing behind when Hardcover lets us delete
cleanup[#cleanup + 1] = function()
  if not ctx.can_delete_journal then
    print("  (journal entries left on the account, private: " .. #(ctx.journal_ids or {}) .. ")")
    return true
  end
  for _, id in ipairs(ctx.journal_ids or {}) do
    probe("clean up journal " .. id, [[mutation { delete_reading_journal(id: ]] .. math.floor(id) .. [[) { id } }]])
  end
  return true
end

step("getBookLists and getLists", function()
  is_table(Api:getBookLists(need(ctx.book_id, "book id")), "book lists")
  local lists = is_table(Api:getLists(), "lists")
  ctx.list = is_table(lists.mine, "your lists")[1]
end)

step("addToList and removeFromList (needs a list on the account)", function()
  if not ctx.list then
    print("    (skipped: the account has no list; make one named anything to cover this)")
    return
  end
  local entry = is_table(Api:addToList(ctx.book_id, ctx.list.id), "list entry")
  local list_book_id = need(entry.id, "list_book id")
  cleanup[#cleanup + 1] = function() return Api:removeFromList(list_book_id) end
  is_table(Api:removeFromList(list_book_id), "list removal")
  cleanup[#cleanup] = nil
end)

step("getListCount and getListBooks", function()
  Api:getListCount()
  if ctx.list then
    is_table(Api:getListBooks(ctx.list.id, "mine", false, 0, 5), "list books")
  end
end)

-- Shelves and what is built on them. Hardcover's shelf reads can trail a write by a moment.
local function eventually(what, fn)
  local last
  for _ = 1, 4 do
    local ok, err = pcall(fn)
    if ok then return end
    last = err
    os.execute("sleep 4")
  end
  error(tostring(last) .. " (" .. what .. ", still, after 16 s)", 0)
end

step("getShelf", function()
  eventually("shelf", function()
    local entries = is_table(Api:getShelf(ctx.user_id, 2, 0, 10), "shelf")
    if #entries == 0 then
      local all = Api:getShelf(ctx.user_id, nil, 0, 10)
      local ub = Api:findUserBook(ctx.book_id, ctx.user_id)
      error(string.format("the book just added is not on the Currently reading shelf (whole library: %s books; the book's status_id is %s)",
        all and #all or "?", tostring(type(ub) == "table" and ub.status_id)), 0)
    end
  end)
end)

step("getShelfCounts", function()
  eventually("count", function()
    local counts = is_table(Api:getShelfCounts(ctx.user_id, { 1, 2, 3, 4, 5 }), "counts")
    if (counts[2] or 0) < 1 then error("Currently reading count is " .. tostring(counts[2]), 0) end
  end)
end)

step("getShelfMembers and getCurrentlyReading", function()
  is_table(Api:getShelfMembers(ctx.user_id, 2, 0, 10), "shelf members")
  is_table(Api:getCurrentlyReading(ctx.user_id, 5), "currently reading")
end)

step("getStats", function()
  is_table(Api:getStats(ctx.user_id), "stats")
end)

step("getForYou and getVibes", function()
  Api:getForYou(5)
  Api:getVibes(ctx.user_id)
end)

step("getGoals", function()
  is_table(Api:getGoals(), "goals")
end)

if os.getenv("HARDCOVER_LIVE_GOALS") == "1" then
  step("saveGoal then archiveGoal", function()
    local year = os.date("!%Y")
    local goal = is_table(Api:saveGoal(nil, {
      description = "hardcoversync live check",
      metric = "book",
      goal = 1,
      start_date = year .. "-01-01",
      end_date = year .. "-12-31",
      privacy_setting_id = 3,
    }), "saved goal")
    local id = need(goal.id, "goal id")
    cleanup[#cleanup + 1] = function() return Api:archiveGoal({ id = id }) end
    -- archive with what the plugin would hold of it
    local ok, err = Api:archiveGoal({
      id = id, name = "hardcoversync live check", target = 1, metric = "book",
      start_date = year .. "-01-01", end_date = year .. "-12-31",
    })
    if not ok then error("archive failed: " .. tostring(type(err) == "table" and json.encode(err) or err), 0) end
    cleanup[#cleanup] = nil
  end)
end

-- Clean up, last, whatever happened above
for i = #cleanup, 1, -1 do
  step("clean up (" .. i .. ")", function()
    local result, err = cleanup[i]()
    if result == nil then error("could not clean up: " .. tostring(type(err) == "table" and json.encode(err) or err), 0) end
  end)
end
step("the added book is gone", function()
  if added then
    -- a read just after a delete can still see the row (seen once in five runs): look again
    local left
    for _ = 1, 4 do
      left = Api:findUserBook(ctx.book_id, ctx.user_id)
      if not (type(left) == "table" and left.id) then return end
      os.execute("sleep 3")
    end
    error("user book " .. tostring(left.id) .. " is still on the account", 0)
  end
end)

-- The emulator's canned data has to look like what Hardcover really sends. Types only, never
-- values. A field both sides have with different types fails. A field the live answer has and the
-- fixture lacks fails only when the plugin's own code mentions that field name: the answers carry
-- plenty the plugin never reads (image colours, author slugs), and the fixtures need not.
local plugin_source
local function plugin_reads(field)
  if not plugin_source then
    local parts = {}
    local p = assert(io.popen("find '" .. PLUGIN .. "/hardcover' '" .. PLUGIN .. "/main.lua' -name '*.lua'"))
    for file in p:lines() do
      local f = io.open(file, "r")
      if f then parts[#parts + 1] = f:read("*a"); f:close() end
    end
    p:close()
    plugin_source = table.concat(parts, "\n")
  end
  return plugin_source:find("%f[%w_]" .. field:gsub("%p", "%%%0") .. "%f[^%w_]") ~= nil
end

local fixture_shapes, fixture_failed
step("emulator fixtures can answer the same calls", function()
  fixture_shapes, fixture_failed = dofile(PLUGIN .. "/spec/live/fixture_shapes.lua")(Api, PLUGIN, is_null)
  local names = {}
  for name, err in pairs(fixture_failed) do names[#names + 1] = name .. " (" .. err:gsub("\n.*", "") .. ")" end
  table.sort(names)
  if #names > 0 then error("fixture fakes raised: " .. table.concat(names, "; "), 0) end
end)
local compared = {}
for name in pairs(live_shapes) do compared[#compared + 1] = name end
table.sort(compared)
for _, name in ipairs(compared) do
  if fixture_shapes and fixture_shapes[name] then
    step("emulator fixture matches the live shape: " .. name, function()
      local mismatches, extras, missing = Shape.compare(live_shapes[name], fixture_shapes[name])
      if #extras > 0 then print("    note: fixture-only fields " .. table.concat(extras, ", ")) end
      local read = {}
      for _, path in ipairs(missing) do
        if plugin_reads(path:match("([^.%[%]]+)$") or path) then read[#read + 1] = path end
      end
      if #read > 0 then print("    note: live fields the plugin reads and the fixture lacks " .. table.concat(read, ", ")) end
      if #mismatches > 0 then error(table.concat(mismatches, "; "), 0) end
    end)
  end
end
local shapes_out = os.getenv("HARDCOVER_LIVE_SHAPES")
if shapes_out and shapes_out ~= "" then
  local f = io.open(shapes_out, "w")
  if f then
    f:write(encode({ live = live_shapes, fixtures = fixture_shapes or {} }), "\n")
    f:close()
  end
end

step("no request was refused at HTTP level", function()
  if #failures_http > 0 then error("non-2xx answers: " .. table.concat(failures_http, ","), 0) end
end)

r.finish()
