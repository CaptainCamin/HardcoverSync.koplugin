-- A "Hardcover details" button in the file manager's long-press dialog for a
-- book linked to Hardcover.
--
-- KOReader's FileManager:addFileDialogButtons is the standard hook, and
-- Bookshelf builds its per-book "Plugin actions" from the same list, so one
-- registration serves both.

local _ = require("gettext")
local logger = require("logger")
local UIManager = require("ui/uimanager")

local FileDialog = {}

local ID = "hardcover_sync"

-- The row for one file, or nil when it is not a linked book. Called as
-- row_func(file, is_file, book_props) every time the dialog opens.
function FileDialog.row(app, file, is_file)
  if not (is_file and file and app.settings and app.dialog_manager) then return nil end
  local book_id = app.settings:readBookSetting(file, "book_id")
  if not book_id then return nil end
  local edition_id = app.settings:readBookSetting(file, "edition_id")
  return {
    {
      text = _("Hardcover details"),
      callback = function()
        -- the stock file dialog stays open under a new screen; Bookshelf's has none to close
        local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
        local dialog = ok_fm and FileManager and FileManager.instance and FileManager.instance.file_dialog
        if dialog then UIManager:close(dialog) end
        app.dialog_manager:showBookDetail(book_id, edition_id)
      end,
    },
  }
end

-- Returns whether the hook was there to register on.
function FileDialog.register(app)
  local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
  if not (ok and FileManager and FileManager.addFileDialogButtons) then
    return false
  end
  -- a second plugin instance (file manager, then reader) must not stack a second button
  if FileManager.removeFileDialogButtons then
    pcall(FileManager.removeFileDialogButtons, FileManager, ID)
  end
  local added, err = pcall(FileManager.addFileDialogButtons, FileManager, ID, function(file, is_file)
    return FileDialog.row(app, file, is_file)
  end)
  if not added then
    logger.warn("Hardcover file dialog button not added:", tostring(err))
  end
  return added
end

return FileDialog
