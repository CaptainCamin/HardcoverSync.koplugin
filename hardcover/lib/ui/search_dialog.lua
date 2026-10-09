local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local SearchMenu = require("hardcover/lib/ui/search_menu")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local ListChrome = require("hardcover/lib/ui/list_chrome")
local ListRow = require("hardcover/lib/ui/list_row")

local Screen = Device.screen

local HardcoverSearchDialog = InputContainer:extend {
  name = "hardcover_search_dialog",
  width = nil,
  bordersize = Size.border.window,
  items = {},
  active_item = {},
  select_cb = nil,
  title = nil,
  search_callback = nil,
  left_icon_callback = nil,
  left_icon = nil,
  search_value = nil,
  close_callback = nil,

  compatibility_mode = true
}

function HardcoverSearchDialog:createListItem(book)
  -- Row shaping lives in hardcover/lib/ui/list_row.lua, shared with the shelf
  -- dialog. It was inline here and the two copies had drifted -- see that
  -- module's header for the three fields whose absence is visible on screen.
  return ListRow.row(book, { compatibility_mode = self.compatibility_mode })
end

function HardcoverSearchDialog:init()
  if Device:isTouchDevice() then
    self.ges_events.Tap = {
      GestureRange:new {
        ges = "tap",
        range = Geom:new {
          x = 0,
          y = 0,
          w = Screen:getWidth(),
          h = Screen:getHeight(),
        }
      }
    }
  end

  self.width = self.width or Screen:getWidth() - Screen:scaleBySize(50)
  self.width = math.min(self.width, Screen:scaleBySize(600))
  self.height = Screen:getHeight() - Screen:scaleBySize(50)

  local left_icon, left_icon_callback
  if self.search_callback then
    left_icon = "appbar.search"
    left_icon_callback = function() self:search() end
  elseif self.left_icon_callback then
    left_icon = self.left_icon
    left_icon_callback = self.left_icon_callback
  end
  local menu_class = self.compatibility_mode and Menu or SearchMenu
  local chrome = ListChrome.options(function() return self.menu end)

  self.menu = menu_class:new {
    page_info_text = chrome.page_info_text,
    -- no Q/W/E letter boxes: they are for keyboards, and cover part of each cover
    is_enable_shortcut = false,
    single_line = false,
    multilines_show_more_text = true,
    title = self.title or "Select book",
    fullscreen = true,
    item_table = self:parseItems(self.items, self.active_item),
    width = self.width,
    height = self.height,
    title_bar_left_icon = left_icon,
    onLeftButtonTap = left_icon_callback,
    onMenuSelect = function(menu, book)
      if self.select_book_cb then
        self.select_book_cb(book)
      end
    end,
    close_callback = function()
      self:onClose()
    end
  }

  self.items = nil

  self.container = CenterContainer:new {
    dimen = Screen:getSize(),
    self.menu,
  }

  self.menu.show_parent = self

  self[1] = self.container
end

function HardcoverSearchDialog:search()
  local search_dialog
  search_dialog = InputDialog:new {
    title = "New search",
    input = self.search_value,
    save_button_text = "Search",
    buttons = { {
      {
        text = _("Cancel"),
        callback = function()
          UIManager:close(search_dialog)
        end,
      },
      {
        text = _("Search"),
        -- button with is_enter_default set to true will be
        -- triggered after user press the enter key from keyboard
        is_enter_default = true,
        callback = function()
          local text = search_dialog:getInputText()
          local result = self.search_callback(text)
          if result then
            UIManager:close(search_dialog)
          end
        end,
      }
    } }
  }

  UIManager:show(search_dialog)
  search_dialog:onShowKeyboard()
end

--
-- An empty list is an answer, not a failure.
--
-- KOReader's own "No items" would otherwise be all the user sees, which is
-- indistinguishable from the list failing to load -- and this dialog is reached
-- from paths that genuinely can return nothing.
--
-- The row carries a `file` marker for the same reason shelf rows do: the
-- vendored ListMenu chooses its drawing path with
-- is_directory = not (entry.is_file or entry.file), and a row without one is
-- drawn through the folder branch.
--
function HardcoverSearchDialog:setEmptyState(message)
  self.empty_state = message
  self.menu:switchItemTable(self.title or _("Select book"), {
    {
      text = message,
      mandatory = "",
      mandatory_dim = true,
      file = "hardcover-empty",
    },
  })
  UIManager:setDirty(self, "ui")
end

function HardcoverSearchDialog:setTitle(title)
  self.menu.title = title
end

function HardcoverSearchDialog:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end

  return true
end

function HardcoverSearchDialog:onTapClose(arg, ges)
  if ges.pos:notIntersectWith(self.movable.dimen) then
    self:onClose()
  end
  return true
end

function HardcoverSearchDialog:parseItems(items, active_item)
  -- ListRow.rows marks the row matching active_item, so the reader can see
  -- which book is already linked without opening anything.
  return ListRow.rows(items, { compatibility_mode = self.compatibility_mode },
                     active_item)
end

function HardcoverSearchDialog:setItems(title, items, active_item)
  if self.menu.halt_image_loading then
    self.menu.halt_image_loading()
  end

  -- hack: Allow reusing menu (and closing more than once)
  self.menu._covermenu_onclose_done = false
  local new_item_table = self:parseItems(items, active_item)
  if self.menu.item_table then
    for _, v in ipairs(self.menu.item_table) do
      if v.cover_bb then
        v.cover_bb:free()
      end
    end
  end
  self.menu:switchItemTable(title, new_item_table)
end

function HardcoverSearchDialog:onTap(_, ges)
  if ges.pos:notIntersectWith(self[1][1].dimen) then
    -- Tap outside closes widget
    self:onClose()
    return true
  end
end

return HardcoverSearchDialog
