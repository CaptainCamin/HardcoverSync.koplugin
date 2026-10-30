-- Case-insensitive, on-device matching for the lists and books already saved here.
-- Every query word must occur somewhere in the supplied fields, so "Le Guin Earthsea"
-- can match a title and author together without depending on their order.

local Utf8Proc = require("ffi/utf8proc")

local LocalSearch = {}

function LocalSearch.matches(query, fields)
  if type(query) ~= "string" or not query:match("%S") then return true end

  local haystack = {}
  for _, field in pairs(fields or {}) do
    if type(field) == "string" and field ~= "" then
      haystack[#haystack + 1] = Utf8Proc.lowercase(field)
    end
  end
  local text = table.concat(haystack, " ")

  for word in Utf8Proc.lowercase(query):gmatch("%S+") do
    if not text:find(word, 1, true) then return false end
  end
  return true
end

return LocalSearch
