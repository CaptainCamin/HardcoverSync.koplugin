-- Link all books on the device (hardcover/lib/bulk_link.lua): reading an EPUB's identifiers,
-- picking the books to check, and the one-book-per-tick scan.
--
-- Run with:  lua spec/bulk_link_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()

local BulkLink = require("hardcover/lib/bulk_link")

-- ------------------------------------------------------------ the OPF
local opf = [[
<package><metadata xmlns:dc="x" xmlns:opf="y">
  <dc:identifier id="uid" opf:scheme="ISBN">978-0-306-40615-7</dc:identifier>
  <dc:identifier opf:scheme="hardcover">the-hobbit</dc:identifier>
  <dc:identifier>urn:uuid:1234</dc:identifier>
  <dc:identifier>isbn13:9780306406157</dc:identifier>
</metadata></package>]]
local ids = BulkLink.identifiersFromOpf(opf)
r.check("an ISBN scheme becomes an isbn line", ids:find("isbn:978-0-306-40615-7", 1, true) ~= nil, ids)
r.check("a hardcover scheme becomes a hardcover line", ids:find("hardcover:the-hobbit", 1, true) ~= nil, ids)
r.check("an identifier with no known scheme is left out", ids:find("urn:uuid", 1, true) == nil, ids)
r.check("a prefixed identifier is kept as written", ids:find("isbn13:9780306406157", 1, true) ~= nil, ids)
r.check("an OPF with no usable identifier gives nil",
  BulkLink.identifiersFromOpf("<package><dc:identifier>urn:uuid:1</dc:identifier></package>") == nil)
r.check("no OPF gives nil", BulkLink.identifiersFromOpf(nil) == nil)
r.check("a meta tag's Hardcover reference is found",
  (BulkLink.identifiersFromOpf("<meta name='x' content='hardcover : dune'/>") or ""):find("hardcover:dune", 1, true) ~= nil)
r.check("the words Hardcover: Penguin in a description are not an identifier",
  BulkLink.identifiersFromOpf("<dc:description>Hardcover: Penguin, 2001</dc:description>") == nil)
r.check("entities in a value are decoded",
  (BulkLink.identifiersFromOpf('<dc:identifier opf:scheme="isbn">978&amp;0</dc:identifier>') or ""):find("isbn:978&0", 1, true) ~= nil)

-- ------------------------------------------------------------ reading an EPUB
local commands = {}
local function fakePopen(listing, content)
  return function(cmd)
    commands[#commands + 1] = cmd
    local text = cmd:find("unzip %-lqq") and listing or content
    local lines = {}
    for line in (text or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
    local i = 0
    return { lines = function() return function() i = i + 1; return lines[i] end end, close = function() end }
  end
end
local read = BulkLink.readEpubIdentifiers("/books/it's a book.epub",
  fakePopen("   2048  2020-01-01 00:00   OEBPS/content.opf", opf))
r.check("an EPUB's OPF is read through unzip", read and read:find("hardcover:the-hobbit", 1, true) ~= nil, read)
r.check("a path with a quote is shell-quoted", commands[1]:find("'/books/it'\\''s a book.epub'", 1, true) ~= nil, commands[1])
r.check("a book that is not an EPUB is not opened",
  BulkLink.readEpubIdentifiers("/books/a.pdf", function() error("opened") end) == nil)
r.check("an EPUB with no OPF gives nil", BulkLink.readEpubIdentifiers("/b/a.epub", fakePopen("", "")) == nil)

-- ------------------------------------------------------------ the link settings
local config = BulkLink.linkConfig({ book_id = 5, edition_id = 9, title = "Dune", pages = 412,
  edition_format = "Paperback" })
r.check("the link carries the book and edition", config.book_id == 5 and config.edition_id == 9)
r.check("the link carries title, pages and format",
  config.title == "Dune" and config.pages == 412 and config.edition_format == "Paperback")
r.check("nothing is deleted when everything is known", #config._delete == 0)
local bare = BulkLink.linkConfig({ book_id = 5, title = "Dune" })
local deleted = {}
for _, key in ipairs(bare._delete) do deleted[key] = true end
r.check("what the book lacks is cleared from an earlier link",
  deleted.edition_id and deleted.pages and deleted.edition_format and not deleted.book_id and not deleted.title)

-- ------------------------------------------------------------ finding books
local tree = {
  ["/home"] = { "a.epub", "B.EPUB", "notes.txt", ".hidden", "Sub", "c.sdr", "d.pdf" },
  ["/home/Sub"] = { "e.epub" },
  ["/home/c.sdr"] = { "inside.epub" },
  ["/home/.hidden"] = { "secret.epub" },
}
local lfs = {
  dir = function(path)
    local names = tree[path]
    if not names then error("cannot open " .. path) end
    local i = 0
    return function() i = i + 1; return names[i] end
  end,
  attributes = function(path)
    if tree[path] then return "directory" end
    return "file"
  end,
}
local found = BulkLink.findFiles("/home", lfs)
r.check("epubs are found in folders and sub folders", #found == 3, table.concat(found, ","))
r.check("hidden folders, sidecars and other formats are skipped",
  not table.concat(found, ","):find("secret") and not table.concat(found, ","):find("inside")
  and not table.concat(found, ","):find("pdf"))
r.check("an unreadable or missing root finds nothing", #BulkLink.findFiles("/nowhere", lfs) == 0
  and #BulkLink.findFiles(nil, lfs) == 0)

local todo = BulkLink.candidates({ "/a.epub", "/b.epub", "/a.epub", "/c.epub" },
  function(file) return file == "/b.epub" end)
r.check("linked and repeated books are not checked again", #todo == 2 and todo[1] == "/a.epub" and todo[2] == "/c.epub")

-- ------------------------------------------------------------ the scan
-- `answers_for(parsed)` is the lookup: a book, false (Hardcover has none), per file; "error" fails the batch.
local function scanOf(files, identifiers, answers_for)
  local stored, batches = {}, {}
  local scan = BulkLink.new(files, {
    read_identifiers = function(file)
      local value = identifiers[file]
      if value == "error" then error("unreadable") end
      return value
    end,
    lookup_batch = function(list)
      batches[#batches + 1] = list
      local out = {}
      for i, parsed in ipairs(list) do
        local answer = answers_for(parsed)
        if answer == "error" then return nil, { completed = false } end
        out[i] = answer
      end
      return out
    end,
    store = function(file, cfg) stored[file] = cfg end,
  })
  return scan, stored, batches
end

local function runAll(scan)
  local network = 0
  local guard = 0
  while not BulkLink.done(scan) and guard < 1000 do
    if BulkLink.step(scan) then network = network + 1 end
    guard = guard + 1
  end
  return network
end

local by_isbn = {
  ["9780441172719"] = { book_id = 7, title = "Dune", edition_id = 3 },
  ["9780000000002"] = false,
}
local scan, stored, batches = scanOf(
  { "/Dune.epub", "/Plain.epub", "/Lost.epub", "/Broken.epub" },
  { ["/Dune.epub"] = "isbn13:9780441172719", ["/Lost.epub"] = "isbn13:9780000000002", ["/Broken.epub"] = "error" },
  function(parsed) return by_isbn[parsed.isbn_13] end)
r.check("reading files does not use the network", BulkLink.step(scan) == false and #batches == 0)
local network = runAll(scan)
r.check("the books are looked up together, in one request", network == 1 and #batches == 1 and #batches[1] == 2, network)
r.check("it is linked with its Hardcover ids", stored["/Dune.epub"] and stored["/Dune.epub"].book_id == 7
  and stored["/Dune.epub"].edition_id == 3)
r.check("a book without identifiers is counted, not looked up", scan.no_id == 1)
r.check("a book Hardcover does not know is reported, not linked", #scan.no_match == 1 and stored["/Lost.epub"] == nil)
r.check("an unreadable file counts as an error and goes on", scan.errors == 1)
r.check("every file is checked", scan.checked == 4 and BulkLink.done(scan))
r.check("stepping a finished scan does nothing", BulkLink.step(scan) == false)
r.check("only the book with a match was written", #scan.linked == 1 and scan.linked[1].name == "Dune"
  and scan.linked[1].matched == "Dune")
r.check("lookups carry parsed identifiers", batches[1][1].isbn_13 == "9780441172719")

-- batches are cut at BATCH
local many, ids = {}, {}
for i = 1, 60 do
  many[i] = "/b" .. i .. ".epub"
  ids[many[i]] = "isbn13:97800000000" .. string.format("%02d", i)
end
local big, _, big_batches = scanOf(many, ids, function(parsed)
  return { book_id = tonumber(parsed.isbn_13:sub(-2)), title = "T" }
end)
local big_network = runAll(big)
r.check("60 books go in 3 requests of at most BATCH", big_network == 3 and #big_batches == 3
  and #big_batches[1] == BulkLink.BATCH and #big_batches[3] == 60 - 2 * BulkLink.BATCH, #big_batches)
r.check("all of them are linked", #big.linked == 60)

-- a failed request is an error for its batch, not "no match"
local failing_scan = scanOf({ "/a.epub", "/b.epub" },
  { ["/a.epub"] = "isbn13:9780441172719", ["/b.epub"] = "isbn13:9780441172719" },
  function() return "error" end)
runAll(failing_scan)
r.check("a failed lookup counts every book in the batch as an error", failing_scan.errors == 2
  and #failing_scan.no_match == 0 and #failing_scan.linked == 0)

local thrown = scanOf({ "/a.epub" }, { ["/a.epub"] = "isbn13:9780441172719" }, function() return {} end)
thrown.deps.lookup_batch = function() error("boom") end
runAll(thrown)
r.check("a lookup that raises is an error too", thrown.errors == 1)

local cancelled = scanOf({ "/a.epub", "/b.epub" }, {}, function() end)
cancelled.cancelled = true
r.check("a cancelled scan does no more work", BulkLink.done(cancelled) and BulkLink.step(cancelled) == false
  and cancelled.index == 0)

local summary = BulkLink.summary(scan)
r.check("the summary counts each outcome", summary:find("Linked: 1", 1, true) and summary:find("No match on Hardcover: 1", 1, true)
  and summary:find("file: 1", 1, true) and summary:find("Could not check: 1", 1, true), summary)
r.check("a cancelled summary says so", BulkLink.summary(cancelled):find("stopped", 1, true) ~= nil)

local failing = scanOf({ "/a.epub" }, { ["/a.epub"] = "isbn13:9780441172719" },
  function() return { book_id = 1, title = "X" } end)
failing.deps.store = function() error("disk full") end
runAll(failing)
r.check("a failed save is an error, not a link", failing.errors == 1 and #failing.linked == 0)

r.finish()
