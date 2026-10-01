-- Browsable list of a user's Hardcover shelf (Want to Read by default).
--
-- Reuses the same Menu/SearchMenu + cover machinery as the link-book dialog so
-- covers, paging and compatibility mode behave identically. Selecting a row
-- opens BookDetailDialog; the left icon loads the next page.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local SearchMenu = require("hardcover/lib/ui/search_menu")
local Shelf = require("hardcover/lib/shelf")

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
  local text = entry.title
  if entry.authors and entry.authors ~= "" then
    text = text .. "\n" .. entry.authors
  end

  local mandatory = Shelf.statusLabel(entry.status_id)

  if entry.user_rating and entry.user_rating > 0 then
    -- format without the trailing .0 so a whole rating reads "5*" not "5.0*"
    local rating = entry.user_rating
    local formatted = rating % 1 == 0 and string.format("%d", rating) or string.format("%.1f", rating)
    mandatory = mandatory .. "  " .. formatted .. "*"
  end

  local item = {
    text = text,
    mandatory = mandatory,
    mandatory_dim = true,
    entry = entry,
    book_id = entry.book_id,
    -- The vendored ListMenu picks its drawing path with
    --   is_directory = not (entry.is_file or entry.file)
    -- so an item with neither is rendered as a FOLDER, not a book. That branch
    -- is what crashed both shelf views on device: every row took it because no
    -- shelf item carried a file marker. search_dialog sets the same synthetic
    -- marker; do the same here so a shelf row draws as a book.
    file = "hardcover-" .. tostring(entry.book_id),
  }

  if entry.series then
    item.series = entry.series
  end

  if entry.cached_image and entry.cached_image.url then
    item.cover_url = entry.cached_image.url
    item.cover_w = entry.cached_image.width
    item.cover_h = entry.cached_image.height
    item.lazy_load_cover = true
  end

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
      UIManager:show(InfoMessage:new {
        text = _("Could not load more books"),
        icon = "notice-warning",
      })
      return
    end

    self.offset = page_offset + #entries
    self.has_more = has_more and #entries > 0
    self.entries = Shelf.appendPage(self.entries, entries, self.has_more)

    -- swap in a fresh item table; keeps the menu's cover cache consistent
    self.menu:switchItemTable(self.title, self:parseItems(self.entries))

    if self.has_more then
      self.menu.title_bar_left_icon = "cre.render.reload"
      self.menu.onLeftButtonTap = function() self:loadMore() end
    else
      self.menu.title_bar_left_icon = nil
      self.menu.onLeftButtonTap = nil
    end

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