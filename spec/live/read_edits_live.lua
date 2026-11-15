-- Live contract probe for read edits: adding one read, changing one read's dates or edition, and
-- removing one read. These are the mutations Reading history will send, so the questions they
-- leave open (journal rows, shelf side effects, read-after-write lag) are answered here before any
-- queue code depends on them.
--
-- Read-only by default: it introspects the schema and prints the mutation signatures. A run with
-- `--write` creates private library records for books already in the catalogue, probes each case,
-- and removes those records again. Only use it on a throwaway account, with the account and books
-- agreed in the request thread first.
--
-- Run with either the token name the plugin's live check uses, or the repository dev account's:
--   HARDCOVER_DEV_KEY=<token> luajit spec/live/read_edits_live.lua [plugin-root]
--   HARDCOVER_API_KEY=<token> luajit spec/live/read_edits_live.lua [plugin-root] --write
--
-- The token is read from the environment only, handed to curl through the environment, and never
-- printed. Every answer that matters is printed as a line that can be pasted into
-- docs/hardcover-journal-api.md; nothing is written to the repository.
--
-- The probes and what each answers:
--   1. insert_user_book_read with finished_at_precision 1, 2 and 3: which journal rows appear,
--      and their action_at.
--   2. update_user_book_read changing only an older read's dates while a newer read is unfinished:
--      does the shelf move to Read, and does setting Currently Reading back start another read?
--   3. delete_user_book_read on a finished read, on the only read, and on the active read: the
--      response, the remaining reads, the journal rows removed, and the shelf.
--   4. update_user_book_read with edition_id and progress_pages together: is the page kept or
--      normalised?
--   5. read-after-write lag for the reads and for the shelf.

local PLUGIN = "."
local WRITE = false
for _, value in ipairs(arg) do
  if value == "--write" then
    WRITE = true
  elseif value:sub(1, 2) ~= "--" then
    PLUGIN = value
  end
end

package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local TOKEN_ENV = "HARDCOVER_DEV_KEY"
if (os.getenv("HARDCOVER_DEV_KEY") or "") == "" then
  if (os.getenv("HARDCOVER_API_KEY") or "") ~= "" then
    TOKEN_ENV = "HARDCOVER_API_KEY"
  else
    io.stderr:write("HARDCOVER_DEV_KEY or HARDCOVER_API_KEY is not set\n")
    os.exit(2)
  end
end

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

-- KOReader's json has json.util (null, InitArray) and writes an empty table as an object; the
-- specs' stand-in has neither, so wrap it as the other live checks do.
local spec_json = require("json")
local NULL, ARRAY = setmetatable({}, { __tostring = function() return "null" end }), {}
local function encode(value)
  local kind = type(value)
  if value == nil or value == NULL then return "null" end
  if kind ~= "table" then return spec_json.encode(value) end
  local out = {}
  if getmetatable(value) == ARRAY or #value > 0 then
    for i, item in ipairs(value) do out[i] = encode(item) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  for key, item in pairs(value) do
    out[#out + 1] = spec_json.encode(tostring(key)) .. ":" .. encode(item)
  end
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
Api.runtime = { subprocess = function(fn) return true, fn() end }

local API_URL = "https://api.hardcover.app/v1/graphql"
Api.transport = {
  post = function(url, headers, body)
    assert(url == API_URL, "unexpected endpoint " .. tostring(url))
    local agent = (headers["User-Agent"] or "hardcoversync-read-edits"):gsub("[^%w%.%-%s%(%)/:]", "")
    -- the curl command reads the token from the environment, never from its arguments; the
    -- repository dev account is named HARDCOVER_API_KEY, the plugin's live check HARDCOVER_DEV_KEY
    local prefix = TOKEN_ENV == "HARDCOVER_API_KEY"
      and 'HARDCOVER_DEV_KEY="$HARDCOVER_API_KEY"; export HARDCOVER_DEV_KEY; ' or ""
    local cmd = prefix .. "curl -sS --max-time 30 -w '\\n%{http_code}'"
      .. " -H 'Content-Type: application/json'"
      .. " -H 'User-Agent: " .. agent .. "'"
      .. " -H \"Authorization: Bearer $(printf %s \"$HARDCOVER_DEV_KEY\" | sed 's/^[[:space:]]*[Bb]earer[[:space:]]*//' | tr -d '[:space:]\"')\""
      .. " --data-binary @- '" .. url .. "'"
    local temp = os.tmpname()
    local file = assert(io.open(temp, "w"))
    file:write(json.encode(body))
    file:close()
    local content, code
    for attempt = 1, 4 do
      -- Hardcover allows 60 requests a minute; stay under it and wait out a 429
      os.execute("sleep 1.1")
      local pipe = assert(io.popen(cmd .. " < " .. temp, "r"))
      local out = pipe:read("*a")
      pipe:close()
      content, code = out:match("^(.*)\n(%d+)$")
      if code ~= "429" then break end
      os.execute("sleep " .. (attempt * 8))
    end
    os.remove(temp)
    if not code then return "0:" end
    return code .. ":" .. (content or "")
  end,
}

local graphql_errors = {}
Api.on_error = function(error)
  graphql_errors[#graphql_errors + 1] = type(error) == "table" and (error.message or json.encode(error))
    or tostring(error)
end

local r = support.reporter()
local check = r.test
local user_id
local cleanup = {}
local cleaned = 0
local touched = {}
local journal_books = {}
-- The journal row ids each probe book had before this run touched it. Cleanup must leave those
-- alone: a catalogue book can have old journal rows even when it is not in the library.
local journal_before = {}

local function step(label, fn)
  local before = #graphql_errors
  local ok, err = pcall(fn)
  if #graphql_errors > before then
    local seen = "GraphQL error: " .. graphql_errors[before + 1]
    ok, err = false, ok and seen or (tostring(err) .. " (" .. seen .. ")")
  end
  r.check(label, ok, err)
end

local function need(value, what)
  if value == nil then error("no " .. what .. " in the answer", 0) end
  return value
end

local function number(value, what)
  local n = tonumber(value)
  if not n then error((what or "value") .. " is not a number: " .. tostring(value), 0) end
  return n
end

local function pairText(name, value)
  print(string.format("    %s=%s", name, tostring(value)))
end

local function readText(read)
  return string.format("id=%s start=%s finish=%s precision=%s page=%s edition=%s",
    tostring(read.id), tostring(read.started_at), tostring(read.finished_at),
    tostring(read.finished_at_precision), tostring(read.progress_pages), tostring(read.edition_id))
end

local function library(book_id)
  local user_book = Api:findUserBook(book_id, user_id)
  if type(user_book) ~= "table" then return nil end
  return user_book
end

local function readsOf(book_id)
  local user_book = library(book_id)
  return user_book and user_book.user_book_reads or nil, user_book
end

local function journalRows(book_id)
  local data = Api:query([[
    query ($bookId: Int!, $userId: Int!) {
      reading_journals(where: { book_id: { _eq: $bookId }, user_id: { _eq: $userId } },
        order_by: { id: asc }) {
        id
        event
        action_at
        created_at
        metadata
      }
    }
  ]], { bookId = book_id, userId = user_id })
  return data and data.reading_journals or nil
end

local function journalText(rows)
  if not rows then return "none" end
  local kept = {}
  for _, row in ipairs(rows) do
    kept[#kept + 1] = string.format("%s(id=%s action_at=%s)", tostring(row.event), tostring(row.id),
      tostring(row.action_at))
  end
  return #kept > 0 and table.concat(kept, ", ") or "none"
end

-- Wait up to `seconds` for `test` to answer something; returns seconds taken and the answer.
local function waitFor(test, seconds)
  local started = os.time()
  for _ = 1, seconds do
    local answer = test()
    if answer then return os.time() - started, answer end
    os.execute("sleep 1")
  end
  return nil, nil
end

-- A private library record for a catalogue book, with a fresh edition. Nothing here creates a
-- catalogue book: "disposable" means the private record, removed at the end.
local function makeRecord(book, status)
  local editions = Api:findEditions(book.book_id, user_id)
  local edition = editions and editions[1]
  if not edition or not edition.edition_id then return nil end
  if journal_before[book.book_id] == nil then
    local existing = journalRows(book.book_id)
    if type(existing) == "table" then
      local ids = {}
      for _, row in ipairs(existing) do ids[tostring(row.id)] = true end
      journal_before[book.book_id] = ids
    end
  end
  -- findEditions answers normalized books: the edition's own id is `edition_id`, not `id`
  local user_book = Api:updateUserBook(book.book_id, status or 2, 3, edition.edition_id)
  if not (type(user_book) == "table" and user_book.id) then return nil end
  cleanup[#cleanup + 1] = { id = user_book.id, book_id = book.book_id, title = book.title }
  touched[#touched + 1] = { book_id = book.book_id, title = book.title }
  journal_books[book.book_id] = book.title
  return user_book, edition
end

local function pickBooks()
  local titles = { "The Yellow Wallpaper", "The Time Machine", "The Metamorphosis",
    "The Strange Case of Dr. Jekyll and Mr. Hyde", "Frankenstein", "Dracula" }
  local books = {}
  for _, title in ipairs(titles) do
    local found = Api:search(title, nil, user_id)
    for _, book in ipairs(found or {}) do
      if #books < 6 and not library(book.book_id) then
        local editions = Api:findEditions(book.book_id, user_id)
        if editions and editions[1] then books[#books + 1] = book end
      end
    end
  end
  return books
end

local function addRead(user_book, fields)
  local user_book_after, err = Api:addRead(user_book.id, fields)
  if not user_book_after then error("addRead said: " .. tostring(type(err) == "table"
    and json.encode(err) or err), 0) end
  return user_book_after.user_book_reads[1]
end

local function setReading(user_book)
  local updated = Api:updateUserBookStatus(user_book.id, 2, 3)
  if not (type(updated) == "table" and updated.id) then
    error("could not set Currently Reading", 0)
  end
  return updated
end

local function removeRecord(entry)
  if not entry then return false end
  local ok, result = pcall(Api.removeUserBook, Api, entry.id)
  if not ok or not result then
    print("    cleanup left user_book " .. tostring(entry.id) .. " (" .. tostring(entry.title) .. ")")
    return false
  end
  cleaned = cleaned + 1
  local left = library(entry.book_id)
  if type(left) == "table" and left.id then
    print("    cleanup warning: user_book " .. tostring(entry.id) .. " was removed but "
      .. tostring(entry.book_id) .. " still has record " .. tostring(left.id))
    return false
  end
  return true
end

-- Remove the records a probe made, so the next probe on the same book starts from nothing.
-- A record that could not be removed stays on the list for the final retry and the audit.
local function dropSince(count)
  for index = #cleanup, count + 1, -1 do
    if removeRecord(cleanup[index]) then table.remove(cleanup, index) end
  end
end

-- ------------------------------------------------------------------ read-only

local mutation_fields

step("me: the account this token belongs to", function()
  local me = need(Api:me(), "me")
  user_id = number(need(me.id, "id"), "me.id")
  print("    account id=" .. user_id .. " username=" .. tostring(me.username))
end)

if user_id then
  step("the read mutation signatures, when the schema can be introspected", function()
    local data = need(Api:query([[
      {
        __type(name: "Mutation") {
          fields {
            name
            args {
              name
              type {
                kind
                name
                ofType { kind name ofType { kind name } }
              }
            }
          }
        }
      }
    ]]), "introspection")
    local fields = data and data.__type
    if not (fields and fields.fields) then
      print("    introspection is not available to this token; the request shapes are recorded in")
      print("    docs/hardcover-journal-api.md")
      return
    end
    mutation_fields = {}
    for _, field in ipairs(fields.fields) do mutation_fields[field.name] = field end
    for _, name in ipairs({ "insert_user_book_read", "update_user_book_read", "delete_user_book_read" }) do
      local field = mutation_fields[name]
      if not field then error("no " .. name .. " in the schema", 0) end
      local args = {}
      for _, argument in ipairs(field.args or {}) do
        local t = argument.type or {}
        local label = t.name or (t.ofType and t.ofType.name) or t.kind
        args[#args + 1] = argument.name .. ":" .. tostring(label)
      end
      print("    " .. name .. "(" .. table.concat(args, ", ") .. ")")
    end
  end)

  step("the new read fields are readable on this account", function()
    local data = Api:query([[
      query ($userId: Int!) {
        user_books(where: { user_id: { _eq: $userId } }, order_by: { id: desc }, limit: 20) {
          id
          status_id
          book { title }
          user_book_reads(order_by: {id: asc}) {
            id
            started_at
            finished_at
            finished_at_precision
            progress_pages
            edition_id
            edition { id pages edition_format reading_format_id audio_seconds }
          }
        }
      }
    ]], { userId = user_id })
    if not data then error("the read query was refused", 0) end
    local records = data.user_books or {}
    local reads, sample = 0, nil
    for _, user_book in ipairs(records) do
      local count = #(user_book.user_book_reads or {})
      reads = reads + count
      print(string.format("    record %s: %s (status %s, %d reads)", tostring(user_book.id),
        tostring(user_book.book and user_book.book.title), tostring(user_book.status_id), count))
      for _, read in ipairs(user_book.user_book_reads or {}) do
        sample = sample or { user_book = user_book, read = read }
      end
    end
    print(string.format("    library records sampled: %d, reads seen: %d", #records, reads))
    if sample then
      print("    sample book: " .. tostring(sample.user_book.book and sample.user_book.book.title))
      print("    sample read: " .. readText(sample.read))
    end
  end)
end

if not user_id then
  print("cannot continue without an account (is the token valid?)")
  r.finish()
end

if not WRITE then
  print("")
  print("Read-only run: the schema check and the account's saved reads are the whole answer.")
  print("Live probes write to the account. To run them, have the account and books agreed first, then:")
  print("  HARDCOVER_DEV_KEY=<token> (or HARDCOVER_API_KEY=<token>) luajit spec/live/read_edits_live.lua "
    .. PLUGIN .. " --write")
  r.finish()
  return
end

-- ------------------------------------------------------------------ live probes

print("")
print("== live probes: private records, removed at the end ==")

-- Everything that writes runs inside one pcall, so the records a failed probe made are still
-- removed below instead of being left on the account.
local function runProbes()
local books = {}
local setup_ok = pcall(function()
  books = pickBooks()
  if #books < 4 then error("not enough catalogue books free of this account", 0) end
end)
if not setup_ok or #books < 4 then
  io.stderr:write("could not find four catalogue books not already in the library\n")
  r.finish()
end

-- 1. Insert with each precision.
print("\n-- insert_user_book_read, by finished_at_precision --")
for index, precision in ipairs({ 1, 2, 3 }) do
  local book = books[index]
  local marked = #cleanup
  local user_book, edition = makeRecord(book, 2)
  if user_book then
    local dates = precision == 1 and { started_at = "2019-03-14", finished_at = "2019-03-14" }
      or precision == 2 and { started_at = "2019-03-01", finished_at = "2019-03-01" }
      or { started_at = "2019-01-01", finished_at = "2019-01-01" }
    dates.finished_at_precision = precision
    dates.edition_id = edition.edition_id
    local before = journalRows(book.book_id)
    local reads_before = #((library(book.book_id) or {}).user_book_reads or {})
    local read
    local ok = pcall(function() read = addRead(user_book, dates) end)
    local after = journalRows(book.book_id)
    local reads_after = #((library(book.book_id) or {}).user_book_reads or {})
    if ok then
      print(string.format("  precision %d (%s)", precision, tostring(book.title)))
      pairText("request", "insert_user_book_read(user_book_id=" .. user_book.id .. ", "
        .. "started_at=" .. tostring(dates.started_at) .. ", finished_at=" .. tostring(dates.finished_at)
        .. ", finished_at_precision=" .. precision .. ", edition_id=" .. tostring(edition.edition_id) .. ")")
      pairText("read", readText(read))
      pairText("shelf", "status_id=" .. tostring((library(book.book_id) or {}).status_id)
        .. ", reads " .. reads_before .. " -> " .. reads_after)
      pairText("journal before", journalText(before))
      pairText("journal after", journalText(after))
      check("insert with precision " .. precision .. ": the read kept its precision", function()
        assert(number(read.finished_at_precision) == precision, "precision came back as "
          .. tostring(read.finished_at_precision))
      end)
    else
      check("insert with precision " .. precision, function() error("insert failed", 0) end)
    end
    dropSince(marked)
  end
end

-- 2. Correct an older read while a newer one is unfinished.
print("\n-- update_user_book_read on an older read while a newer read is unfinished --")
do
  local book = books[4]
  local marked = #cleanup
  local user_book, edition = makeRecord(book, 2)
  if user_book then
    local older = addRead(user_book, { started_at = "2019-03-14", finished_at = "2019-03-20",
      finished_at_precision = 1, edition_id = edition.edition_id })
    local newer = addRead(user_book, { started_at = "2020-01-01", edition_id = edition.edition_id })
    setReading(user_book)
    local current = library(book.book_id)
    local before = journalRows(book.book_id)
    local before_shelf = current.status_id
    local before_reads = current.user_book_reads or {}
    print("  " .. tostring(book.title))
    pairText("older read", readText(older))
    pairText("newer read", readText(newer))
    pairText("shelf before", tostring(before_shelf) .. " (" .. tostring(#before_reads) .. " reads)")

    local requested = { started_at = "2019-03-12" }
    local wrote = Api:updateRead(older.id, requested)
    local lag, changed = waitFor(function()
      local reads = readsOf(book.book_id)
      for _, read in ipairs(reads or {}) do
        if tostring(read.id) == tostring(older.id) and read.started_at == "2019-03-12" then return read end
      end
    end, 30)
    local after = library(book.book_id)
    pairText("request", "update_user_book_read(id=" .. older.id .. ", started_at=2019-03-12)")
    pairText("write accepted", tostring(wrote ~= nil))
    pairText("read-after-write", lag and (lag .. "s") or "more than 30s")
    pairText("shelf after", tostring(after.status_id) .. " (" .. tostring(#(after.user_book_reads or {}))
      .. " reads)")
    pairText("journal after", journalText(journalRows(book.book_id)))

    if after.status_id ~= before_shelf then
      local restored = Api:updateUserBookStatus(user_book.id, 2, 3)
      local shelf_lag, same = waitFor(function()
        local again = library(book.book_id)
        if again and again.status_id == 2 then return again end
      end, 30)
      pairText("shelf restored to Currently Reading", tostring(restored ~= nil) ..
        " after " .. (shelf_lag and (shelf_lag .. "s") or "more than 30s"))
      local final = library(book.book_id)
      pairText("reads after restoring", tostring(#(final.user_book_reads or {})) ..
        " (a new one means the restore started another read)")
    end

    -- The same correction again: the plan asks whether repeating it moves the shelf.
    local repeats = Api:updateRead(older.id, requested)
    local repeat_lag, moved = waitFor(function()
      local again = library(book.book_id)
      if again and again.status_id ~= before_shelf then return again end
    end, 10)
    pairText("repeating the identical correction", "accepted=" .. tostring(repeats ~= nil)
      .. ", shelf " .. (moved and ("moved to " .. tostring(moved.status_id) .. " after " .. repeat_lag .. "s")
        or ("stayed " .. tostring((library(book.book_id) or {}).status_id))))
    dropSince(marked)
  end
end

-- 3. Delete a finished read, the only read, and the active read.
print("\n-- delete_user_book_read --")
local delete_cases = {
  { name = "a finished read", make = function(user_book, edition)
      addRead(user_book, { started_at = "2019-03-14", finished_at = "2019-03-20",
        finished_at_precision = 1, edition_id = edition.edition_id })
      return addRead(user_book, { started_at = "2020-01-01", edition_id = edition.edition_id }), "older"
    end },
  { name = "the only read", make = function(user_book, edition)
      return addRead(user_book, { started_at = "2019-03-14", finished_at = "2019-03-20",
        finished_at_precision = 1, edition_id = edition.edition_id }), "only"
    end },
  { name = "the active read", make = function(user_book, edition)
      addRead(user_book, { started_at = "2019-03-14", finished_at = "2019-03-20",
        finished_at_precision = 1, edition_id = edition.edition_id })
      return addRead(user_book, { started_at = "2020-01-01", edition_id = edition.edition_id }), "active"
    end },
}
for index, case in ipairs(delete_cases) do
  local book = books[index]
  local marked = #cleanup
  local user_book, edition = makeRecord(book, 2)
  if user_book then
    local target = case.make(user_book, edition)
    local before = journalRows(book.book_id)
    local before_state = library(book.book_id)
    local response, err = Api:deleteRead(target.id)
    local lag, gone = waitFor(function()
      local reads = readsOf(book.book_id)
      for _, read in ipairs(reads or {}) do
        if tostring(read.id) == tostring(target.id) then return nil end
      end
      return true
    end, 30)
    local after = library(book.book_id)
    print("  " .. case.name .. " (" .. tostring(book.title) .. ")")
    pairText("request", "delete_user_book_read(id=" .. target.id .. ")")
    pairText("response", response and ("id=" .. tostring(response.id)) or ("refused: " .. tostring(err)))
    pairText("read gone", gone and (lag .. "s") or "not within 30s")
    pairText("shelf before", tostring(before_state.status_id) .. " (" ..
      tostring(#(before_state.user_book_reads or {})) .. " reads)")
    pairText("shelf after", tostring(after.status_id) .. " (" .. tostring(#(after.user_book_reads or {}))
      .. " reads)")
    pairText("journal before", journalText(before))
    pairText("journal after", journalText(journalRows(book.book_id)))
    dropSince(marked)
  end
end

-- 4. Change a read's edition and page together.
print("\n-- update_user_book_read with edition_id and progress_pages --")
do
  local book = books[5]
  local marked = #cleanup
  local user_book, edition = makeRecord(book, 2)
  if user_book then
    local read = addRead(user_book, { started_at = "2020-01-01", edition_id = edition.edition_id,
      progress_pages = 150 })
    local editions = Api:findEditions(book.book_id, user_id) or {}
    local other
    for _, candidate in ipairs(editions) do
      if tonumber(candidate.edition_id) ~= tonumber(edition.edition_id)
          and tonumber(candidate.pages) and tonumber(candidate.pages) > 151 then
        other = candidate
        break
      end
    end
    print("  " .. tostring(book.title))
    pairText("read before", readText(read))
    if other then
      pairText("request", "update_user_book_read(id=" .. read.id .. ", edition_id="
        .. tostring(other.edition_id) .. ", progress_pages=151)")
      local updated = Api:updateRead(read.id, { edition_id = other.edition_id, progress_pages = 151 })
      local lag, fresh = waitFor(function()
        local reads = readsOf(book.book_id)
        for _, row in ipairs(reads or {}) do
          if tostring(row.id) == tostring(read.id) then return row end
        end
      end, 30)
      pairText("write accepted", tostring(updated ~= nil))
      pairText("read after", fresh and readText(fresh) or "not within 30s")
      pairText("read-after-write", lag and (lag .. "s") or "more than 30s")
    else
      pairText("other edition", "none with more than 151 pages: the page question is unanswered")
    end
    dropSince(marked)
  end
end

end

local probes_ok, probes_err = pcall(runProbes)

-- 5. What is left, for a repeat run.
print("\n== cleanup ==")
for index = #cleanup, 1, -1 do
  removeRecord(cleanup[index])
end
print("  private library records removed: " .. cleaned)
for index = #cleanup, 1, -1 do
  if removeRecord(cleanup[index]) then table.remove(cleanup, index) end
end
local leftovers = 0
for _, entry in ipairs(touched) do
  local left = library(entry.book_id)
  if type(left) == "table" and left.id then
    leftovers = leftovers + 1
    print("  CLEANUP LEFT: " .. tostring(entry.book_id) .. " (" .. tostring(entry.title)
      .. ") still has user_book " .. tostring(left.id))
  end
end
print("  library cleanup audit: " .. (leftovers == 0 and "no records left for the books this run touched"
  or (leftovers .. " book(s) still have a record")))

-- A catalogue book can have journal rows from before this run even when it was not in the
-- library when selected. Remove only the rows that were not there before the probe touched it,
-- and say exactly what is left if Hardcover refuses any.
local journals_removed, journals_left, journals_preserved = 0, 0, 0
for book_id, title in pairs(journal_books) do
  local before = journal_before[book_id]
  if before == nil then
    print("  journal cleanup skipped for " .. tostring(book_id) .. " (" .. tostring(title)
      .. "): its earlier rows could not be recorded")
  else
    local rows = journalRows(book_id) or {}
    for _, row in ipairs(rows) do
      if before[tostring(row.id)] then
        journals_preserved = journals_preserved + 1
      else
        local deleted, err = Api:deleteJournalEntry(row.id)
        if deleted then
          journals_removed = journals_removed + 1
        else
          print("  journal cleanup failed for " .. tostring(book_id) .. " row " .. tostring(row.id)
            .. ": " .. tostring(type(err) == "table" and json.encode(err) or err))
        end
      end
    end
    waitFor(function()
      local left = journalRows(book_id)
      if not left then return false end
      for _, row in ipairs(left) do
        if not before[tostring(row.id)] then return false end
      end
      return true
    end, 5)
    local left = journalRows(book_id) or {}
    local new_left = 0
    for _, row in ipairs(left) do
      if not before[tostring(row.id)] then new_left = new_left + 1 end
    end
    if new_left > 0 then
      journals_left = journals_left + new_left
      print("  CLEANUP LEFT: " .. tostring(book_id) .. " (" .. tostring(title) .. ") still has "
        .. new_left .. " journal rows this run wrote")
    end
  end
end
print("  journal rows removed: " .. journals_removed
  .. (journals_left > 0 and (", " .. journals_left .. " left") or ", none left")
  .. (journals_preserved > 0 and ("; " .. journals_preserved .. " earlier row(s) kept") or ""))
if not probes_ok then print("  a probe stopped early: " .. tostring(probes_err)) end

check("all probes completed", function() assert(probes_ok, probes_err) end)
step("no HTTP or GraphQL refusals in the run", function()
  if #graphql_errors > 0 then error(table.concat(graphql_errors, "; "), 0) end
end)

r.finish()
