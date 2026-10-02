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
local Picker = require("hardcover/lib/ui/picker")
local ListChrome = require("hardcover/lib/ui/list_chrome")
local ListRow = require("hardcover/lib/ui/list_row")
local ShelfSort = require("hardcover/lib/shelf_sort")
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
  -- a shelf can be re-ordered (search results are in relevance order and cannot):
  -- the left icon is then the sort button, `sort_key` the order, and
  -- `on_sort_change(key)` is told when it changes so it can be remembered
  sortable = false,
  sort_key = nil,
  on_sort_change = nil,
}

function ShelfDialog:createListItem(entry)
  local item = ListRow.row(entry, { compatibility_mode = self.compatibility_mode, year = false })

  -- A shelf list is covers, titles and authors, and nothing else: the shelf
  -- already says the status, and the page count is on the details screen. The
  -- year go with them (they are in the details). The right-hand column is left
  -- for the one thing that is yours -- your rating --
  -- and is absent when there is none, so the text gets the room.
  --
  -- Empty, never nil: ListMenu concatenates it (BD.wrap(self.mandatory)), and a
  -- nil there aborts drawing the whole page, which then reads "No items".
  item.pages = nil
  item.mandatory = ""
  if entry.user_rating and entry.user_rating > 0 then
    -- Format without the trailing .0, so a whole rating reads "5*" not "5.0*"
    local rating = entry.user_rating
    item.mandatory = (rating % 1 == 0 and string.format("%d", rating)
                                       or string.format("%.1f", rating)) .. "*"
  end
  item.entry = entry

  return item
end

function ShelfDialog:init()
  -- offset is how many entries are already loaded, so the next page starts
  -- there. Default it rather than trusting the caller: a nil offset would
  -- reach the API as a nil and silently refetch page one forever.
  self.offset = self.offset or #(self.entries or {})
  self.loading = self.loading or false

  -- the whole screen: no margin, no rounded frame, so the covers can sit flush
  -- against the edge
  self.width = Screen:getWidth()
  self.height = Screen:getHeight()

  local menu_class = self.compatibility_mode and Menu or SearchMenu
  local chrome = ListChrome.options(function() return self.menu end)

  self.menu = menu_class:new {
    page_info_text = chrome.page_info_text,
    single_line = false,
    multilines_show_more_text = true,
    -- five tall rows, so the covers are big enough to recognise (the default is
    -- ten rows of 64px); and no Q/W/E letter boxes, which are for keyboards
    files_per_page = 5,
    is_enable_shortcut = false,
    title = self:displayTitle(),
    fullscreen = true,
    is_borderless = true,
    is_popout = false,
    item_table = self:parseItems(self.entries),
    width = self.width,
    height = self.height,
    title_bar_left_icon = self:leftIcon(),
    onLeftButtonTap = self:leftAction(),
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

-- The title-bar icon and what it does: the sort button on a shelf, otherwise the
-- reload icon that appears when a load was interrupted.
function ShelfDialog:leftIcon()
  if self.sortable then return "appbar.menu" end
  return self.has_more and "cre.render.reload" or nil
end

function ShelfDialog:leftAction()
  if self.sortable then
    return function() self:showSortMenu() end
  end
  return self.has_more and function() self:loadMore() end or nil
end

-- the title, with the order when it is not the usual one
function ShelfDialog:displayTitle()
  if self.sortable and self.sort_key and self.sort_key ~= ShelfSort.DEFAULT and ShelfSort.isKey(self.sort_key) then
    return self.title .. " \194\183 " .. ShelfSort.label(self.sort_key)
  end
  return self.title
end

function ShelfDialog:parseItems(entries)
  local items = {}
  if self.sortable then
    entries = ShelfSort.sort(entries, self.sort_key)
  end
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

  self.menu:switchItemTable(self:displayTitle(), self:parseItems(self.entries), item_number)
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
  self.menu:switchItemTable(self:displayTitle(), {
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
  self.menu.title_bar_left_icon = self:leftIcon()
  self.menu.onLeftButtonTap = self:leftAction()
end

--
-- The sort menu: every order, the current one ticked; and, when a load was
-- interrupted, a way to carry on (the reload icon is the sort button on a shelf).
--
function ShelfDialog:showSortMenu()
  if self.sort_menu then
    UIManager:close(self.sort_menu)
    self.sort_menu = nil
  end

  local rows = {}
  if self.has_more and self.fetch_page then
    rows[#rows + 1] = {
      text = _("Load the rest of the list"),
      bold = true,
      callback = function()
        UIManager:close(self.sort_menu)
        self.sort_menu = nil
        self:loadMore()
      end,
    }
  end

  local current = self.sort_key or ShelfSort.DEFAULT
  for _, option in ipairs(ShelfSort.OPTIONS) do
    rows[#rows + 1] = {
      text = (option.key == current and "\226\156\147 " or "") .. option.label,
      current = option.key == current,
      callback = function()
        UIManager:close(self.sort_menu)
        self.sort_menu = nil
        self:setSort(option.key)
      end,
    }
  end

  self.sort_menu = Picker.new { title = _("Sort by"), rows = rows }
  UIManager:show(self.sort_menu)
end

-- Re-order the list and go back to its first page.
function ShelfDialog:setSort(key)
  if not ShelfSort.isKey(key) or key == self.sort_key then
    return
  end
  self.sort_key = key
  if self.on_sort_change then
    self.on_sort_change(key)
  end
  self.menu:switchItemTable(self:displayTitle(), self:parseItems(self.entries))
  self:updatePager()
  UIManager:setDirty(self, "ui")
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
    self.menu:switchItemTable(self:displayTitle(), self:parseItems(self.entries))
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