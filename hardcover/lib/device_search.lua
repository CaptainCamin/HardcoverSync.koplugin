-- Look for a book among the files on the device.
--
-- KOReader's own file search (FileManagerFileSearcher) is a module of both the
-- FileManager and the reader, registered as `ui.filesearcher`; `onShowFileSearch(text)`
-- opens its search box with the text filled in, and the reader picks the folder. No
-- Hardcover-side data is involved, so this is plain data plus one call.

local DeviceSearch = {}

--
-- What to search the file names for: the book's title, without a subtitle ("Dune:
-- Deluxe Edition" -> "Dune") or a series suffix in brackets, since file names rarely
-- carry those and a longer text finds less. The author is left out for the same reason.
--
function DeviceSearch.query(book)
  if type(book) ~= "table" or type(book.title) ~= "string" then return nil end
  local title = book.title:gsub("%s+", " ")
  local head = title:match("^([^:%(%[]+)")
  if head and head:find("%S") then title = head end
  title = title:gsub("^%s+", ""):gsub("%s+$", "")
  if title == "" then return nil end
  return title
end

-- The file searcher of this UI (the FileManager or the reader), or nil.
function DeviceSearch.find(ui)
  local searcher = type(ui) == "table" and ui.filesearcher
  if type(searcher) == "table" and type(searcher.onShowFileSearch) == "function" then
    return searcher
  end
  return nil
end

function DeviceSearch.available(ui)
  return DeviceSearch.find(ui) ~= nil
end

-- Open the search for `book`. Returns true, or nil and a reason ("not_available",
-- "no_title", "failed") for the caller to show.
function DeviceSearch.search(ui, book)
  local query = DeviceSearch.query(book)
  if not query then return nil, "no_title" end

  local searcher = DeviceSearch.find(ui)
  if not searcher then return nil, "not_available" end

  if pcall(searcher.onShowFileSearch, searcher, query) then
    return true
  end
  return nil, "failed"
end

return DeviceSearch
