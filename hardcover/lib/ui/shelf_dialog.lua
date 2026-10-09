-- Browsable list of a user's Hardcover shelf (Want to Read by default).
--
-- Reuses the same Menu/SearchMenu + cover machinery as the link-book dialog so
-- covers, paging and compatibility mode behave identically. Selecting a row
-- opens BookDetailDialog.
--
-- The top is a ListHeader: the family's title bar (Back, the title, the X, and a reload
-- icon beside the X when the screen can fetch itself again or has more to load), and a
-- row of buttons under it: Sort and Search on a shelf, Search on a list, "New search" on
-- search results. Search filters the entries already on the device (see entry_search.lua).

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local SearchMenu = require("hardcover/lib/ui/search_menu")
local Shelf = require("hardcover/lib/shelf")
local EntrySearch = require("hardcover/lib/entry_search")
local Picker = require("hardcover/lib/ui/picker")
local ListChrome = require("hardcover/lib/ui/list_chrome")
local ListHeader = require("hardcover/lib/ui/list_header")
local ListRow = require("hardcover/lib/ui/list_row")
local Refresh = require("hardcover/lib/ui/refresh")
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
  -- the row then has a Sort button, `sort_key` is the order, and
  -- `on_sort_change(key)` is told when it changes so it can be remembered
  sortable = false,
  sort_key = nil,
  on_sort_change = nil,
  -- a screen that can fetch itself again (a shelf's or a list's Refresh) gives the
  -- reload icon beside the X this to run, as on_refresh(dialog). A screen with more to
  -- load has the icon too, and it carries on loading instead.
  on_refresh = nil,
  -- the words the list is filtered by (the Search button); nil shows every entry
  filter = nil,
  -- search results only: "New search" in place of Search, which would filter just the
  -- books shown. It opens the home search box again.
  on_search = nil,
}

local OPEN_QUOTE, CLOSE_QUOTE, TIMES = "\226\128\156", "\226\128\157", "\195\151"

-- A row that says something in place of books: the file marker keeps the vendored list
-- from drawing it as a folder (see setEmptyState).
local function messageRow(message)
  return {
    text = message,
    mandatory = "",
    mandatory_dim = true,
    file = "hardcover-empty",
  }
end

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
  -- a ranked list numbers its books, in the column a shelf uses for your rating
  if entry.rank then
    item.mandatory = "#" .. tostring(entry.rank)
  end
  -- "For you": why it was suggested, where a series would be named
  if type(entry.reason) == "string" and entry.reason ~= "" then
    local why = T(_("Because you liked %1"), entry.reason)
    item.series = why
    item.series_index = nil
    -- the stock list (compatibility mode) is one line: the reason goes at its end
    if self.compatibility_mode and item.text then item.text = item.text .. " - " .. why end
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

  -- one function for the reload icon, so the header is not rebuilt for a new closure
  self.reload_callback = function() self:onReload() end
  local icon, buttons = self:reloadIcon(), self:rowButtons()
  self.header_signature = self:headerSignature(icon, buttons)
  self.header = ListHeader:new {
    title = self:displayTitle(),
    width = self.width,
    back_callback = function() self:onClose() end,
    right_icon = icon,
    right_callback = self.reload_callback,
    buttons = buttons,
    show_parent = self,
  }

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
    item_table = self:currentItems(),
    width = self.width,
    height = self.height,
    -- Back and the X are the header's own; the Menu wires nothing into a custom bar
    custom_title_bar = self.header,
    onMenuSelect = function(_, entry)
      if self.select_entry_cb then
        self.select_entry_cb(entry)
      end
    end,
    -- the device's Back key: the Menu then asks for the window to close
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

-- The title-bar's second icon: reload, when the screen can fetch itself again or there
-- is more of the list to load (a load that was interrupted).
function ShelfDialog:reloadIcon()
  if self.on_refresh or (self.has_more and self.fetch_page) then
    return "cre.render.reload"
  end
  return nil
end

-- What the icon does. More to load comes first: finishing the load costs less than
-- fetching everything again.
function ShelfDialog:onReload()
  if self.has_more and self.fetch_page then
    self:loadMore()
  elseif self.on_refresh then
    self.on_refresh(self)
  end
end

-- The row under the title bar, as ListHeader takes it. Search results have just "New
-- search": filtering the few books shown would not find more.
function ShelfDialog:rowButtons()
  local buttons = {}
  if self.on_search then
    buttons[1] = {
      text = _("New search"),
      chevron = true,
      callback = function() self.on_search() end,
    }
    return buttons
  end
  if self.sortable then
    buttons[#buttons + 1] = {
      text = T(_("Sort: %1"), ShelfSort.label(self.sort_key or ShelfSort.DEFAULT)),
      chevron = true,
      callback = function() self:showSortMenu() end,
    }
  end
  if self.filter then
    -- black: a filter is on. It opens the box again; the small button beside it clears it
    buttons[#buttons + 1] = {
      text = OPEN_QUOTE .. self.filter .. CLOSE_QUOTE,
      filled = true,
      callback = function() self:showSearchBox() end,
    }
    buttons[#buttons + 1] = {
      text = TIMES,
      narrow = true,
      callback = function() self:setFilter(nil) end,
    }
  else
    buttons[#buttons + 1] = {
      text = _("Search"),
      callback = function() self:showSearchBox() end,
    }
  end
  return buttons
end

-- What the header shows, as one string, so it is only rebuilt when it changed
function ShelfDialog:headerSignature(icon, buttons)
  local parts = { icon or "" }
  for _, button in ipairs(buttons) do
    parts[#parts + 1] = (button.filled and "!" or "") .. (button.narrow and "~" or "") .. button.text
  end
  return table.concat(parts, "\0")
end

-- the title: the Sort button names the order, so the title does not
function ShelfDialog:displayTitle()
  return self.title
end

-- The entries that match the filter, in the sort order, as rows. The filter comes first:
-- sorting is the dearer part.
function ShelfDialog:parseItems(entries)
  local items = {}
  entries = EntrySearch.filter(entries or {}, self.filter)
  if self.sortable then
    entries = ShelfSort.sort(entries, self.sort_key)
  end
  for _, entry in ipairs(entries) do
    table.insert(items, self:createListItem(entry))
  end
  return items
end

-- The rows to show now. When nothing is left to show, a row says why: the filter matched
-- no book, or the shelf has none (see setEmptyState).
function ShelfDialog:currentItems()
  local items = self:parseItems(self.entries)
  if #items == 0 then
    if self.filter and #(self.entries or {}) > 0 then
      return { messageRow(T(_("No books match \226\128\156%1\226\128\157"), self.filter)) }
    elseif self.empty_state then
      return { messageRow(self.empty_state) }
    end
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
  self.empty_state = nil

  local item_number
  if keep_position and self.menu.page and self.menu.perpage then
    item_number = (self.menu.page - 1) * self.menu.perpage + 1
  end

  self:updatePager()
  self.menu:switchItemTable(self:displayTitle(), self:currentItems(), item_number)
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
  self:updatePager()
  self.menu:switchItemTable(self:displayTitle(), { messageRow(message) })
  UIManager:setDirty(self, "ui")
end

--
-- The header follows the state of the screen: the reload icon is there while the screen
-- can fetch itself again or has a next page, and goes when it has neither (it would
-- invite a tap that does nothing), and the buttons show the sort order and the filter.
-- Only the header's own rectangle is refreshed, and only when something in it changed.
-- Called before the Menu swaps its rows: that builds the Menu's key-navigation layout from
-- the header's buttons as they are then.
--
function ShelfDialog:updatePager()
  local icon, buttons = self:reloadIcon(), self:rowButtons()
  local signature = self:headerSignature(icon, buttons)
  if signature == self.header_signature then return end
  self.header_signature = signature
  self.header:update {
    -- false takes the icon away (nil would mean "leave it")
    right_icon = icon or false,
    right_callback = self.reload_callback,
    buttons = buttons,
  }
  Refresh.region(self, function() return self.header.dimen end)
end

--
-- The sort orders, the current one ticked.
--
function ShelfDialog:showSortMenu()
  if self.sort_menu then
    UIManager:close(self.sort_menu)
    self.sort_menu = nil
  end

  local function closeMenu()
    UIManager:close(self.sort_menu)
    self.sort_menu = nil
  end

  local rows = {}
  local current = self.sort_key or ShelfSort.DEFAULT
  for _, option in ipairs(ShelfSort.OPTIONS) do
    rows[#rows + 1] = {
      text = (option.key == current and "\226\156\147 " or "") .. option.label,
      current = option.key == current,
      callback = function()
        closeMenu()
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
  self:updatePager()
  self.menu:switchItemTable(self:displayTitle(), self:currentItems())
  UIManager:setDirty(self, "ui")
end

--
-- The Search button: a box for the words, filled in with the filter that is on.
-- Searching with nothing in the box takes the filter off.
--
function ShelfDialog:showSearchBox()
  local InputDialog = require("ui/widget/inputdialog")
  local box
  box = InputDialog:new {
    title = self.sortable and _("Search this shelf") or _("Search this list"),
    input = self.filter or "",
    input_hint = _("Title, author or series"),
    buttons = { {
      {
        text = _("Cancel"),
        callback = function() UIManager:close(box) end,
      },
      {
        text = _("Search"),
        is_enter_default = true,
        callback = function()
          local text = box:getInputText()
          UIManager:close(box)
          self:setFilter(text)
        end,
      },
    } },
  }
  UIManager:show(box)
  box:onShowKeyboard()
  return box
end

-- Show only the books that match `text` (nil, or only spaces, shows them all), from the
-- first page. The entries themselves are not touched: clearing the filter brings every
-- book back without a request.
function ShelfDialog:setFilter(text)
  text = text and (tostring(text):gsub("^%s+", ""):gsub("%s+$", "")) or ""
  if #EntrySearch.words(text) == 0 then text = nil end
  self.filter = text
  self:updatePager()
  self.menu:switchItemTable(self:displayTitle(), self:currentItems())
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
    -- the reload icon goes once the last page is in
    self.has_more = (has_more and #entries > 0) and true or false

    self:updatePager()
    -- Swap in a fresh item table; keeps the menu's cover cache consistent
    self.menu:switchItemTable(self:displayTitle(), self:currentItems())

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