-- The book and edition pickers: "Select book" (linking a book) and "Select edition". A list to choose one
-- row from, on the same screen as the shelves and search results (shelf_dialog.lua), so there is one
-- look. A tap picks the row and closes the picker; the search field under the bar searches again in
-- place; the row already chosen has a filled radio.
--
-- The callers (dialog_manager, hardcover.lua, the journal's edition button) use this as a plain list:
-- setItems, setEmptyState, onClose, and the two callbacks. The row handed to select_book_cb is the
-- ListRow row they have always read (book_id, edition_id, edition_format, pages, title, ...).

local InputDialog = require("hardcover/lib/ui/components/input_dialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local ListRow = require("hardcover/lib/ui/list_row")
local ShelfDialog = require("hardcover/lib/ui/shelf_dialog")

-- (the title is the class's own: ShelfDialog's default is the Want to Read shelf's)
local HardcoverSearchDialog = ShelfDialog:extend {
  title = _("Select book"),
  active_item = nil,
  search_value = nil,
  select_book_cb = nil,
  search_callback = nil,
}

function HardcoverSearchDialog:init()
  -- the callers pass their rows as `items`; the shelf screen keeps them as `entries`
  self.entries = self.items or {}
  self.items = nil
  self.search = self:searchStrip()
  self.select_entry_cb = function(entry)
    if self.select_book_cb then
      self.select_book_cb(self:createListItem(entry))
    end
  end
  ShelfDialog.init(self)
end

-- A row of the picker: the title with its year, and under it the author. On the edition picker the second
-- line is the format and pages instead, since the author is the same for every edition. The chosen row is
-- marked. (Decided by the picker, not by the row: the link-book lookup can return an edition too.)
function HardcoverSearchDialog:createListItem(book)
  local row = ListRow.row(book, { compatibility_mode = false })
  row.chooser = true
  row.current = ListRow.isActive(row, self.active_item)
  if self.edition_rows then
    local parts = {}
    if row.filetype then parts[#parts + 1] = row.filetype end
    if row.pages then parts[#parts + 1] = string.format(_("%d pages"), row.pages) end
    row.detail = #parts > 0 and table.concat(parts, " \194\183 ") or nil
  end
  return row
end

-- The search field under the bar: what was searched for, and a tap to search again. There is no clear
-- X: a picker has to end with a choice, so clearing the words would only leave an empty list.
function HardcoverSearchDialog:searchStrip()
  if not self.search_callback then return nil end
  return {
    query = self.search_value,
    placeholder = _("Title or author"),
    on_edit = function(query) self:promptSearch(query) end,
  }
end

-- The keyboard box for a new search. Its Search button hands the words to search_callback, which
-- returns true once the results are on their way, and the box then closes.
function HardcoverSearchDialog:promptSearch(initial)
  local search_dialog
  search_dialog = InputDialog:new {
    title = _("New search"),
    input = initial or self.search_value,
    buttons = {
      {
        label = _("Cancel"),
        callback = function()
          UIManager:close(search_dialog)
        end,
      },
      {
        label = _("Search"),
        primary = true, -- also what Enter runs
        callback = function()
          local result = self.search_callback(search_dialog:getInputText())
          if result then
            UIManager:close(search_dialog)
          end
        end,
      }
    }
  }

  UIManager:show(search_dialog)
  search_dialog:onShowKeyboard()
end

-- A new list for the picker: its rows, the chosen one marked, and the search field showing the words
-- the rows came from. The caller sets search_value first (see DialogManager:updateSearchResults).
-- No rows is an answer, so it is said where the rows would be, not left as a blank list.
function HardcoverSearchDialog:setItems(title, items, active_item)
  self.title = title or self.title
  self.active_item = active_item
  self.search = self:searchStrip()
  if not items or #items == 0 then
    self:setEmptyState(_("No results"))
    return
  end
  self:setEntries(items)
end

return HardcoverSearchDialog
