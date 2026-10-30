local Book = {}
local reading_format_labels = {
  "Physical Book",
  "Audiobook",
  nil,
  "E-Book"
}

-- Reads arrive oldest first. An explicitly recorded page 0 is progress too: it
-- distinguishes a restarted read from Hardcover's newly created empty read.
function Book:currentRead(reads)
  if type(reads) ~= "table" then return nil end
  local unfinished
  for i = #reads, 1, -1 do
    local read = reads[i]
    if not read.finished_at then
      unfinished = unfinished or read
      if tonumber(read.progress_pages) ~= nil then return read end
    end
  end
  return unfinished or reads[#reads]
end

function Book:readingFormat(format_id)
  if not format_id then
    return
  end

  return reading_format_labels[format_id]
end

function Book:editionFormatName(edition_format, format_id)
  if edition_format and edition_format ~= "" then
    return edition_format
  end

  return self:readingFormat(format_id)
end

function Book:parseIdentifiers(identifiers)
  local result = {}

  if not identifiers then
    return result
  end

  for line in string.lower(identifiers):gmatch("%s*([^%s]+)%s*") do
    -- check for hardcover:, hardcover-slug: and hardcover-edition:
    local hc = string.match(line, "hardcover:([%w_-]+)") or string.match(line, "hardcover%-slug:([%w_-]+)")
    if hc then
      result.book_slug = hc
    end

    local hc_edition = string.match(line, "hardcover%-edition:(%d+)")

    if hc_edition then
      result.edition_id = hc_edition
    end

    if not hc and not hc_edition then
      -- strip prefix
      local str = string.gsub(line, "^[^%s]+%s*:%s*", "")
      str = string.gsub(str, "-", "")

      -- an ISBN-10 may end in the check digit X
      if str and (string.find(str, "^%d+$") or string.find(str, "^%d%d%d%d%d%d%d%d%d[xX]$")) then
        str = string.upper(str)
        local len = #str

        if len == 13 then
          result.isbn_13 = str
        elseif len == 10 then
          result.isbn_10 = str
        end
      end
    end
  end
  return result
end

return Book
