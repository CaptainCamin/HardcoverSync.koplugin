-- What the reader panel says about the book, decided apart from the widgets so it can be tested:
-- the page or length line and the shelf line. Pure: no KOReader, no settings, no network.
--
--   describe { linked, status_id, not_on_shelf, saved_page, pages, status_label }
--     -> { line, shelf, paused, finished }   (each nil when there is nothing true to say)
--
-- line:       directly under the title, in every state. "Page 120 of 387 · 31%" while the book is
--             being read or has a saved page, otherwise how long it is ("387 pages"); nothing when
--             the length is not known. A book that is not linked says so here.
-- shelf:      where the book is, in words. Not said for Currently Reading: the reader is in that
--             book, and the page line already says how far.
-- paused:     Paused: the panel offers "Resume" beside the shelf line.
-- finished:   Finished or Did not finish: the panel offers "Read again" beside the shelf line.

local _ = require("gettext")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local Facts = {}

local function fill(text, ...)
  local args = { ... }
  return (text:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

-- Where the saved shelves put a book, for when nothing better is known (offline, a book never synced
-- from here): its shelf's status id, or not_on_shelf = true once every shelf in `status_ids` is saved
-- whole and none holds it. Both nil when the shelves cannot say (the panel then says "not checked").
function Facts.fromShelves(shelves, user_id, book_id, status_ids)
  if not (shelves and book_id) then return nil, nil end
  local m = shelves:member(user_id, book_id)
  if m and m.status_id then return m.status_id, nil end
  if shelves:synced(user_id, status_ids) then return nil, true end
  return nil, nil
end

function Facts.describe(o)
  local out = {}
  if not o.linked then
    out.line = _("Not linked to Hardcover")
    return out
  end

  local status_id = o.status_id
  local reading = status_id == HARDCOVER.STATUS.READING
  out.paused = status_id == HARDCOVER.STATUS.PAUSED
  out.finished = status_id == HARDCOVER.STATUS.FINISHED or status_id == HARDCOVER.STATUS.DNF

  local pages = tonumber(o.pages)
  if pages and pages > 0 then
    local saved = tonumber(o.saved_page)
    if reading or (saved and saved > 0) then
      local page = saved or 0
      out.line = fill(_("Page %1 of %2"), page, pages)
        .. "  \194\183  " .. fill(_("%1%"), math.floor(100 * page / pages + 0.5))
    elseif pages == 1 then
      out.line = _("1 page")
    else
      out.line = fill(_("%1 pages"), pages)
    end
  end

  if reading then
    out.shelf = nil
  elseif status_id then
    out.shelf = fill(_("On your '%1' shelf"), o.status_label)
  elseif o.not_on_shelf then
    out.shelf = _("Not on a shelf")
  else
    out.shelf = _("Shelf not checked yet")
  end

  return out
end

return Facts
