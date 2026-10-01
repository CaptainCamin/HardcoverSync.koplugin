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

-- The text shown at the right of a row.
function Home.countText(count)
  if type(count) ~= "number" then
    return ""
  end
  return string.format("%d", count)
end

return Home
