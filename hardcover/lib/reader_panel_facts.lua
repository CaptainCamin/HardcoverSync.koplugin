-- What the reader panel says about the book, decided apart from the widgets so it can be tested:
-- the page or length line, the shelf line, whether the progress switch is offered and what is
-- written under it. Pure: no KOReader, no settings, no network.
--
--   describe { linked, status_id, not_on_shelf, saved_page, pages, sync_on, status_label, start_pages }
--     -> { line, shelf, finished, track, track_note, hint }   (each nil when there is nothing true to say)
--
-- line:       directly under the title, in every state. "Page 120 of 387 · 31%" while the book is
--             being read or has a saved page, otherwise how long it is ("387 pages"); nothing when
--             the length is not known. A book that is not linked says so here.
-- shelf:      where the book is, in words. Not said for Currently Reading: the reader is in that
--             book, and the page line already says how far.
-- paused:     Paused: the panel offers "Resume" beside the shelf line.
-- finished:   Finished or Did not finish: the panel offers "Read again" beside the shelf line.
-- track:      the "Update Hardcover as I read" switch is offered: for a book being read, and for any
--             other linked book while tracking is off (so it can always be turned back on). A book
--             that is not being read is not tracked (reading it asks to start it), so a switch there
--             would promise what does not happen.
--             The rule is BookActions.offerTrackSwitch.
-- track_note: under the switch, only while it is off and the book is Want to Read or on no shelf:
--             "Change status to update progress." (the way to update it by hand).
-- hint:       where the switch is not shown (tracking on, book Want to Read, on no shelf, or shelf not
--             checked yet; reading each of them asks to start it), what
--             reading will do: "After 5 pages you'll be asked to start reading." `start_pages` is the
--             threshold setting (5 when not given).

local _ = require("gettext")
local BookActions = require("hardcover/lib/book_actions")
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
  out.status = o.status_label or (o.not_on_shelf and _("Not on a shelf") or _("Shelf not checked yet"))
  if status_id == HARDCOVER.STATUS.FINISHED then
    out.message, out.action = _("You finished this book."), "reread"
  elseif status_id == HARDCOVER.STATUS.DNF then
    out.message, out.action = _("You didn't finish this book."), "restart"
  elseif out.paused then
    out.message, out.action = _("You paused this book."), "resume"
  elseif status_id == HARDCOVER.STATUS.TO_READ then
    out.message, out.action = _("Ready to start this book?"), "start"
  elseif o.not_on_shelf then
    out.message, out.action = _("This book isn't on a shelf yet."), "shelf"
  end

  local pages = tonumber(o.pages)
  if pages and pages > 0 then
    local saved = tonumber(o.saved_page)
    if reading or (saved and saved > 0) then
      local page = saved or 0
      out.progress = math.max(0, math.min(1, page / pages))
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

  out.track = BookActions.offerTrackSwitch(status_id, o.sync_on)
  if out.track and not o.sync_on
      and (status_id == HARDCOVER.STATUS.TO_READ or (status_id == nil and o.not_on_shelf)) then
    out.track_note = _("Change status to update progress.")
  end
  if not out.track and (status_id == HARDCOVER.STATUS.TO_READ or status_id == nil) then
    local n = tonumber(o.start_pages) or 5
    out.hint = n == 1 and _("After 1 page you'll be asked to start reading.")
      or fill(_("After %1 pages you'll be asked to start reading."), n)
  end
  return out
end

return Facts
