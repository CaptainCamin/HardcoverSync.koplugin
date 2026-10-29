-- Two small hooks into KOReader, installed once per process. Each is guarded, so a KOReader that
-- changed the thing hooked loses the feature and nothing else.
--
--   * Closing the book-status screen sends "HardcoverStatusScreenClosed". The screen's
--     Reading / On hold / Finished switch only edits the book's saved summary and sends no event, so
--     without this nothing could tell the plugin the book was marked Finished there.
--   * "Hardcover end page" is added to KOReader's "End of document action" list, the way ZenOS adds
--     its own. KOReader does nothing for a value it does not know, so choosing it only means this
--     plugin shows the page (see HardcoverApp:onEndOfBook). The entry is never selected for the reader.

local _ = require("gettext")
local logger = require("logger")
local EndOfBook = require("hardcover/lib/end_of_book")

local Hooks = {}

local installed = false

local function watchStatusScreen()
  local BookStatusWidget = require("ui/widget/bookstatuswidget")
  local original = BookStatusWidget.onClose
  if type(original) ~= "function" then return end
  function BookStatusWidget:onClose(...)
    local result = original(self, ...)
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
      UIManager:broadcastEvent(require("ui/event"):new("HardcoverStatusScreenClosed"))
    end)
    return result
  end
end

local function offerEndPage()
  local MenuSorter = require("ui/menusorter")
  local original = MenuSorter.mergeAndSort
  if type(original) ~= "function" then return end
  function MenuSorter:mergeAndSort(prefix, menu_items, ...)
    local entry = type(menu_items) == "table" and menu_items.document_end_action
    local items = type(entry) == "table" and entry.sub_item_table
    if type(items) == "table" then
      local present = false
      for _i, item in ipairs(items) do
        if item.hardcover_end_page then present = true end
      end
      if not present then
        items[#items + 1] = {
          text = _("Hardcover end page"),
          hardcover_end_page = true,
          radio = true,
          checked_func = function()
            return G_reader_settings:readSetting("end_document_action") == EndOfBook.ACTION
          end,
          callback = function()
            G_reader_settings:saveSetting("end_document_action", EndOfBook.ACTION)
          end,
        }
      end
    end
    return original(self, prefix, menu_items, ...)
  end
end

function Hooks.install()
  if installed then return end
  installed = true
  for name, hook in pairs { status_screen = watchStatusScreen, end_page_entry = offerEndPage } do
    local ok, err = pcall(hook)
    if not ok then logger.warn("HARDCOVER hook", name, "not installed:", err) end
  end
end

return Hooks
