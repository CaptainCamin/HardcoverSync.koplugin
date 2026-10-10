-- The Shelves tab of the Library: one row per shelf (Want to Read, Currently Reading, Read, Did Not
-- Finish) with how many books it holds. Tapping a row opens that shelf over the shell. Counts are
-- what Home last loaded (see DialogManager:showOldHome), pushed in with setRows.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local Home = require("hardcover/lib/home")
local Hosted = require("hardcover/lib/ui/hosted")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Theme = require("hardcover/lib/ui/theme")

local ShelvesBody = InputContainer:extend {
  name = "hardcover_shelves",
  rows = nil,      -- Home.rows(counts)
  select_cb = nil, -- called with the chosen row
  shell = nil,
  width = nil,
  height = nil,
  parent = nil,    -- the Library body that holds this tab
}

function ShelvesBody:init()
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  self:build()
end

function ShelvesBody:build()
  local w, h = Hosted.size(self)
  local group = VerticalGroup:new { align = "left" }
  local rows = self.rows or {}
  for i, row in ipairs(rows) do
    local trailing = HorizontalGroup:new { align = "center" }
    local count = Home.countText(row.count)
    if count ~= "" then
      trailing[#trailing + 1] = Theme.mmdText(count, "text", 18, { secondary = true })
      trailing[#trailing + 1] = Theme.hspan("s")
    end
    trailing[#trailing + 1] = Draw.chevron("right")
    group[#group + 1] = ListItem.new {
      width = w, label = row.title, trailing = trailing, strong = true,
      divider = i < #rows and "dotted" or nil,
      callback = function() if self.select_cb then self.select_cb(row) end end,
    }
  end
  self[1] = FrameContainer:new { width = w, height = h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0, group }
end

function ShelvesBody:setRows(rows)
  self.rows = rows or {}
  if self[1] and type(self[1].free) == "function" then pcall(function() self[1]:free() end) end
  self[1] = nil
  self:build()
  Hosted.dirty(self)
end

function ShelvesBody:onClose() return true end

return ShelvesBody
