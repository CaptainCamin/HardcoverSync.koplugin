local Book = {}
local reading_format_labels = {
  "Physical Book",
  "Audiobook",
  nil,
  "E-Book"
}

-- Server ids are numbers; an unsent addition is named local:N until Hardcover answers. Order
-- them without turning the local name into nil (the form needs it to replace the addition in
-- place), and without comparing a number with a string.
function Book.readIdOrder(id)
  local numeric = tonumber(id)
  if numeric then return numeric end
  local local_seq = type(id) == "string" and tonumber(id:match("^local:(%d+)$")) or nil
  return local_seq and (1000000000 + local_seq) or 0
end

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
  if unfinished then return unfinished end
  -- Every read is finished. The newest read is the latest finish, not necessarily the highest
  -- id: adding a past read gives it a new id but an older finish date.
  local latest = reads[#reads]
  for _, read in ipairs(reads) do
    local read_date, latest_date = read.finished_at or "", latest.finished_at or ""
    if read_date > latest_date
      or (read_date == latest_date and Book.readIdOrder(read.id) > Book.readIdOrder(latest.id)) then
      latest = read
    end
  end
  return latest
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
