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
    errors = 0,
  }
end

function BulkLink.total(scan)
  return #scan.items
end

function BulkLink.done(scan)
  return scan.cancelled or (scan.index >= #scan.items and #scan.queue == 0)
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
    elseif pcall(scan.deps.store, entry.file, BulkLink.linkConfig(book)) then
      scan.linked[#scan.linked + 1] = { name = nameOf(entry.file), matched = book.title }
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
    return false
  end
  scan.queue[#scan.queue + 1] = { file = file, parsed = parsed }
  return false
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
