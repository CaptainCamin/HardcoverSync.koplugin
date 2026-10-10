-- What the home screen lists, as plain data.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite; the dialog
-- (ui/home_dialog.lua) only draws what this returns.

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Shelf = require("hardcover/lib/shelf")

local Home = {}

-- The shelves shown, in order: what you are in the middle of first.
local SHELF_ORDER = {
  HARDCOVER.STATUS.READING,
  HARDCOVER.STATUS.TO_READ,
  HARDCOVER.STATUS.FINISHED,
  HARDCOVER.STATUS.DNF,
}

function Home.statusIds()
  local ids = {}
  for i, id in ipairs(SHELF_ORDER) do ids[i] = id end
  return ids
end

--
-- One row per shelf. `counts` maps status id to how many books are on it; any
-- shelf missing from it (never loaded, or offline with nothing saved) gets no
-- count rather than a made up zero, because "0" says the shelf is empty.
--
function Home.rows(counts)
  counts = counts or {}
  local rows = {}
  for _, status_id in ipairs(SHELF_ORDER) do
    local count = tonumber(counts[status_id])
    rows[#rows + 1] = {
      status_id = status_id,
      title = Shelf.statusLabel(status_id),
      count = count,
    }
  end
  return rows
end

-- The shelves as the redesigned screens list them (mock 1 and 2): Want to read, Currently reading,
-- Read, Did not finish. A new table; `rows` is left as it is.
local LIST_ORDER = { HARDCOVER.STATUS.TO_READ, HARDCOVER.STATUS.READING, HARDCOVER.STATUS.FINISHED, HARDCOVER.STATUS.DNF }
function Home.listOrder(rows)
  local by_status = {}
  for _, row in ipairs(rows or {}) do by_status[row.status_id] = row end
  local out = {}
  for _, id in ipairs(LIST_ORDER) do
    if by_status[id] then out[#out + 1] = by_status[id] end
  end
  return out
end

-- The text shown at the right of a row.
function Home.countText(count)
  if type(count) ~= "number" then
    return ""
  end
  return string.format("%d", count)
end

--
-- The "Currently reading" cards, from the entries Api:getCurrentlyReading returns
-- (or the saved copy of them).
--
-- Each card carries what the dialog draws and nothing it has to work out:
-- `fraction` is how far through the book you are, clamped to 0..1, or nil when
-- the page count or the progress is unknown (the bar is then left out rather
-- than drawn empty, which would say "not started"). `progress_text` is
-- "p / pages"; with no progress yet only the page count is shown, and with
-- neither there is no text.
--
function Home.cards(entries)
  local cards = {}
  if type(entries) ~= "table" then
    return cards
  end

  for _, entry in ipairs(entries) do
    if type(entry) == "table" and entry.book_id then
      local current = tonumber(entry.progress_pages)
      local total = tonumber(entry.edition_pages) or tonumber(entry.pages)
      if total and total <= 0 then total = nil end
      if current and current < 0 then current = 0 end

      local fraction, text
      if current and total then
        fraction = math.min(1, math.max(0, current / total))
        text = string.format("%d / %d", current, total)
      elseif total then
        text = string.format("%d pages", total)
      end

      local image = entry.cached_image
      local cover_url
      if type(image) == "table" and type(image.url) == "string" and image.url ~= "" then
        cover_url = image.url
      end

      cards[#cards + 1] = {
        book_id = entry.book_id,
        title = entry.title or "Unknown title",
        author = entry.authors,
        cover_url = cover_url,
        current = current,
        total = total,
        fraction = fraction,
        progress_text = text,
      }
    end
  end

  return cards
end

-- Whether two reading lists would draw the same cards, so a refresh that brought
-- nothing new does not repaint the screen.
function Home.sameCards(a, b)
  local ca, cb = Home.cards(a), Home.cards(b)
  if #ca ~= #cb then return false end
  for i = 1, #ca do
    for _, key in ipairs({ "book_id", "title", "author", "cover_url", "current", "total" }) do
      if ca[i][key] ~= cb[i][key] then return false end
    end
  end
  return true
end

-- Whether two count tables hold the same numbers for these shelves.
function Home.sameCounts(a, b, ids)
  a, b = a or {}, b or {}
  for _, id in ipairs(ids or {}) do
    if tonumber(a[id]) ~= tonumber(b[id]) then return false end
  end
  return true
end

-- The label of a shelf button: "Name  \194\183  count", or just the name when the
-- count is unknown.
function Home.rowLabel(row)
  local count = Home.countText(row.count)
  if count == "" then
    return row.title
  end
  return row.title .. "  \194\183  " .. count
end

return Home
