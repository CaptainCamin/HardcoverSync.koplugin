-- Pure helpers for the Home screen's book search (no widgets).

local BookSearch = {}

-- Hardcover's search returns 25 books a page and this plugin asks for the first
-- page only: a request costs one search plus one hydrate query, and the rate
-- limit is 60 a minute.
BookSearch.MAX_RESULTS = 25

-- The text to search for, or nil when there is nothing to search: nothing typed,
-- or only spaces. Nil means no request is made at all.
function BookSearch.normalize(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  return text
end

-- At most MAX_RESULTS books, in the order they came back.
function BookSearch.cap(books)
  local out = {}
  for i, book in ipairs(books or {}) do
    if i > BookSearch.MAX_RESULTS then break end
    out[#out + 1] = book
  end
  return out
end

-- The results screen's title.
function BookSearch.title(query)
  return "\"" .. tostring(query) .. "\""
end

return BookSearch
