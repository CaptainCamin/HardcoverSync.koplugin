-- The "Hardcover details" button in the file manager's long-press dialog
-- (lib/file_dialog.lua), which Bookshelf also lists under Plugin actions.
--
-- Run with:  lua spec/file_dialog_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()

local closed = {}
package.preload["ui/uimanager"] = function()
  return { close = function(_, w) closed[#closed + 1] = w end, show = function() end }
end

local file_dialog = { name = "stock file dialog" }
local FileManager = {
  instance = { file_dialog = file_dialog },
  registered = {}, removed = {},
}
function FileManager:addFileDialogButtons(id, fn) self.registered[id] = fn end
function FileManager:removeFileDialogButtons(id) self.removed[#self.removed + 1] = id end
package.preload["apps/filemanager/filemanager"] = function() return FileManager end

local FileDialog = require("hardcover/lib/file_dialog")

local shown
local books = { ["/b/linked.epub"] = { book_id = 7, edition_id = 70 } }
local app = {
  settings = { readBookSetting = function(_, f, k) return books[f] and books[f][k] end },
  dialog_manager = { showBookDetail = function(_, ...) shown = { ... } end },
}

r.check("registers on the file manager", FileDialog.register(app) == true and FileManager.registered.hardcover_sync ~= nil)
r.check("a repeat registration replaces the first", (function()
  FileDialog.register(app)
  return FileManager.removed[#FileManager.removed] == "hardcover_sync"
end)())

local build = FileManager.registered.hardcover_sync
r.check("no button for an unlinked book", build("/b/other.epub", true) == nil)
r.check("no button for a folder", build("/b/linked.epub", false) == nil)

local row = build("/b/linked.epub", true)
r.check("a linked book gets one button", row and #row == 1 and row[1].text == "Hardcover details")
row[1].callback()
r.check("it opens that book's details with its edition", shown and shown[1] == 7 and shown[2] == 70)
r.check("it closes the stock file dialog", closed[1] == file_dialog)

FileManager.instance = nil
closed, shown = {}, nil
build("/b/linked.epub", true)[1].callback()
r.check("without a file dialog (Bookshelf) it still opens the details", shown and shown[1] == 7 and #closed == 0)

FileManager.addFileDialogButtons = nil
r.check("an older KOReader without the hook is skipped", FileDialog.register(app) == false)

r.finish()
