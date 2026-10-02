-- "More in this series": a strip of covers you page through.
--
-- E-ink has no smooth scrolling, so this is a paged strip rather than a swipeable
-- one: a few covers at a time, with an arrow either side to turn the page. Each
-- cover carries its number in the series, its title and your status on it; the
-- book on screen has a heavier frame and is not tappable; the others open that
-- book.
--
-- Turning a page swaps the strip's contents in place and never rebuilds the
-- screen around it, so the page the reader is on does not jump back to the top.
-- That only works if every page is exactly the same size, so every piece of text
-- here has a fixed height and short pages are padded.
--
-- It lives inside a scrolling page, so every tappable part is limited to what the
-- scroll area is showing (see viewport.lua).

local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local CoverBox = require("hardcover/lib/ui/cover_box")
local Shelf = require("hardcover/lib/shelf")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")
local Viewport = require("hardcover/lib/ui/viewport")

local Screen = Device.screen

local SeriesCarousel = {}
SeriesCarousel.__index = SeriesCarousel

--
-- opts:
--   card          Shelf.seriesCard's result
--   width         the width available
--   viewport      function returning the visible rectangle of the scroll area
--   on_open       function(book_id), called when a cover is tapped
--   image_loader  something with loadImages(urls, callback) -> batch, halt
--   on_change     function(get_dimen), called after the strip changes, to repaint;
--                 get_dimen returns the painted box that changed (a cover, or the
--                 whole strip when a page was turned), so only that need be refreshed
--
function SeriesCarousel:new(opts)
  local o = setmetatable(opts, self)
  o.generation = 0
  o.boxes = {}
  o:build()
  o:render()
  return o
end

function SeriesCarousel:build()
  local width = self.width
  local items = self.card.items

  self.arrow_width = math.floor(width * 0.07)
  local strip_width = width - 2 * self.arrow_width
  -- at least 20% of the width for each cover, between three and five at a time
  self.per_page = math.max(3, math.min(5, math.floor(strip_width / (width * 0.20))))
  self.item_width = math.floor(strip_width / self.per_page)
  self.cover_width = self.item_width - 20
  self.cover_height = math.floor(self.cover_width * 1.5)
  self.text_width = self.item_width - 8

  self.number_face = Theme.face("small")
  self.title_face = Theme.face("label")
  self.status_face = Theme.face("label")

  -- the height of two lines of title, so every title takes the same room
  local probe = TextBoxWidget:new {
    text = "A\\nA",
    face = self.title_face,
    width = self.text_width,
    alignment = "center",
  }
  self.title_height = probe:getSize().h
  probe:free()

  -- measure one item so the arrows and the padding can match it
  local sample = self:buildItem(items[1])
  self.item_height = sample:getSize().h
  self:releaseBoxes()

  self.paged = #items > self.per_page
  if self.paged then
    local icon = math.floor(self.arrow_width * 0.6)
    self.prev = Button:new {
      icon = "chevron.left",
      icon_width = icon,
      icon_height = icon,
      width = self.arrow_width,
      bordersize = 0,
      margin = 0,
      padding = 0,
      callback = function() self:turn(-1) end,
    }
    self.next = Button:new {
      icon = "chevron.right",
      icon_width = icon,
      icon_height = icon,
      width = self.arrow_width,
      bordersize = 0,
      margin = 0,
      padding = 0,
      callback = function() self:turn(1) end,
    }
    Viewport.limitButton(self.prev, self.viewport)
    Viewport.limitButton(self.next, self.viewport)
  end

  local function arrow_cell(button)
    if not button then
      return HorizontalSpan:new { width = self.arrow_width }
    end
    return CenterContainer:new {
      dimen = Geom:new { w = self.arrow_width, h = self.item_height },
      button,
    }
  end
  self.left_cell = arrow_cell(self.prev)
  self.right_cell = arrow_cell(self.next)

  self.holder = FrameContainer:new {
    bordersize = 0,
    padding = 0,
    margin = 0,
    HorizontalGroup:new {},
  }

  -- the section heading with its firm rule, and the book count at its end
  self.widget = VerticalGroup:new { align = "left" }
  table.insert(self.widget, Theme.sectionHeader(self.card.title, width, TextWidget:new {
    text = self.card.subtitle,
    face = Theme.face("small"),
    max_width = width,
    fgcolor = Theme.DARK_GREY,
  }))
  table.insert(self.widget, Theme.span("m"))
  table.insert(self.widget, self.holder)
end

-- One cover with its number, title and status, as a cell of fixed size.
function SeriesCarousel:buildItem(item)
  local thick, thin = Size.border.thick, Size.border.thin
  -- the book on screen gets the heavy frame; the others get padding in its
  -- place, so every cover is the same outer size
  local box = CoverBox:new {
    width = self.cover_width,
    height = self.cover_height,
    border = item.current and thick or thin,
    padding = item.current and 0 or (thick - thin),
  }
  self.boxes[#self.boxes + 1] = { box = box, url = item.cover and item.cover.url }

  local group = VerticalGroup:new { align = "center" }
  table.insert(group, box:widget())
  table.insert(group, VerticalSpan:new { width = 4 })
  local number = TextWidget:new {
    text = item.number,
    face = self.card.title_first and self.status_face or self.number_face,
    bold = not self.card.title_first,
    max_width = self.text_width,
  }
  local title = TextBoxWidget:new {
    text = item.title,
    face = self.title_face,
    bold = item.current or self.card.title_first,
    width = self.text_width,
    height = self.title_height,
    height_overflow_show_ellipsis = true,
    alignment = "center",
  }
  -- a series strip puts the book's number first, then its title; a strip of other
  -- books (card.title_first) puts the bold title first, then the line under it (the author)
  if self.card.title_first then
    table.insert(group, title)
    table.insert(group, number)
  else
    table.insert(group, number)
    table.insert(group, title)
  end
  -- a space, not nothing, so a book with no status takes the same room
  table.insert(group, TextWidget:new {
    text = item.status or " ",
    face = self.status_face,
    max_width = self.text_width,
  })

  local cell = CenterContainer:new {
    dimen = Geom:new { w = self.item_width, h = self.item_height or group:getSize().h },
    group,
  }

  if item.current then
    return cell
  end

  return TapRow:new {
    viewport = self.viewport,
    callback = function()
      if self.on_open then self.on_open(item.book_id) end
    end,
    cell,
  }
end

-- Lay out the current page of the strip, in place.
function SeriesCarousel:render()
  self:releaseBoxes()

  local items = self.card.items
  local window = Shelf.carouselWindow(#items, self.per_page, self.first, self.card.current_index)
  self.first = window.first
  self.last = window.last

  local row = HorizontalGroup:new { align = "center" }
  -- the tappable covers on this page, in order (the book on screen is not one)
  self.targets = {}
  table.insert(row, self.left_cell)
  for i = window.first, window.last do
    local cell = self:buildItem(items[i])
    if not items[i].current then self.targets[#self.targets + 1] = cell end
    table.insert(row, cell)
  end
  -- a short page is padded so the strip is always the same width
  for _ = window.last - window.first + 2, self.per_page do
    table.insert(row, HorizontalSpan:new { width = self.item_width })
  end
  table.insert(row, self.right_cell)
  self.holder[1] = row

  if self.paged then
    if window.has_prev then self.prev:enable() else self.prev:disable() end
    if window.has_next then self.next:enable() else self.next:disable() end
  end

  self:loadCovers()
end

-- Turn the page: -1 for earlier books, 1 for later ones.
function SeriesCarousel:turn(direction)
  self.first = self.first + direction * self.per_page
  self:render()
  if self.on_change then self.on_change(function() return self.holder.dimen end) end
end

-- Ask for the covers on this page, in one batch.
function SeriesCarousel:loadCovers()
  if not self.image_loader then return end

  local urls, boxes_by_url = {}, {}
  for _, entry in ipairs(self.boxes) do
    if entry.url then
      if not boxes_by_url[entry.url] then
        boxes_by_url[entry.url] = {}
        urls[#urls + 1] = entry.url
      end
      table.insert(boxes_by_url[entry.url], entry.box)
    end
  end
  if #urls == 0 then return end

  local generation = self.generation
  local _, halt = self.image_loader:loadImages(urls, function(url, content)
    -- the page was turned (or the screen closed) while this was on its way
    if generation ~= self.generation then return end
    for _, box in ipairs(boxes_by_url[url] or {}) do
      if box:setImage(content) and self.on_change then
        self.on_change(function() return box.frame.dimen end)
      end
    end
  end)
  self.halt = halt
end

-- Stop fetching and give back the pictures on the current page.
function SeriesCarousel:releaseBoxes()
  self.generation = self.generation + 1
  if self.halt then
    self.halt()
    self.halt = nil
  end
  for _, entry in ipairs(self.boxes) do
    entry.box:release()
  end
  self.boxes = {}
end

-- For the owner to call when it goes away.
function SeriesCarousel:release()
  self:releaseBoxes()
end

return SeriesCarousel
