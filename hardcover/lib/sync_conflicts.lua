-- The words for the "your progress differs from Hardcover" questions, kept
-- apart from the dialog so they can be tested without a screen.
--
-- Two kinds of question come out of the offline queue (see SyncQueue):
--   page    this device read to one page, Hardcover already holds a page well
--           past it (read on another device)
--   reread  Hardcover has the book as Read / Did Not Finish, but this device has
--           new progress: is the book being read again?

local _ = require("gettext")
local T = require("ffi/util").template

local HARDCOVER = require("hardcover/lib/constants/hardcover")

local SyncConflicts = {}

-- The book's name for a dialog: its title, else the file's name.
function SyncConflicts.title(filepath, entry)
  if type(entry) == "table" and type(entry.title) == "string" and entry.title ~= "" then
    return entry.title
  end
  local name = tostring(filepath or ""):match("([^/]+)$") or tostring(filepath or "")
  return (name:gsub("%.[%w]+$", ""))
end

function SyncConflicts.statusName(status_id)
  if status_id == HARDCOVER.STATUS.FINISHED then
    return _("Read")
  elseif status_id == HARDCOVER.STATUS.DNF then
    return _("Did not finish")
  end
  return _("not being read")
end

-- { title, rows = { { id, text }... } } for one conflict. The ids are what
-- SyncQueue:resolve takes, plus "later".
function SyncConflicts.describe(filepath, entry)
  local conflict = type(entry) == "table" and entry.conflict
  if not conflict then
    return nil
  end
  local name = SyncConflicts.title(filepath, entry)

  if conflict.kind == "reread" then
    return {
      title = T(_("%1\n\nHardcover has this as \"%2\", but you have read on to page %3 here.\n\nAre you re-reading it?"),
        name, SyncConflicts.statusName(conflict.cloud_status), conflict.local_page),
      rows = {
        { id = "yes", text = _("Yes, I'm re-reading it") },
        { id = "no", text = _("No, ignore this progress") },
        { id = "later", text = _("Decide later") },
      },
    }
  end

  return {
    title = T(_("%1\n\nThis device is at page %2, but Hardcover is at page %3.\n\nWhich should be kept?"),
      name, conflict.local_page, conflict.cloud_page),
    rows = {
      { id = "cloud", text = T(_("Use Hardcover (page %1)"), conflict.cloud_page) },
      { id = "local", text = T(_("Use this device (page %1)"), conflict.local_page) },
      { id = "later", text = _("Decide later") },
    },
  }
end

-- The menu row's words.
function SyncConflicts.menuText(count)
  return T(_("Resolve sync conflicts (%1)"), count)
end

-- What to say after a sync that left questions unanswered.
function SyncConflicts.notice(count)
  if count == 1 then
    return _("1 book needs your decision: Settings > Sync > Resolve sync conflicts.")
  end
  return T(_("%1 books need your decision: Settings > Sync > Resolve sync conflicts."), count)
end

-- A page a conversion from an edition page to a position in this file.
function SyncConflicts.documentPage(edition_page, edition_pages, document_pages)
  if not (edition_page and edition_pages and edition_pages > 0 and document_pages) then
    return nil
  end
  local page = math.floor(edition_page / edition_pages * document_pages + 0.5)
  return math.max(1, math.min(document_pages, page))
end

return SyncConflicts
