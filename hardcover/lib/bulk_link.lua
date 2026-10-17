-- Link every book on the device to Hardcover in one pass.
--
-- Adapted from the "Auto-link all books" scan in Bookshelf
-- (https://github.com/AndyHazz/bookshelf.koplugin, AGPL-3.0, lib/bookshelf_settings.lua and
-- lib/bookshelf_hardcover.lua): the way it reads an EPUB's embedded ISBN / Hardcover
-- identifiers from the OPF, and its paced, cancellable, one-book-per-tick scan with a report
-- at the end. The second pass is adapted from Bookshelf's "best guess" mode: for books with no
-- usable identifier, a title-and-author search on Hardcover. Ours is stricter (a guess must match
-- the title exactly once subtitles and punctuation are ignored, and the author's name), and
-- every guessed link is marked in the book's settings (`guessed_book_id`) so it can be reviewed
-- and undone.
--
-- Everything that touches KOReader or the network is passed in, so the scan can be driven
-- from a spec: `lookup` finds the Hardcover book for parsed identifiers, `read_identifiers`
-- reads a file's identifiers, `store` writes the link, `is_linked` says a book already is.

local Book = require("hardcover/lib/book")

local BulkLink = {}

-- Seconds between books. Each one costs one or two Hardcover calls and the API allows 60 a
-- minute.
BulkLink.RATE = 2.5

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
  if lower:match("^hardcover[%w_-]*:") or lower:match("^isbn[%w_-]*:") then
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

-- A scan over `items`. `deps` is { read_identifiers, lookup, store }. Call `BulkLink.step` once
-- per tick; it says whether it used the network (so the caller can wait before the next one).
function BulkLink.new(items, deps)
  return {
    items = items,
    deps = deps,
    index = 0,
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
  return scan.cancelled or scan.index >= #scan.items
end

local function nameOf(file)
  return (file:match("([^/]+)$") or file):gsub("%.[^%.]+$", "")
end

-- Handle the next book. Returns true when it called Hardcover.
function BulkLink.step(scan)
  if BulkLink.done(scan) then return false end
  scan.index = scan.index + 1
  local file = scan.items[scan.index]
  local deps = scan.deps

  local ok_read, identifiers = pcall(deps.read_identifiers, file)
  if not ok_read then
    scan.errors = scan.errors + 1
    return false
  end
  local parsed = identifiers and Book:parseIdentifiers(identifiers) or {}
  if not (parsed.isbn_13 or parsed.isbn_10 or parsed.book_slug or parsed.edition_id) then
    scan.no_id = scan.no_id + 1
    scan.unmatched[#scan.unmatched + 1] = file
    return false
  end

  -- `lookup` gives the book, nil when Hardcover has no such book, or nil and an error when the
  -- call itself failed (offline, rate limit, expired token): that is not "no match".
  local ok_lookup, book, lookup_error = pcall(deps.lookup, parsed)
  if not ok_lookup or (not book and lookup_error) then
    scan.errors = scan.errors + 1
    return true
  end
  if not (book and book.book_id) then
    scan.no_match[#scan.no_match + 1] = { name = nameOf(file) }
    scan.unmatched[#scan.unmatched + 1] = file
    return true
  end

  local ok_store = pcall(deps.store, file, BulkLink.linkConfig(book))
  if ok_store then
    scan.linked[#scan.linked + 1] = { name = nameOf(file), matched = book.title }
  else
    scan.errors = scan.errors + 1
  end
  return true
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

-- A scan that guesses for `items` (files). `deps` is { read_metadata, search, store }:
-- `read_metadata(file)` gives { title, author } or nil, `search(title, author)` gives Hardcover's
-- results (nil when the call failed), `store(file, config)` writes the link.
function BulkLink.newGuess(items, deps)
  local scan = BulkLink.new(items, deps)
  scan.guess = true
  scan.no_title = 0
  return scan
end

-- Handle the next book of a guess scan. Returns true when it called Hardcover.
function BulkLink.stepGuess(scan)
  if BulkLink.done(scan) then return false end
  scan.index = scan.index + 1
  local file = scan.items[scan.index]
  local deps = scan.deps

  local ok_read, meta = pcall(deps.read_metadata, file)
  if not ok_read then
    scan.errors = scan.errors + 1
    return false
  end
  if not (meta and meta.title and normalize(meta.title) ~= "") then
    scan.no_title = scan.no_title + 1
    return false
  end

  local ok_search, results = pcall(deps.search, meta.title, meta.author)
  if not ok_search or results == nil then
    scan.errors = scan.errors + 1
    return true
  end
  local book = BulkLink.pickGuess(results, meta.title, meta.author)
  if not book then
    scan.no_match[#scan.no_match + 1] = { name = nameOf(file) }
    return true
  end

  local config = BulkLink.linkConfig(book)
  config.guessed_book_id = book.book_id
  if pcall(deps.store, file, config) then
    scan.linked[#scan.linked + 1] = { name = nameOf(file), matched = book.title,
      authors = table.concat(authorNames(book), ", ") }
  else
    scan.errors = scan.errors + 1
  end
  return true
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
-- the existing shelf download (Flows:downloadShelf); each shelf is asked about first (`check`)
-- and fetched only if it differs from the saved copy. Nothing to do when no book was linked.
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

-- The words for the end of a scan.
function BulkLink.summary(scan)
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  add(scan.cancelled and "Linking stopped." or "Linking finished.")
  add(string.format("Linked: %d", #scan.linked))
  add(string.format("No match on Hardcover: %d", #scan.no_match))
  add(string.format("No Hardcover or ISBN identifier in the file: %d", scan.no_id))
  if scan.errors > 0 then add(string.format("Could not check: %d", scan.errors)) end
  if #scan.linked > 0 then add("Saving their shelves on this device.") end
  return table.concat(lines, "\n")
end

return BulkLink
