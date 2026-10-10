-- Is a Hardcover book on this device, and open it.
--
-- The plugin keeps a table of the files it has linked to a Hardcover book (hardcover_settings.lua,
-- "books": filename -> { book_id, ... }). That is the only record used: a book you have read with the
-- plugin, or linked from the reader. A book never opened on this device is not found (there is no
-- guessing from file names; "Find on device" is for that).

local OnDevice = {}

-- The file of the book `book_id` on this device, or nil. `books` is that table; `exists(file)` says
-- whether a file is still there (a moved or deleted book is skipped). Several files for one book:
-- the first in name order, so it is the same one every time.
function OnDevice.file(books, book_id, exists)
  if type(books) ~= "table" or not book_id then return nil end
  local found = {}
  for file, config in pairs(books) do
    if type(config) == "table" and config.book_id == book_id and exists(file) then
      found[#found + 1] = file
    end
  end
  table.sort(found)
  return found[1]
end

-- Open `file` in the reader: from the reader itself the current book is swapped, from the file
-- manager the reader is started.
function OnDevice.open(ui, file)
  local ReaderUI = require("apps/reader/readerui")
  if type(ui) == "table" and ui.document and type(ui.switchDocument) == "function" then
    ui:switchDocument(file)
  else
    ReaderUI:showReader(file)
  end
end

return OnDevice
