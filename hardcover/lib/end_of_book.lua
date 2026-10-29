-- What the plugin does when a book ends, as plain decisions with no KOReader in them.
--
-- KOReader chooses what happens at the end of a book with one setting, "end_document_action".
-- Its own values are listed below; another plugin can add a value of its own (ZenOS adds
-- "zen_end_book"), and so does this one (EndOfBook.ACTION). Only one value is selected at a time,
-- so two end pages never show together.
--
--   "builtin"    KOReader's own: pop-up (the default when nothing is saved), book status, mark as
--                finished, do nothing, ...
--   "hardcover"  this plugin's end page
--   "custom"     any other value: another plugin's end page, which this plugin leaves alone

local EndOfBook = {}

EndOfBook.ACTION = "hardcover_end"

local BUILT_IN = {
  ["pop-up"] = true,
  nothing = true,
  book_status = true,
  book_status_file_browser = true,
  delete_file = true,
  next_file = true,
  goto_beginning = true,
  file_browser = true,
  mark_read = true,
}

function EndOfBook.kind(action)
  if action == nil or BUILT_IN[action] then return "builtin" end
  if action == EndOfBook.ACTION then return "hardcover" end
  return "custom"
end

-- What the end event asks for.
--   `auto_mark`  KOReader's "Always mark as finished", or this plugin's own setting of the same name
--   "mark"         write Read now
--   "check_later"  KOReader's pop-up is on screen: look at the book's saved status after the
--                  reader has answered it
--   "none"         nothing to write; a book-status screen is watched by the hook on its closing
function EndOfBook.onEnd(action, auto_mark)
  action = action or "pop-up"
  if auto_mark or action == "mark_read" then return "mark" end
  if action == "pop-up" then return "check_later" end
  return "none"
end

-- Whether landing on the last page asks "Mark as Read?". `setting` is the reader's choice (nil when
-- they have not made one). Left alone it is on for KOReader's own end actions and off when an end
-- page, this plugin's or another's, is selected: that page already does the asking.
function EndOfBook.promptOnLastPage(setting, action)
  if setting ~= nil then return setting == true end
  return EndOfBook.kind(action) == "builtin"
end

function EndOfBook.atLastPage(page, page_count)
  page, page_count = tonumber(page), tonumber(page_count)
  return page ~= nil and page_count ~= nil and page_count > 0 and page >= page_count
end

-- True the first time `key` is seen in `seen`, false after: one prompt per book per session, whichever
-- trigger gets there first.
function EndOfBook.once(seen, key)
  if seen[key] then return false end
  seen[key] = true
  return true
end

-- Forget that `key` was handled, so a book started again can end (and ask) once more.
function EndOfBook.forget(seen, key)
  seen[key] = nil
end

return EndOfBook
