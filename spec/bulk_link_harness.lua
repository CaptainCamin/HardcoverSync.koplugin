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

-- ------------------------------------------------------------ the exact pass keeps the books to guess
local keep, _, _ = scanOf({ "/Plain.epub", "/Lost.epub", "/Down.epub", "/Dune.epub" },
  { ["/Lost.epub"] = "isbn13:9780000000002", ["/Down.epub"] = "isbn13:9780000000004",
    ["/Dune.epub"] = "isbn13:9780441172719" },
  function(parsed)
    if parsed.isbn_13 == "9780000000004" then return "error" end
    return by_isbn[parsed.isbn_13]
  end)
-- (a failed request fails the whole batch, so Lost, Down and Dune are all errors here)
runAll(keep)
r.check("a failed batch is not offered for a guess, books Hardcover does not know are",
  #keep.unmatched == 1 and keep.unmatched[1] == "/Plain.epub", table.concat(keep.unmatched, ","))
local keep2 = scanOf({ "/Plain.epub", "/Lost.epub", "/Dune.epub" },
  { ["/Lost.epub"] = "isbn13:9780000000002", ["/Dune.epub"] = "isbn13:9780441172719" },
  function(parsed) return by_isbn[parsed.isbn_13] end)
runAll(keep2)
r.check("books with no identifier and no match are kept for a guess",
  #keep2.unmatched == 2 and keep2.unmatched[1] == "/Plain.epub" and keep2.unmatched[2] == "/Lost.epub",
  table.concat(keep2.unmatched, ","))

-- ------------------------------------------------------------ title and author from the OPF
local meta_opf = [[
<package><metadata xmlns:dc="x" xmlns:opf="y">
  <dc:title id="t1">Dune &amp; Co</dc:title>
  <dc:subtitle>not this</dc:subtitle>
  <dc:creator opf:role="aut" opf:file-as="Herbert, Frank">Frank Herbert</dc:creator>
  <dc:creator>Someone Else</dc:creator>
</metadata></package>]]
local meta = BulkLink.metadataFromOpf(meta_opf)
r.check("the title is read, with entities decoded", meta and meta.title == "Dune & Co", meta and meta.title)
r.check("the first creator is the author", meta and meta.author == "Frank Herbert", meta and meta.author)
r.check("an OPF with a title only still gives it",
  (BulkLink.metadataFromOpf("<dc:title>Solo</dc:title>") or {}).title == "Solo")
r.check("an OPF with neither gives nil", BulkLink.metadataFromOpf("<package></package>") == nil
  and BulkLink.metadataFromOpf(nil) == nil)
local from_epub = BulkLink.readEpubMetadata("/b/a.epub", fakePopen("  1  2020-01-01 00:00   OEBPS/content.opf", meta_opf))
r.check("an EPUB's title and author are read through unzip", from_epub and from_epub.author == "Frank Herbert")

-- ------------------------------------------------------------ choosing a guess
local function book(id, title, ...)
  local contributions = {}
  for _, name in ipairs({ ... }) do contributions[#contributions + 1] = { author = { name = name } } end
  return { book_id = id, title = title, contributions = contributions }
end
local dune = book(1, "Dune", "Frank Herbert")
local results = { book(9, "Dune Messiah", "Frank Herbert"), book(8, "Dune", "Brian Herbert"), dune }
r.check("the title must match exactly and the author's surname too",
  BulkLink.pickGuess(results, "Dune", "Frank Herbert") == dune)
r.check("a 'Surname, First' author works", BulkLink.pickGuess(results, "Dune", "Herbert, Frank") ~= nil)
r.check("a wrong author is not guessed", BulkLink.pickGuess({ book(8, "Dune", "Brian Smith") }, "Dune", "Frank Herbert") == nil)
r.check("a longer title is not the same book", BulkLink.pickGuess({ book(9, "Dune Messiah", "Frank Herbert") }, "Dune", "Frank Herbert") == nil)
r.check("a subtitle, case and a leading 'The' are ignored",
  BulkLink.pickGuess({ book(3, "The Hobbit: Or There and Back Again", "J.R.R. Tolkien") }, "the HOBBIT", "J. R. R. Tolkien") ~= nil)
r.check("with no author, one exact title is enough", BulkLink.pickGuess({ dune, book(9, "Dune Messiah", "F H") }, "Dune", nil) == dune)
r.check("with no author, two books with that title are too many",
  BulkLink.pickGuess({ dune, book(8, "Dune", "Brian Herbert") }, "Dune", nil) == nil)
r.check("no results, no title, no guess", BulkLink.pickGuess({}, "Dune", "x") == nil
  and BulkLink.pickGuess(results, "", "x") == nil and BulkLink.pickGuess(nil, "Dune", "x") == nil)

local function title_of(picked) return picked and picked.title or nil end
local messiah = book(2, "Dune: Messiah", "Frank Herbert")
r.check("the whole title wins over a title that only starts the same",
  title_of(BulkLink.pickGuess({ dune, messiah }, "Dune: Messiah", "Frank Herbert")) == "Dune: Messiah")
r.check("a file with a subtitle needs the whole title",
  BulkLink.pickGuess({ dune }, "Dune: Messiah", "Frank Herbert") == nil)
r.check("a series with the same start does not pick the first of its books",
  title_of(BulkLink.pickGuess({ book(4, "Star Wars: Heir to the Empire", "Timothy Zahn"),
    book(5, "Star Wars: Thrawn", "Timothy Zahn") }, "Star Wars: Thrawn", "Timothy Zahn")) == "Star Wars: Thrawn")
r.check("a plain title with several subtitled books is too many to choose from",
  BulkLink.pickGuess({ book(4, "Star Wars: Heir to the Empire", "Timothy Zahn"),
    book(5, "Star Wars: Thrawn", "Timothy Zahn") }, "Star Wars", "Timothy Zahn") == nil)
r.check("a title with no author and no exact result is not guessed from subtitled ones",
  BulkLink.pickGuess({ book(4, "Star Wars: Heir to the Empire", "Timothy Zahn"),
    book(5, "Star Wars: Thrawn", "Timothy Zahn") }, "Star Wars", nil) == nil)

-- ------------------------------------------------------------ the guess scan
local function guessScanOf(files, metas, searches, titles)
  local stored, calls = {}, { titles = {}, searches = {} }
  local g = BulkLink.newGuess(files, {
    read_metadata = function(file)
      local m = metas[file]
      if m == "error" then error("unreadable") end
      return m
    end,
    search_titles = function(list)
      calls.titles[#calls.titles + 1] = list
      if titles == "error" then error("offline") end
      return titles
    end,
    search = function(title)
      calls.searches[#calls.searches + 1] = title
      local found = searches[title]
      if found == "error" then error("offline") end
      return found
    end,
    store = function(file, cfg) stored[file] = cfg end,
  })
  return g, stored, calls
end
local function runGuess(g)
  local network = 0
  while not BulkLink.done(g) do
    if BulkLink.stepGuess(g) then network = network + 1 end
  end
  return network
end

local g, gstored, gcalls = guessScanOf(
  { "/Dune.epub", "/Untitled.epub", "/Wrong.epub", "/Broken.epub", "/Offline.epub", "/Failed.epub", "/Loose.epub" },
  { ["/Dune.epub"] = { title = "Dune", author = "Frank Herbert" }, ["/Untitled.epub"] = nil,
    ["/Wrong.epub"] = { title = "Emma", author = "Jane Austen" }, ["/Broken.epub"] = "error",
    ["/Offline.epub"] = { title = "Offline" }, ["/Failed.epub"] = { title = "Failed" },
    ["/Loose.epub"] = { title = "loose title", author = "Frank Herbert" } },
  { Emma = { book(5, "Emma", "Somebody Else") }, Offline = "error",
    ["loose title"] = { book(6, "Loose Title", "Frank Herbert") } },
  { Dune = { dune } })
r.check("reading a file does not call Hardcover", BulkLink.stepGuess(g) == false and #gcalls.titles == 0)
local gnetwork = runGuess(g)
r.check("every title is asked for in one request", #gcalls.titles == 1 and #gcalls.titles[1] == 5, #gcalls.titles)
r.check("the guess is stored with its mark",
  gstored["/Dune.epub"] and gstored["/Dune.epub"].book_id == 1 and gstored["/Dune.epub"].guessed_book_id == 1)
r.check("a book settled by the batch is not searched for", not tostring(table.concat(gcalls.searches, ",")):find("Dune", 1, true))
r.check("a book the batch could not settle is searched for, one request each",
  table.concat(gcalls.searches, ",") == "Emma,Offline,Failed,loose title", table.concat(gcalls.searches, ","))
r.check("a spelling only search finds is still linked", gstored["/Loose.epub"] and gstored["/Loose.epub"].book_id == 6)
r.check("a request for the batch and one for each search", gnetwork == 5, gnetwork)
r.check("a book with no title does not call Hardcover", g.no_title == 1)
r.check("a result that does not match is reported, not linked", gstored["/Wrong.epub"] == nil and #g.no_match == 1)
r.check("an unreadable file is an error", g.errors >= 1)
r.check("a failed search is an error, a search with no answer (nil) too", g.errors == 3, g.errors)
r.check("every book was counted once", g.checked == 7, g.checked)
r.check("the guess scan is done", BulkLink.done(g) and #g.linked == 2 and g.linked[1].authors == "Frank Herbert")
local gsummary = BulkLink.guessSummary(g)
r.check("the guess summary counts each outcome", gsummary:find("Linked by guess: 2", 1, true)
  and gsummary:find("No confident match: 1", 1, true) and gsummary:find("No title in the file: 1", 1, true)
  and gsummary:find("Could not check: 3", 1, true), gsummary)

do
  local files, metas = {}, {}
  for i = 1, 30 do
    files[i] = "/b" .. i .. ".epub"
    metas[files[i]] = { title = "T" .. i, author = "A B" }
  end
  local scan, _, calls = guessScanOf(files, metas, {}, {})
  runGuess(scan)
  r.check("titles are asked for BATCH at a time", #calls.titles == 2 and #calls.titles[1] == BulkLink.BATCH
    and #calls.titles[2] == 30 - BulkLink.BATCH, #calls.titles)
  r.check("a titles request that fails falls back to searching every book", #calls.searches == 30)
  local failing, _, fcalls = guessScanOf({ "/a.epub" }, { ["/a.epub"] = { title = "Dune", author = "Frank Herbert" } },
    { Dune = { dune } }, "error")
  runGuess(failing)
  r.check("a titles call that raises is a fallback to search, not an error",
    #failing.linked == 1 and failing.errors == 0 and #fcalls.searches == 1)
end

-- ------------------------------------------------------------ reviewing guesses
local saved = {
  ["/b/Zed.epub"] = { book_id = 2, title = "Zed", guessed_book_id = 2 },
  ["/b/Dune.epub"] = { book_id = 1, title = "Dune", guessed_book_id = 1 },
  ["/b/Hand.epub"] = { book_id = 7, title = "Relinked", guessed_book_id = 3 },
  ["/b/Exact.epub"] = { book_id = 4, title = "Exact" },
}
local guessed = BulkLink.guessedBooks(saved)
r.check("only still-guessed links are listed, in name order",
  #guessed == 2 and guessed[1].name == "Dune" and guessed[2].name == "Zed", #guessed)
local function applied(config, setting)
  local out = {}
  for k, v in pairs(setting) do out[k] = v end
  for _, key in ipairs(config._delete or {}) do out[key] = nil end
  return out
end
local right = applied(BulkLink.confirmGuessConfig(), saved["/b/Dune.epub"])
r.check("confirming keeps the link and drops the mark", right.book_id == 1 and right.guessed_book_id == nil)
local wrong = applied(BulkLink.undoGuessConfig(), saved["/b/Dune.epub"])
r.check("undoing forgets the link and the mark", wrong.book_id == nil and wrong.title == nil and wrong.guessed_book_id == nil)
r.check("no guesses in empty settings", #BulkLink.guessedBooks(nil) == 0)

r.finish()
