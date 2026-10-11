-- Hand a book to whichever book-download plugin the reader has chosen.
--
-- Three separate plugins are supported, none of which has a public API, so each
-- is found by what its instance can do (KOReader keeps every loaded plugin in
-- the UI's array part, and the name it registers under is translated):
--
--   zlibrary  ZlibraryKO/zlibrary.koplugin       performSearch(query) + showMultiSearchDialog(pos, text)
--   annas     fischer-hub/annas.koplugin         performSearch(query) + displaySearchResults + downloadBook
--   kindlefetch  william-spongberg/KindleFetch.koplugin   searchFrom(query, page) + searchInBackground
--
-- Everything is defensive: a missing plugin, or a version without these methods,
-- is reported rather than raised. This plugin never downloads anything itself.

local Zlibrary = require("hardcover/lib/zlibrary")

local BookSources = {}

BookSources.AUTO = "auto"

local function isFn(module, name) return type(module[name]) == "function" end

-- In the order "auto" tries them.
BookSources.SOURCES = {
  {
    id = "zlibrary",
    label = "Z-library",
    matches = function(m) return isFn(m, "performSearch") and isFn(m, "showMultiSearchDialog") end,
    run = function(instance, query)
      if pcall(instance.performSearch, instance, query) then return true end
      -- a version without performSearch's shape: its search screen with the text filled in
      return pcall(instance.showMultiSearchDialog, instance, nil, query)
    end,
  },
  {
    id = "annas",
    label = "Anna's Archive",
    matches = function(m)
      return isFn(m, "performSearch") and isFn(m, "displaySearchResults") and isFn(m, "downloadBook")
        and not isFn(m, "showMultiSearchDialog")
    end,
    run = function(instance, query) return pcall(instance.performSearch, instance, query) end,
  },
  {
    id = "kindlefetch",
    label = "Kindle Fetch",
    matches = function(m) return isFn(m, "searchFrom") and isFn(m, "searchInBackground") end,
    run = function(instance, query) return pcall(instance.searchFrom, instance, query, 1) end,
  },
}

local function sourceById(id)
  for _, source in ipairs(BookSources.SOURCES) do
    if source.id == id then return source end
  end
end

-- The plugin instance for one source in this UI (the FileManager or ReaderUI), or nil.
function BookSources.find(ui, id)
  local source = sourceById(id)
  if not source or type(ui) ~= "table" then return nil end
  for _, module in ipairs(ui) do
    if type(module) == "table" and source.matches(module) then return module end
  end
  return nil
end

function BookSources.installed(ui, id)
  return BookSources.find(ui, id) ~= nil
end

--
-- The source to use for `choice` (a source id, "auto" or nil): the chosen one
-- when it is installed, else for "auto" the first installed one. Returns the
-- source and its instance, or nil.
--
function BookSources.resolve(ui, choice)
  if choice and choice ~= BookSources.AUTO then
    local source = sourceById(choice)
    local instance = source and BookSources.find(ui, choice)
    if instance then return source, instance end
    return nil
  end
  for _, source in ipairs(BookSources.SOURCES) do
    local instance = BookSources.find(ui, source.id)
    if instance then return source, instance end
  end
  return nil
end

function BookSources.available(ui, choice)
  return BookSources.resolve(ui, choice) ~= nil
end

-- What the button says: the source that would run, else the name of the choice.
function BookSources.label(ui, choice)
  local source = BookSources.resolve(ui, choice)
  if source then return source.label end
  source = sourceById(choice)
  return source and source.label or BookSources.SOURCES[1].label
end

--
-- Search for `book`. Returns true when the plugin took it, or nil and a reason
-- ("not_installed", "no_title", "failed") plus the source label for the message.
--
function BookSources.search(ui, book, choice)
  local query = Zlibrary.query(book)
  local source, instance = BookSources.resolve(ui, choice)
  local label = source and source.label or BookSources.label(ui, choice)
  if not query then return nil, "no_title", label end
  if not source then return nil, "not_installed", label end
  if source.run(instance, query) then return true, nil, label end
  return nil, "failed", label
end

return BookSources
