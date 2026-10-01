-- The home screen: your shelves, with how many books are on each.
--
-- Built like the shelf screen (an InputContainer around a Menu inside a
-- CenterContainer) because that structure is the one already proven on the
-- device. Selecting a row opens that shelf on top of this screen, so closing the
-- shelf comes back here.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Home = require("hardcover/lib/home")

local Screen = Device.screen

local HomeDialog = InputContainer:extend {
  name = "hardcover_home_dialog",
  title = _("Hardcover"),
  rows = {},
  select_cb = nil,
  close_callback = nil,
}

function HomeDialog:parseItems(rows)
  local items = {}
  for _, row in ipairs(rows or {}) do
    table.insert(items, {
      text = row.title,
      mandatory = Home.countText(row.count),
      row = row,
    })
  end
  return items
end

function HomeDialog:init()
  self.width = math.min(Screen:getWidth() - Screen:scaleBySize(50), Screen:scaleBySize(600))
  self.height = Screen:getHeight() - Screen:scaleBySize(50)

  self.menu = Menu:new {
    single_line = false,
    title = self.title,
    fullscreen = true,
    item_table = self:parseItems(self.rows),
    width = self.width,
    height = self.height,
    onMenuSelect = function(_, item)
      if self.select_cb and item.row then
        self.select_cb(item.row)
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

-- Swap in fresh counts once they arrive.
function HomeDialog:setRows(rows)
  self.rows = rows or {}
  self.menu:switchItemTable(self.title, self:parseItems(self.rows))
  UIManager:setDirty(self, "ui")
end

function HomeDialog:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

return HomeDialog
