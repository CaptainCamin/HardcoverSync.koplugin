-- Browsable list of a user's Hardcover shelf (Want to Read by default).
--
-- Reuses the same Menu/SearchMenu + cover machinery as the link-book dialog so
-- covers, paging and compatibility mode behave identically. Selecting a row
-- opens BookDetailDialog; the left icon loads the next page.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local SearchMenu = require("hardcover/lib/ui/search_menu")
local Shelf = require("hardcover/lib/shelf")
local ListRow = require("hardcover/lib/ui/list_row")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local Screen = Device.screen

local ShelfDialog = InputContainer:extend {
  name = "hardcover_shelf_dialog",
  title = _("Want to Read"),
  entries = {},
  offset = 0,
  has_more = false,
  loading = false,
  page_size = 20,
  status_id = nil,
  fetch_page = nil,
  select_entry_cb = nil,
  close_callback = nil,
  compatibility_mode = true,
}

function ShelfDialog:createListItem(entry)
  local item = ListRow.row(entry, { compatibility_mode = self.compatibility_mode })

  -- Shelf rows carry two things a search row does not: the reader's status for
  -- the book, and their rating. Both decorate the mandatory column rather than
  -- being derived inside list_row, because they are properties of a shelf
  -- entry rather than of a book.
  local mandatory_parts = { Shelf.statusLabel(entry.status_id) }

  if entry.user_rating and entry.user_rating > 0 then
    -- Format without the trailing .0, so a whole rating reads "5*" not "5.0*"
    local rating = entry.user_rating
    local formatted = rating % 1 == 0 and string.format("%d", rating)
                                   or string.format("%.1f", rating)
    table.insert(mandatory_parts, formatted .. "*")
  end

  item.mandatory = table.concat(mandatory_parts, "  ")
  item.entry = entry

  return item
end

function ShelfDialog:init()
  -- offset is how many entries are already loaded, so the next page starts
  -- there. Default it rather than trusting the caller: a nil offset would
  -- reach the API as a nil and silently refetch page one forever.
  self.offset = self.offset or #(self.entries or {})
  self.loading = self.loading or false

  self.width = math.min(Screen:getWidth() - Screen:scaleBySize(50), Screen:scaleBySize(600))
  self.height = Screen:getHeight() - Screen:scaleBySize(50)

  local menu_class = self.compatibility_mode and Menu or SearchMenu

  self.menu = menu_class:new {
    single_line = false,
    multilines_show_more_text = true,
    title = self.title,
    fullscreen = true,
    item_table = self:parseItems(self.entries),
    width = self.width,
    height = self.height,
    title_bar_left_icon = self.has_more and "cre.render.reload" or nil,
    onLeftButtonTap = self.has_more and function() self:loadMore() end or nil,
    onMenuSelect = function(_, entry)
      if self.select_entry_cb then
        self.select_entry_cb(entry)
      end
    end,
    close_callback = function()
      self:onClose()
    end,
  }

  self.container = CenterContainer:new {
    dimen = Screen:getSize(),
    self.menu,
  }
  self.menu.show_parent = self
  self[1] = self.container
end

function ShelfDialog:parseItems(entries)
  local items = {}
  for _, entry in ipairs(entries or {}) do
    table.insert(items, self:createListItem(entry))
  end
  return items
end

--
-- Replace the rows after the first page lands.
--
-- The dialog is built and shown empty, so this is what fills it. The item table
-- is swapped rather than appended because the menu's cover cache is keyed on it.
--
--
-- `keep_position` stays on the page being viewed. Rows that arrive while the
-- reader is already browsing would otherwise send them back to page one each
-- time (switchItemTable resets to the first page unless it is given an item
-- number to show).
--
function ShelfDialog:setEntries(entries, has_more, keep_position)
  self.entries = entries or {}
  self.has_more = has_more and #self.entries > 0

  local item_number
  if keep_position and self.menu.page and self.menu.perpage then
    item_number = (self.menu.page - 1) * self.menu.perpage + 1
  end

  self.menu:switchItemTable(self.title, self:parseItems(self.entries), item_number)
  self:updatePager()
  UIManager:setDirty(self, "ui")
end

--
-- An empty shelf is a real answer, not a failure.
--
-- Without a row saying so, the screen is a title bar over a blank list, which
-- reads as a bug rather than as "you have not added anything here yet".
--
-- The row still carries a `file` marker. The vendored ListMenu chooses its
-- drawing path with is_directory = not (entry.is_file or entry.file), so a row
-- without one renders through the FOLDER branch -- the branch that already
-- crashed both shelf views on device once.
--
function ShelfDialog:setEmptyState(message)
  self.empty_state = message
  self.has_more = false
  self.menu:switchItemTable(self.title, {
    {
      text = message,
      mandatory = "",
      mandatory_dim = true,
      file = "hardcover-empty",
    },
  })
  self:updatePager()
  UIManager:setDirty(self, "ui")
end

--
-- The title-bar left icon loads the next page; it has to disappear once there
-- is no next page, or it invites a tap that does nothing.
--
function ShelfDialog:updatePager()
  if self.has_more then
    self.menu.title_bar_left_icon = "cre.render.reload"
    self.menu.onLeftButtonTap = function() self:loadMore() end
  else
    self.menu.title_bar_left_icon = nil
    self.menu.onLeftButtonTap = nil
  end
end

--
-- Fetch the next page and append it. Guarded by self.loading so a double tap
-- on the reload icon cannot fire two overlapping requests.
--
function ShelfDialog:loadMore()
  if self.loading or not self.has_more or not self.fetch_page then
    return
  end

  self.loading = true

  local page_offset = self.offset
  self.fetch_page(page_offset, self.page_size, function(entries, err, has_more)
    self.loading = false

    if err or not entries then
      StatusDialogs.error(_("Could not load more books"))
      return
    end

    self.offset = page_offset + #entries
    self.entries = Shelf.appendPage(self.entries, entries, has_more and #entries > 0)

    -- Swap in a fresh item table; keeps the menu's cover cache consistent
    self.menu:switchItemTable(self.title, self:parseItems(self.entries))
    self:updatePager()

    UIManager:setDirty(self, "ui")
  end)
end

function ShelfDialog:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

return ShelfDialog