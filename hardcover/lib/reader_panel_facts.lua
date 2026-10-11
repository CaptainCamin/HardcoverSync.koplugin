-- What the reader panel says about the book, decided apart from the widgets so it can be tested:
-- the page or length line, the shelf line, whether the progress switch is offered and what is
-- written under it. Pure: no KOReader, no settings, no network.
--
--   describe { linked, status_id, not_on_shelf, saved_page, pages, sync_on, status_label }
--     -> { line, shelf, finished, track, track_note }   (each nil when there is nothing true to say)
--
-- line:       directly under the title, in every state. "Page 120 of 387 · 31%" while the book is
--             being read or has a saved page, otherwise how long it is ("387 pages"); nothing when
--             the length is not known. A book that is not linked says so here.
-- shelf:      where the book is, in words. Not said for Currently Reading: the reader is in that
--             book, and the page line already says how far.
-- finished:   Finished or Did not finish: the panel offers "Read again" beside the shelf line.
-- track:      the "Update Hardcover as I read" switch is offered (a linked book that is not finished).
-- track_note: under the switch, only for Want to Read and a book on no shelf (where reading moves it),
--             "Keep reading to update progress." with the switch on, "Change status to update progress."
--             with it off (the way to update it by hand).

local _ = require("gettext")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local Facts = {}

local function fill(text, ...)
  local args = { ... }
  return (text:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

function Facts.describe(o)
  local out = {}
  if not o.linked then
    out.line = _("Not linked to Hardcover")
    return out
  end

  local status_id = o.status_id
  local reading = status_id == HARDCOVER.STATUS.READING
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

  out.track = not out.finished
  if status_id == HARDCOVER.STATUS.TO_READ or (status_id == nil and o.not_on_shelf) then
    out.track_note = o.sync_on and _("Keep reading to update progress.")
      or _("Change status to update progress.")
  end
  return out
end

return Facts
