-- Link every book on the device to Hardcover in one pass.
--
-- Adapted from the "Auto-link all books" scan in Bookshelf
-- (https://github.com/AndyHazz/bookshelf.koplugin, AGPL-3.0, lib/bookshelf_settings.lua and
-- lib/bookshelf_hardcover.lua): the way it reads an EPUB's embedded ISBN / Hardcover
-- identifiers from the OPF, and its paced, cancellable, one-book-per-tick scan with a report
-- at the end. Only the exact-match mode is carried over (an embedded identifier); there is no
-- title-and-author guess.
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
  -- A Hardcover reference written anywhere else in the package (a meta tag, a comment).
  for token in opf:gmatch("[Hh][Aa][Rr][Dd][Cc][Oo][Vv][Ee][Rr][%w_-]*%s*:%s*[%w_-]+") do
    add((token:gsub("%s*:%s*", ":")))
  end
  return #tokens > 0 and table.concat(tokens, "\n") or nil
end

-- The identifiers inside an EPUB, read by the system `unzip`. nil for any other format, a book
-- without an OPF, or a device without unzip.
function BulkLink.readEpubIdentifiers(filepath, popen)
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
  return BulkLink.identifiersFromOpf(table.concat(chunks, "\n"))
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
    return false
  end

  local ok_lookup, book = pcall(deps.lookup, parsed)
  if not ok_lookup then
    scan.errors = scan.errors + 1
    return true
  end
  if not (book and book.book_id) then
    scan.no_match[#scan.no_match + 1] = { name = nameOf(file) }
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
