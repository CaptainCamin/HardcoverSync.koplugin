-- Hand a book to the Z-library plugin's search.
--
-- The Z-library plugin (ZlibraryKO/zlibrary.koplugin) is a separate plugin with
-- no public API. What it does have, and what this relies on:
--
--   * KOReader keeps every loaded plugin instance in the UI's array part
--     (FileManager:registerModule / ReaderUI:registerModule do table.insert),
--     so the instance can be found by what it can do rather than by the name it
--     registers under (which is translated).
--   * Zlibrary:performSearch(query) runs a search and shows the results,
--     signing in first if it has to; Zlibrary:showMultiSearchDialog(position,
--     text) opens its search screen with the text filled in.
--
-- Both are internals of that plugin, so everything here is defensive: when the
-- plugin is not installed, or a version of it no longer has these methods, the
-- feature reports that rather than raising.

local Zlibrary = {}

--
-- The search text for a book: its title, then its first author. A subtitle is
-- left off (it narrows a search to nothing as often as it helps), and so is a
-- series suffix. Authors arrive as the details' joined string ("A, B"): the
-- first is enough.
--
function Zlibrary.query(book)
  if type(book) ~= "table" then return nil end

  local title = type(book.title) == "string" and book.title or ""
  title = title:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if title == "" then return nil end

  local author = type(book.authors) == "string" and book.authors or ""
  author = author:match("^([^,]+)") or ""
  author = author:gsub("^%s+", ""):gsub("%s+$", "")

  if author ~= "" then
    return title .. " " .. author
  end
  return title
end

--
-- The Z-library plugin instance in this UI, or nil. `ui` is the FileManager or
-- ReaderUI.
--
function Zlibrary.find(ui)
  if type(ui) ~= "table" then return nil end

  for _, module in ipairs(ui) do
    if type(module) == "table"
        and type(module.performSearch) == "function"
        and type(module.showMultiSearchDialog) == "function" then
      return module
    end
  end
  return nil
end

function Zlibrary.available(ui)
  return Zlibrary.find(ui) ~= nil
end

--
-- Search for `book`. Returns true when the Z-library plugin took it, or nil and
-- a reason ("not_installed", "no_title", "failed") for the caller to show.
--
function Zlibrary.search(ui, book)
  local query = Zlibrary.query(book)
  if not query then
    return nil, "no_title"
  end

  local instance = Zlibrary.find(ui)
  if not instance then
    return nil, "not_installed"
  end

  local ok = pcall(instance.performSearch, instance, query)
  if ok then
    return true
  end

  -- an older or newer version without performSearch's shape: open its search
  -- screen with the text filled in instead
  ok = pcall(instance.showMultiSearchDialog, instance, nil, query)
  if ok then
    return true
  end

  return nil, "failed"
end

return Zlibrary
