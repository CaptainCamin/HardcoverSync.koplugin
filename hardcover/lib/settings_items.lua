-- Turn the plugin's menu definitions into plain rows for a Menu.
--
-- The settings live in the same item tables TouchMenu reads (text_func,
-- checked_func, enabled_func, sub_item_table_func, callbacks that are handed
-- the menu). The home screen is not a TouchMenu, so this resolves one level of
-- those tables into { text, mandatory, enabled, ... } rows and says what
-- choosing each one does. Pure: no widgets, so it can be tested without them.

local SettingsItems = {}

local CHECK = "\226\156\147" -- check mark

local function resolve(item, field)
  local fn = item[field .. "_func"]
  if fn then return fn() end
  return item[field]
end

local function children(item)
  if item.sub_item_table_func then return item.sub_item_table_func() end
  return item.sub_item_table
end

--
-- Rows for one level. `open(title, items)` is called when a row with children is
-- chosen; `refresh()` when a row changed something and the level should be
-- drawn again. Items that are falsy (gated off) are skipped.
--
function SettingsItems.rows(items, open, refresh)
  local rows = {}
  -- the menu instance handed to callbacks: they ask it to redraw
  local menu_shim = { updateItems = function() refresh() end }

  for _, item in ipairs(items or {}) do
    if item then
      local text = resolve(item, "text") or ""
      local enabled = true
      if item.enabled_func then enabled = item.enabled_func() and true or false end

      local row = {
        text = text,
        mandatory = resolve(item, "checked") and CHECK or (children(item) and "\226\128\186" or nil),
        dim = not enabled or nil,
        item = item,
        -- what the screen needs to draw it: a tick box (ticked or not), an
        -- arrow into a submenu, or one of the two header tiles
        checkable = (item.checked_func ~= nil or item.checked ~= nil) or nil,
        checked = resolve(item, "checked") and true or false,
        submenu = (item.sub_item_table ~= nil or item.sub_item_table_func ~= nil) or nil,
        -- a row that is not a submenu but still opens a screen, a dialog or a picker
        opens = item.opens or nil,
        -- one choice of several (the current status): a radio mark, not a switch
        radio = item.radio or nil,
        -- a bundled icon at the row's end (what tapping it does: "close" cancels a pending change)
        icon = item.icon or nil,
        tile = item.tile,
        separator = item.separator,
      }

      row.choose = function()
        if not enabled then return end
        if item.sub_item_table or item.sub_item_table_func then
          open(text, children(item) or {}, item)
        elseif item.callback then
          item.callback(menu_shim)
          refresh()
        end
      end

      -- long press, for items that have one (Sync: discard what is queued)
      if item.hold_callback then
        row.hold = function()
          item.hold_callback(menu_shim)
          refresh()
        end
      end

      rows[#rows + 1] = row
    end
  end

  return rows
end

return SettingsItems
