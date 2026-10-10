-- A list of rows with one icon each instead of covers, in two groups: the Library's Vibes tab (mock 2v:
-- a sparkle for For you, a ranked list for Hardcover's own vibes, a lock for private ones) and its Lists
-- tab (the shelf icon, the same as the Shelves tab, for "Your lists" and "Following"). No covers also
-- means no cover fetches. A For you row is simply the first row, with no heading of its own; the group
-- heads sit on the same dotted line the rows use; dividers start after the icon.
--
-- It takes the same data as the lists screen it replaces in the Library (setLists, setMessage), so
-- DialogManager:showVibes and showLists feed either.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Draw = require("hardcover/lib/ui/components/draw")
local Hosted = require("hardcover/lib/ui/hosted")
local Lists = require("hardcover/lib/lists")
local ListItem = require("hardcover/lib/ui/components/list_item")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Theme = require("hardcover/lib/ui/theme")

local IconListBody = InputContainer:extend {
  name = "hardcover_icon_list",
  first_title = nil,  -- the first group's head (default "From Hardcover")
  second_title = nil, -- the second group's head (default "Made by you")
  icon_for = nil,     -- function(row) -> the icon's name (default: by the kind of vibe)
  empty_title = nil,
  system = nil,   -- rows (Vibes.rows): Hardcover's own, "For you" first when it is on
  mine = nil,     -- rows: made by you
  message = nil,  -- shown instead of the rows ("Loading your vibes…")
  select_cb = nil,
  shell = nil,
  width = nil,
  height = nil,
  parent = nil,
}

function IconListBody:init()
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  self:build()
end

-- the icon a row gets: what kind of vibe it is
local function vibeIcon(row)
  if row.for_you then return "sparkle" end
  if row.private then return "lock" end
  return "ranked"
end

-- A group head on the dotted line: capitals at the left, the count at the right.
local function groupHead(title, count, width)
  local left = Theme.mmdText(string.upper(title), "strong", 15)
  local right = Theme.mmdText(tostring(count), "text", 15, { secondary = true })
  local gap = math.max(0, width - 2 * ListItem.PAD - left:getSize().w - right:getSize().w)
  return VerticalGroup:new { align = "left",
    Theme.span(Theme.px(18)),
    HorizontalGroup:new { align = "center", Theme.hspan(ListItem.PAD), left, Theme.hspan(gap), right,
      Theme.hspan(ListItem.PAD) },
    Theme.span(Theme.px(8)),
    Theme.dottedRule(width),
  }
end

function IconListBody:rows(width)
  local group = VerticalGroup:new { align = "left" }
  local icon = Theme.px(30)
  local divider_x = ListItem.PAD + icon + Theme.px(16)
  local function add(rows)
    for i, row in ipairs(rows) do
      group[#group + 1] = ListItem.new {
        width = width, label = row.name,
        support = row.for_you and _("Based on what you read") or Lists.subtitle(row),
        lead = Theme.icon((self.icon_for or vibeIcon)(row), icon), trailing = Draw.chevron("right"),
        divider = "dotted", divider_x = divider_x,
        callback = function() if self.select_cb then self.select_cb(row) end end,
      }
    end
  end
  local system = self.system or {}
  -- For you is the first row, with no heading of its own
  local first = system[1] and system[1].for_you and { system[1] } or {}
  add(first)
  local hardcover = {}
  for i = #first + 1, #system do hardcover[#hardcover + 1] = system[i] end
  if #hardcover > 0 then
    group[#group + 1] = groupHead(self.first_title or _("From Hardcover"), #hardcover, width)
    add(hardcover)
  end
  if self.mine and #self.mine > 0 then
    group[#group + 1] = groupHead(self.second_title or _("Made by you"), #self.mine, width)
    add(self.mine)
  end
  return group
end

function IconListBody:build()
  local w, h = Hosted.size(self)
  local body
  self.scroll = nil
  if self.message then
    local face, bold = Theme.mmdFace("text", 18)
    body = CenterContainer:new { dimen = Geom:new { w = w, h = h },
      TextBoxWidget:new { text = self.message, face = face, bold = bold, width = w - 4 * Theme.margin,
        alignment = "center", fgcolor = Theme.secondary() } }
  else
    local group = self:rows(w)
    body = group
    if group:getSize().h > h then
      group = self:rows(w - ScrollControl.gutter())
      self.scroll = ScrollableContainer:new { dimen = Geom:new { x = 0, y = 0, w = w, h = h },
        show_parent = Hosted.window(self) }
      self.scroll[1] = group
      body = ScrollControl.wrap(self.scroll, group)
    end
  end
  self[1] = FrameContainer:new { width = w, height = h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0, body }
end

function IconListBody:rebuild()
  local offset = self.scroll and self.scroll:getScrolledOffset()
  if self[1] and type(self[1].free) == "function" then pcall(function() self[1]:free() end) end
  self[1] = nil
  self:build()
  if offset and self.scroll then self.scroll:setScrolledOffset(offset) end
  Hosted.dirty(self)
end

function IconListBody:setLists(system, mine, message)
  self.system, self.mine, self.message = system, mine, message
  self:rebuild()
end

function IconListBody:setMessage(message)
  self.message = message
  self:rebuild()
end

function IconListBody:onClose() return true end

return IconListBody
