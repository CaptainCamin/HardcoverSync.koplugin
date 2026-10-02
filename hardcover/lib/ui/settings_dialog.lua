-- The plugin's settings, as a screen of their own.
--
-- The settings live in the reader / file browser menu; the home screen (which can
-- be launched from another plugin) needs a way in too. This shows the same item
-- tables in a plain Menu: tick marks for options, "›" for submenus, and a first
-- row to go back up. Back (or the close icon) leaves one level at a time.

local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local SettingsItems = require("hardcover/lib/settings_items")

local SettingsDialog = {}

function SettingsDialog.show(opts)
  local stack = {} -- { title, items } for the levels above this one
  local current = { title = opts.title or _("Settings"), items = opts.items }
  local menu

  local function render()
    local rows = SettingsItems.rows(current.items, function(title, items)
      stack[#stack + 1] = current
      current = { title = title, items = items }
      render()
    end, function()
      render()
    end)

    local item_table = {}
    if #stack > 0 then
      item_table[1] = {
        text = "\226\128\185 " .. _("Back"),
        callback = function()
          current = table.remove(stack)
          render()
        end,
      }
    end
    for _, row in ipairs(rows) do
      item_table[#item_table + 1] = {
        text = row.text,
        mandatory = row.mandatory,
        dim = row.dim,
        callback = row.choose,
      }
    end

    menu:switchItemTable(current.title, item_table)
  end

  menu = Menu:new {
    title = current.title,
    item_table = {},
    is_borderless = true,
    is_popout = false,
    covers_fullscreen = true,
    onMenuSelect = function(_self, item)
      if item.callback then item.callback() end
      return true
    end,
    close_callback = function()
      UIManager:close(menu)
      if opts.on_close then opts.on_close() end
    end,
  }
  -- leaving the screen must repaint what was under it
  menu.onCloseWidget = function(self)
    UIManager:setDirty(nil, "ui")
    return Menu.onCloseWidget and Menu.onCloseWidget(self)
  end

  render()
  UIManager:show(menu)
  return menu
end

return SettingsDialog
