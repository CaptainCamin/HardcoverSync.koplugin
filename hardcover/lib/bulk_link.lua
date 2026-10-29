-- Link every book on the device to Hardcover in one pass.
--
-- Adapted from the "Auto-link all books" scan in Bookshelf
-- (https://github.com/AndyHazz/bookshelf.koplugin, AGPL-3.0, lib/bookshelf_settings.lua and
-- lib/bookshelf_hardcover.lua): the way it reads an EPUB's embedded ISBN / Hardcover
-- identifiers from the OPF, and a paced, cancellable scan with a report at the end.
--
-- Unlike Bookshelf's, the scan asks Hardcover about many books at once: reading a file is local
-- and cheap, so it is done one file per tick with no wait, and the identifiers read are looked up
-- BATCH at a time (Api:findBooksByIdentifiers: a few requests for the batch, not a few per book).
--
-- Everything that touches KOReader or the network is passed in, so the scan can be driven
-- from a spec: `read_identifiers` reads a file's identifiers, `lookup_batch` finds the
-- Hardcover books for a list of parsed identifiers, `store` writes the link.

local Book = require("hardcover/lib/book")

local BulkLink = {}

-- How far below the root the walk goes, and the most files it will list.
local MAX_DEPTH = 8
local MAX_FILES = 20000

local function shellQuote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function xmlDecode(s)
  if not s then return "" end
  return (s:gsub("&lt;", "<")
           :gsub("&gt;", ">")
           :gsub("&quot;", "\"")
           :gsub("&apos;", "'")
           :gsub("&amp;", "&")
           :gsub("^%s+", "")
           :gsub("%s+$", ""))
end

local function attr(attrs, name)
  if type(attrs) ~= "string" then return nil end
  return attrs:match(name .. '%s*=%s*"([^"]+)"') or attrs:match(name .. "%s*=%s*'([^']+)'")
end

-- One <dc:identifier> as a "key:value" line `Book:parseIdentifiers` understands, or nil.
local function identifierToken(attrs, value)
  value = xmlDecode(value)
  if value == "" then return nil end
  local lower = value:lower()
  if lower:match("^hardcover[%w_-]*:") or lower:match("^isbn[%w_-]*:") or lower:match("^urn:isbn:") then
    return value
  end

  local scheme = attr(attrs, "opf:scheme") or attr(attrs, "scheme")
  if not scheme or scheme == "" then return nil end
  scheme = scheme:lower():gsub("_", "-")
  if scheme == "hardcover" or scheme == "hardcover-slug" then
    return "hardcover:" .. value
  elseif scheme == "hardcover-edition" or scheme == "hardcover-edition-id" then
    return "hardcover-edition:" .. value
  elseif scheme == "isbn" or scheme == "isbn10" or scheme == "isbn-10" then
    return "isbn:" .. value
  elseif scheme == "isbn13" or scheme == "isbn-13" then
    return "isbn13:" .. value
  end
  return nil
end

-- The identifiers in an OPF document, one per line, or nil when it has none we use.
function BulkLink.identifiersFromOpf(opf)
  if type(opf) ~= "string" or opf == "" then return nil end
  local tokens, seen = {}, {}
  local function add(token)
    if token and token ~= "" and not seen[token] then
      seen[token] = true
      tokens[#tokens + 1] = token
    end
  end
  for attrs, value in opf:gmatch("<%s*[%w_%-:]*identifier([^>]*)>(.-)</%s*[%w_%-:]*identifier%s*>") do
    add(identifierToken(attrs, value))
  end
  -- A Hardcover reference in a <meta> tag's content ("hardcover:slug"). Not anywhere else: the
  -- words "Hardcover: Penguin" in a description are not an identifier.
  for attrs in opf:gmatch("<%s*meta%s([^>]*)>") do
    local content = attr(attrs, "content")
    if content then
      content = xmlDecode(content)
      if content:lower():match("^hardcover[%w_-]*%s*:%s*[%w_-]+$") then
        add((content:gsub("%s*:%s*", ":")))
      end
    end
  end
  return #tokens > 0 and table.concat(tokens, "\n") or nil
end

-- The text of an EPUB's OPF, read by the system `unzip`. nil for any other format, a book without
-- an OPF, or a device without unzip.
function BulkLink.readEpubOpf(filepath, popen)
  popen = popen or io.popen
  if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then return nil end

  local list = popen("unzip -lqq " .. shellQuote(filepath) .. " '*.opf' 2>/dev/null", "r")
  if not list then return nil end
  local opf_path
  for line in list:lines() do
    opf_path = line:match("%s+%d+%s+%S+%s+%S+%s+(.+%.opf)$") or line:match("([^%s].-%.opf)$")
    if opf_path then break end
  end
  list:close()
  if not opf_path then return nil end

  local read = popen("unzip -p " .. shellQuote(filepath) .. " " .. shellQuote(opf_path) .. " 2>/dev/null", "r")
  if not read then return nil end
  local chunks, total = {}, 0
  for chunk in read:lines() do
    total = total + #chunk
    if total > 1024 * 1024 then break end
    chunks[#chunks + 1] = chunk
  end
  read:close()
  return table.concat(chunks, "\n")
end

-- The identifiers inside an EPUB, one per line, or nil.
function BulkLink.readEpubIdentifiers(filepath, popen)
  return BulkLink.identifiersFromOpf(BulkLink.readEpubOpf(filepath, popen))
end

-- The title and first author in an OPF document ({ title =, author = }, either may be nil), or nil
-- when it has neither.
function BulkLink.metadataFromOpf(opf)
  if type(opf) ~= "string" or opf == "" then return nil end
  local function first(tag)
    local value = opf:match("<%s*[%w_%-]*:?" .. tag .. "[^>]*>(.-)</%s*[%w_%-]*:?" .. tag .. "%s*>")
    value = value and xmlDecode((value:gsub("<[^>]*>", ""))) or ""
    return value ~= "" and value or nil
  end
  local title, author = first("title"), first("creator")
  if not title and not author then return nil end
  return { title = title, author = author }
end

function BulkLink.readEpubMetadata(filepath, popen)
  return BulkLink.metadataFromOpf(BulkLink.readEpubOpf(filepath, popen))
end

-- The per-book settings that link a file to `book` (a normalised Hardcover book), in the shape
-- Hardcover:linkBook saves them.
function BulkLink.linkConfig(book)
  local delete = {}
  for _index, key in ipairs({ "book_id", "edition_id", "edition_format", "pages", "title" }) do
    local value = key == "edition_format" and Book:editionFormatName(book.edition_format, book.reading_format_id)
      or book[key]
    if value == nil then delete[#delete + 1] = key end
  end
  return {
    book_id = book.book_id,
    edition_id = book.edition_id,
    edition_format = Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    _delete = delete,
  }
end

-- Every .epub under `root`, in a stable order. Hidden folders and KOReader's .sdr folders are
-- skipped. `lfs` is passed in (KOReader's libs/lfs).
function BulkLink.findFiles(root, lfs)
  local files = {}
  local function walk(dir, depth)
    if depth > MAX_DEPTH or #files >= MAX_FILES then return end
    local names = {}
    local ok = pcall(function()
      for name in lfs.dir(dir) do
        if name:sub(1, 1) ~= "." then names[#names + 1] = name end
      end
    end)
    if not ok then return end
    table.sort(names)
    for _index, name in ipairs(names) do
      local path = dir:gsub("/$", "") .. "/" .. name
      local mode = lfs.attributes(path, "mode")
      if mode == "directory" then
        if not name:match("%.sdr$") then walk(path, depth + 1) end
      elseif mode == "file" and name:lower():match("%.epub$") then
        files[#files + 1] = path
        if #files >= MAX_FILES then return end
      end
    end
  end
  if type(root) == "string" and root ~= "" then walk(root, 0) end
  return files
end

-- The files that are not linked yet, in order and without repeats.
function BulkLink.candidates(files, is_linked)
  local out, seen = {}, {}
  for _index, file in ipairs(files or {}) do
    if not seen[file] then
      seen[file] = true
      if not is_linked(file) then out[#out + 1] = file end
    end
  end
  return out
end


-- Files looked up in one request, and the seconds to wait after one. A batch costs up to four
-- requests (edition ids, slugs, ISBN-13s, ISBN-10s) and the API allows 60 a minute.
BulkLink.BATCH = 25
BulkLink.RATE = 4

-- Seconds between guesses: each is one search of Hardcover, and they cannot be batched.
BulkLink.GUESS_RATE = 2.5

-- A scan over `items`. `deps` is { read_identifiers, lookup_batch, store }. Call `BulkLink.step`
-- once per tick; it says whether it used the network (so the caller can wait before the next one).
function BulkLink.new(items, deps)
  return {
    items = items,
    deps = deps,
    -- files read so far
    index = 0,
    -- read, with identifiers, and waiting for a lookup: { file =, parsed = }
    queue = {},
    -- files finished: no identifier, looked up, or failed
    checked = 0,
    cancelled = false,
    linked = {},
    no_id = 0,
    no_match = {},
    -- the files the exact pass could not match (no identifier, or Hardcover does not know it):
    -- the books a guess pass can try
    unmatched = {},
    errors = 0,
  }
end

function BulkLink.total(scan)
  return #scan.items
end

function BulkLink.done(scan)
  return scan.cancelled
    or (scan.index >= #scan.items and #scan.queue == 0 and not (scan.fallback and #scan.fallback > 0))
end

local function nameOf(file)
  return (file:match("([^/]+)$") or file):gsub("%.[^%.]+$", "")
end

local function usable(parsed)
  return parsed.isbn_13 or parsed.isbn_10 or parsed.book_slug or parsed.edition_id
end

-- Look up the next BATCH queued files in one go.
local function lookup(scan)
  local batch = {}
  for _index = 1, math.min(BulkLink.BATCH, #scan.queue) do
    batch[#batch + 1] = table.remove(scan.queue, 1)
  end
  scan.checked = scan.checked + #batch

  local parsed = {}
  for i, entry in ipairs(batch) do parsed[i] = entry.parsed end

  -- `lookup_batch` gives one answer per file in order (a book, or false when Hardcover has no such
  -- book), or nil when a call failed (offline, rate limit, expired token): that is not "no match".
  local ok, answers = pcall(scan.deps.lookup_batch, parsed)
  if not ok or type(answers) ~= "table" then
    scan.errors = scan.errors + #batch
    return
  end

  for i, entry in ipairs(batch) do
    local book = answers[i]
    if not (book and book.book_id) then
      scan.no_match[#scan.no_match + 1] = { name = nameOf(entry.file) }
      scan.unmatched[#scan.unmatched + 1] = entry.file
    elseif pcall(scan.deps.store, entry.file, BulkLink.linkConfig(book)) then
      scan.linked[#scan.linked + 1] = { name = nameOf(entry.file), matched = book.title,
        file = entry.file, book_id = book.book_id, edition_id = book.edition_id }
    else
      scan.errors = scan.errors + 1
    end
  end
end

-- Do the next piece of work: look up a full batch, else read the next file, else look up what is
-- left. Returns true when it called Hardcover.
function BulkLink.step(scan)
  if BulkLink.done(scan) then return false end

  if #scan.queue >= BulkLink.BATCH or (scan.index >= #scan.items and #scan.queue > 0) then
    lookup(scan)
    return true
  end

  scan.index = scan.index + 1
  local file = scan.items[scan.index]
  local ok, identifiers = pcall(scan.deps.read_identifiers, file)
  if not ok then
    scan.errors = scan.errors + 1
    scan.checked = scan.checked + 1
    return false
  end
  local parsed = identifiers and Book:parseIdentifiers(identifiers) or {}
  if not usable(parsed) then
    scan.no_id = scan.no_id + 1
    scan.checked = scan.checked + 1
    scan.unmatched[#scan.unmatched + 1] = file
    return false
  end
  scan.queue[#scan.queue + 1] = { file = file, parsed = parsed }
  return false
end

-- ------------------------------------------------------------ guessing by title and author
--
-- A guess must be safe to keep without a look, or easy to see wrong: it links only when the
-- title matches exactly (after case, punctuation, a subtitle and a leading "the" are ignored)
-- and the author (surname, and first initial if given) is one of the book's authors. A file with
-- no author links only if exactly one result has that title. Anything else is left unlinked.

local function normalizeWith(text, keep_subtitle)
  text = tostring(text or ""):lower()
  text = text:gsub("%b()", " "):gsub("%b[]", " ")
  if not keep_subtitle then text = text:gsub(":.*$", "") end
  text = text:gsub("[^%w%s]", " ")
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("^the ", ""):gsub("^an? ", "")
  return text
end
-- The title without its subtitle; `full` keeps the subtitle.
local function normalize(text) return normalizeWith(text, false) end
local function full(text) return normalizeWith(text, true) end
BulkLink.normalize = normalize

-- The surname and first initial of "Frank Herbert" or "Herbert, Frank" (lower case; the initial is
-- nil when no first name is given), or nil for an empty name.
local function person(author)
  author = tostring(author or "")
  local last, given
  local before, after = author:match("^([^,]+),%s*(.*)$")
  if before then
    last, given = before:match("(%S+)%s*$"), after
  else
    last = author:match("(%S+)%s*$")
    given = author:match("^%s*(%S+)%s+%S")
  end
  last = normalize(last or "")
  if last == "" then return nil end
  local initial = normalize(given or ""):sub(1, 1)
  return { surname = last, initial = initial ~= "" and initial or nil }
end

-- The author names on a Hardcover book (the structured `contributions`).
local function authorNames(book)
  local names = {}
  local contributions = book.contributions
  if type(contributions) == "table" then
    if contributions.author then contributions = { contributions } end
    for _index, contribution in ipairs(contributions) do
      local author = type(contribution) == "table" and contribution.author
      if type(author) == "table" and author.name then
        names[#names + 1] = author.name
      elseif type(author) == "string" then
        names[#names + 1] = author
      end
    end
  end
  return names
end
BulkLink.authorNames = authorNames

-- Is `wanted` (from person()) one of the book's authors: the same surname, and the same first
-- initial when both give one (so "Frank Herbert" is not "Brian Herbert").
local function hasAuthor(book, wanted)
  for _index, name in ipairs(authorNames(book)) do
    local candidate = person(name)
    if candidate and candidate.surname == wanted.surname
      and (not candidate.initial or not wanted.initial or candidate.initial == wanted.initial) then
      return true
    end
  end
  return false
end

-- The result to link for a file called `title` by `author`, or nil when none is safe. The whole
-- title is matched first, so "Dune: Messiah" is never "Dune". A file whose title has no subtitle
-- may also match a result that only adds one ("The Hobbit" and "The Hobbit: Or There and Back
-- Again"), but only when exactly one result does: a series ("Star Wars: Thrawn", "Star Wars:
-- Heir to the Empire") is not told apart by its first words.
function BulkLink.pickGuess(results, title, author)
  local wanted_title = normalize(title)
  if wanted_title == "" or type(results) ~= "table" then return nil end
  local wanted_full = full(title)
  local has_subtitle = wanted_full ~= wanted_title
  local wanted_author = person(author)

  local function acceptable(book)
    return not wanted_author or hasAuthor(book, wanted_author)
  end
  local function matching(same)
    local out = {}
    for _index, book in ipairs(results) do
      if book.book_id and same(book) and acceptable(book) then out[#out + 1] = book end
    end
    return out
  end

  local whole = matching(function(book) return full(book.title) == wanted_full end)
  if wanted_author and #whole > 0 then return whole[1] end
  if #whole == 1 then return whole[1] end
  if #whole > 1 or has_subtitle then return nil end

  local started = matching(function(book) return normalize(book.title) == wanted_title end)
  return #started == 1 and started[1] or nil
end

-- A scan that guesses for `items` (files). `deps` is { read_metadata, search_titles, search, store }:
-- `read_metadata(file)` gives { title, author } or nil, `search_titles(titles)` gives Hardcover's
-- books for many exact titles at once (a table from title to books; nil when the call failed),
-- `search(title, author)` gives the results of searching for one (nil when the call failed), and
-- `store(file, config)` writes the link.
--
-- Titles are tried BATCH at a time first, which settles most books in one request. A book that
-- batch could not settle (spelled differently, an author that does not match, several candidates) is
-- then searched for on its own, as before.
function BulkLink.newGuess(items, deps)
  local scan = BulkLink.new(items, deps)
  scan.guess = true
  scan.no_title = 0
  -- { file =, meta = } for books the batch did not settle: searched for one by one
  scan.fallback = {}
  return scan
end

local function link(scan, file, book)
  local config = BulkLink.linkConfig(book)
  config.guessed_book_id = book.book_id
  if pcall(scan.deps.store, file, config) then
    scan.linked[#scan.linked + 1] = { name = nameOf(file), matched = book.title,
      authors = table.concat(authorNames(book), ", "),
      file = file, book_id = book.book_id, edition_id = book.edition_id }
  else
    scan.errors = scan.errors + 1
  end
end

-- Try the next BATCH queued books by exact title in one request.
local function guessBatch(scan)
  local batch, titles, seen = {}, {}, {}
  for _index = 1, math.min(BulkLink.BATCH, #scan.queue) do
    local entry = table.remove(scan.queue, 1)
    batch[#batch + 1] = entry
    if not seen[entry.meta.title] then
      seen[entry.meta.title] = true
      titles[#titles + 1] = entry.meta.title
    end
  end

  local ok, found = pcall(scan.deps.search_titles, titles)
  if not ok or type(found) ~= "table" then found = {} end

  for _index, entry in ipairs(batch) do
    local book = BulkLink.pickGuess(found[entry.meta.title], entry.meta.title, entry.meta.author)
    if book then
      scan.checked = scan.checked + 1
      link(scan, entry.file, book)
    else
      scan.fallback[#scan.fallback + 1] = entry
    end
  end
end

-- Search for one book the batch could not settle.
local function guessOne(scan)
  local entry = table.remove(scan.fallback, 1)
  scan.checked = scan.checked + 1
  local meta = entry.meta
  local ok_search, results = pcall(scan.deps.search, meta.title, meta.author)
  if not ok_search or results == nil then
    scan.errors = scan.errors + 1
    return
  end
  local book = BulkLink.pickGuess(results, meta.title, meta.author)
  if not book then
    scan.no_match[#scan.no_match + 1] = { name = nameOf(entry.file) }
    return
  end
  link(scan, entry.file, book)
end

-- Do the next piece of work: try a full batch of titles, else read the next book's title, else try
-- what is left of the batch, else search for one of the books still unsettled. Returns true when it
-- called Hardcover.
function BulkLink.stepGuess(scan)
  if BulkLink.done(scan) then return false end

  if #scan.queue >= BulkLink.BATCH or (scan.index >= #scan.items and #scan.queue > 0) then
    guessBatch(scan)
    return true
  end

  if scan.index >= #scan.items then
    guessOne(scan)
    return true
  end

  scan.index = scan.index + 1
  local file = scan.items[scan.index]
  local ok_read, meta = pcall(scan.deps.read_metadata, file)
  if not ok_read then
    scan.errors = scan.errors + 1
    scan.checked = scan.checked + 1
    return false
  end
  if not (meta and meta.title and normalize(meta.title) ~= "") then
    scan.no_title = scan.no_title + 1
    scan.checked = scan.checked + 1
    return false
  end
  scan.queue[#scan.queue + 1] = { file = file, meta = meta }
  return false
end

-- ------------------------------------------------------------ reviewing guesses

-- Books whose link is a guess that nobody has confirmed: `books` is the saved per-book settings
-- (filename -> settings). A guess counts only while the book is still the one guessed, so linking
-- a different book by hand ends it.
function BulkLink.guessedBooks(books)
  local out = {}
  for file, setting in pairs(books or {}) do
    if type(setting) == "table" and setting.guessed_book_id ~= nil
      and setting.guessed_book_id == setting.book_id then
      out[#out + 1] = { file = file, name = nameOf(file), title = setting.title, book_id = setting.book_id }
    end
  end
  table.sort(out, function(a, b)
    if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
    return a.file < b.file
  end)
  return out
end

-- Settings changes for the two answers to a guess: it was right (keep the link, drop the mark),
-- or wrong (forget the link).
function BulkLink.confirmGuessConfig()
  return { _delete = { "guessed_book_id" } }
end

function BulkLink.undoGuessConfig()
  return { _delete = { "book_id", "edition_id", "edition_format", "pages", "title", "guessed_book_id" } }
end

-- The words for the end of a guess scan.
function BulkLink.guessSummary(scan)
  local lines = {}
  lines[#lines + 1] = scan.cancelled and "Guessing stopped." or "Guessing finished."
  lines[#lines + 1] = string.format("Linked by guess: %d", #scan.linked)
  lines[#lines + 1] = string.format("No confident match: %d", #scan.no_match)
  lines[#lines + 1] = string.format("No title in the file: %d", scan.no_title or 0)
  if scan.errors > 0 then lines[#lines + 1] = string.format("Could not check: %d", scan.errors) end
  return table.concat(lines, "\n")
end

-- After linking: a Library sync, so the linked books' shelves are saved on the device and show
-- offline (linking saves only the Hardcover id, not the shelves). `download(status_id, opts)` is
-- the existing shelf download (Flows:downloadShelf); each shelf is asked about first (`check`) and
-- fetched only if it differs from the saved copy. Nothing to do when no book was linked.
-- Returns how many shelves were queued.
function BulkLink.syncShelves(scan, status_ids, download)
  if not scan or #scan.linked == 0 then return 0 end
  local queued = 0
  for _index, status_id in ipairs(status_ids or {}) do
    download(status_id, { check = true })
    queued = queued + 1
  end
  return queued
end

-- The books a details run should fetch for what a scan linked: `settings` shaped like the saved
-- per-book settings ({ [file] = { book_id =, edition_id = } }), which is what
-- DetailsSync.pending reads.
function BulkLink.linkedSettings(scan)
  local out = {}
  for _index, link in ipairs(scan.linked) do
    if link.file then out[link.file] = { book_id = link.book_id, edition_id = link.edition_id } end
  end
  return out
end

-- The words for the end of a scan.
function BulkLink.summary(scan)
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  add(scan.cancelled and "Linking stopped." or "Linking finished.")
  add(string.format("Linked: %d", #scan.linked))
  add(string.format("No match on Hardcover: %d", #scan.no_match))
  add(string.format("No Hardcover or ISBN identifier in the file: %d", scan.no_id))
  if scan.errors > 0 then add(string.format("Could not check: %d", scan.errors)) end
  if scan.cancelled and (scan.index < #scan.items or #scan.queue > 0) then
    add(string.format("Not checked yet: %d", #scan.items - scan.checked))
  end
  return table.concat(lines, "\n")
end

return BulkLink
