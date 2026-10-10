-- A list of books on a screen of its own: a shelf, one of your lists, a vibe's ranking, "For you",
-- search results. Selecting a row opens the book's details.
--
-- Built on our own widgets, a page at a time (mock 3): the top bar (back arrow, the short title, the
-- sort icon on a shelf, a reload icon where the screen can be refreshed), fixed-height rows (cover,
-- title, author, a chevron), the scroll control at the right edge stepping by page, and a footer saying
-- which books are on show. Only the page on screen is built, so a shelf of hundreds of books costs the
-- same as one of twenty, and only its covers are decoded. Rows past what is loaded come with a
-- "Load more" block at the end of the last page.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local CoverCells = require("hardcover/lib/ui/cover_cells")
local Draw = require("hardcover/lib/ui/components/draw")
local ListRow = require("hardcover/lib/ui/list_row")
local Popover = require("hardcover/lib/ui/components/popover")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Shelf = require("hardcover/lib/shelf")
local ShelfSort = require("hardcover/lib/shelf_sort")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen
local px = Theme.px

-- every row of a list is the same height, so the lines sit in the same place on every page; a list
-- with a "Because you liked" line under each book has room for it
local ROW_H = px(92)
local ROW_H_REASON = px(112)
local COVER_W, COVER_H = px(46), px(68)
local FOOTER_H = px(40)
local SIDE = px(16)

local ShelfDialog = FocusManager:extend {
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
  -- (kept so callers need not change; this screen has one look)
  compatibility_mode = true,
  -- a shelf can be re-ordered (search results are in relevance order and cannot): the sort icon is
  -- then in the top bar, `sort_key` is the order, and `on_sort_change(key)` is told when it changes so
  -- it can be remembered
  sortable = false,
  sort_key = nil,
  on_sort_change = nil,
  -- more things the screen can do, { { text, callback }, ... } (a list's Refresh): each is an icon
  -- in the top bar
  actions = nil,
}

-- The rating of the row, "4" or "4.5", or nil when it is not rated.
local function ratingText(entry)
  local rating = tonumber(entry.user_rating)
  if not rating or rating <= 0 then return nil end
  return rating % 1 == 0 and string.format("%d", rating) or string.format("%.1f", rating)
end

-- The data of a row: what the list shows of an entry.
function ShelfDialog:createListItem(entry)
  local item = ListRow.row(entry, { compatibility_mode = false, year = false })
  item.rating = ratingText(entry)
  item.rank = entry.rank
  -- "For you": why it was suggested
  if type(entry.reason) == "string" and entry.reason ~= "" then
    item.reason = string.format(_("Because you liked %s"), entry.reason)
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
  self.page = self.page or 1

  self.width = Screen:getWidth()
  self.height = Screen:getHeight()
  self.dimen = Geom:new { x = 0, y = 0, w = self.width, h = self.height }
  self.closed = false

  self.key_events.CloseShelf = { { "Back" } }
  if Device:hasKeys() then
    self.key_events.NextPage = { { Device.input.group.PgFwd } }
    self.key_events.PrevPage = { { Device.input.group.PgBack } }
  end
  if Device:isTouchDevice() then
    self.ges_events = {
      -- a swipe up pages on, down pages back (the triangles do the same)
      SwipeShelf = { GestureRange:new { ges = "swipe", range = function() return self.dimen end } },
    }
  end

  -- pictures already decoded are kept across pages and rebuilds (see cover_cells.lua)
  self.covers = CoverCells:new {
    window = self,
    loader = function() return self.image_loader or require("hardcover/lib/ui/image_loader") end,
    clip = function() return self.body_region end,
  }
  self:build()
end

-- the title, with the order when it is not the usual one
function ShelfDialog:displayTitle()
  if self.sortable and self.sort_key and self.sort_key ~= ShelfSort.DEFAULT and ShelfSort.isKey(self.sort_key) then
    return self.title .. " \194\183 " .. ShelfSort.label(self.sort_key)
  end
  return self.title
end

-- Everything the list shows, in order: a row for each entry (in the chosen sort), then the
-- "Load more" block when the shelf is not all here yet.
function ShelfDialog:buildItems()
  local entries = self.entries or {}
  if self.sortable then entries = ShelfSort.sort(entries, self.sort_key) end
  local items = {}
  for _i, entry in ipairs(entries) do
    local row = self:createListItem(entry)
    items[#items + 1] = { kind = "book", row = row, entry = entry, rating = row.rating, rank = row.rank, reason = row.reason }
  end
  if self.has_more and self.fetch_page and #items > 0 then
    items[#items + 1] = { kind = "more" }
  end
  return items
end

-- How many rows fit a page under the top bar and over the footer.
function ShelfDialog:rowsPerPage(body_h)
  return math.max(1, math.floor((body_h - FOOTER_H) / self.row_h))
end

-- One row: a rank numeral on a ranked list, the cover, the title over the author (and why, on a
-- suggestion), your rating, a chevron, and a dotted rule below.
function ShelfDialog:buildRow(item, width)
  local inner_h = self.row_h - Theme.line.hair
  local row = item.row
  local line = HorizontalGroup:new { align = "center", Theme.hspan(SIDE) }

  local numeral_w = px(40)
  if item.rank then
    table.insert(line, LeftContainer:new {
      dimen = Geom:new { w = numeral_w, h = inner_h },
      Theme.mmdText(tostring(item.rank), "strong", 30, { width = numeral_w }),
    })
  end
  table.insert(line, self.covers:cell(row.cover_url, COVER_W, COVER_H))
  table.insert(line, Theme.hspan(SIDE))

  -- the right-hand end: your rating, then the chevron
  local trailing = HorizontalGroup:new { align = "center" }
  if item.rating then
    table.insert(trailing, Theme.icon("star-filled", px(18)))
    table.insert(trailing, Theme.hspan(px(4)))
    table.insert(trailing, Theme.mmdText(item.rating, "strong", 18))
    table.insert(trailing, Theme.hspan(px(12)))
  end
  table.insert(trailing, Draw.chevron("right"))

  local used = SIDE + (item.rank and numeral_w or 0) + COVER_W + SIDE + trailing:getSize().w + SIDE + SIDE
  local text_w = math.max(px(60), width - used)
  local column = VerticalGroup:new { align = "left",
    Theme.mmdText(row.title or row.text or "", "strong", 21, { width = text_w }) }
  if row.authors then
    table.insert(column, Theme.span(px(3)))
    table.insert(column, Theme.mmdText(row.authors, "text", 18, { width = text_w, secondary = true }))
  end
  if item.reason then
    table.insert(column, Theme.span(px(3)))
    table.insert(column, Theme.mmdText(item.reason, "text", 15, { width = text_w, secondary = true }))
  end
  table.insert(line, LeftContainer:new { dimen = Geom:new { w = text_w, h = inner_h }, column })
  table.insert(line, trailing)
  table.insert(line, Theme.hspan(SIDE))

  local tap = TapRow:new {
    callback = function()
      if self.select_entry_cb then self.select_entry_cb(item.entry) end
    end,
    CenterContainer:new { dimen = Geom:new { w = width, h = inner_h }, line },
  }
  item.tap = tap
  return VerticalGroup:new { align = "left", tap, Theme.dottedRule(width) }
end

-- The block that asks for the rest of a shelf that is not all here.
function ShelfDialog:buildMore(width)
  local inner_h = self.row_h - Theme.line.hair
  self.more_button = Button.new {
    label = _("Load more books"), w = width - 2 * SIDE, h = Theme.TOUCH_MIN, size = 19,
    callback = function() self:loadMore() end,
  }
  return VerticalGroup:new { align = "left",
    CenterContainer:new { dimen = Geom:new { w = width, h = inner_h }, self.more_button },
    Theme.dottedRule(width),
  }
end

function ShelfDialog:build()
  local sw, sh = self.width, self.height

  -- the top bar: back, the title, then the sort icon (a shelf) and one icon per action (Refresh)
  local actions = {}
  if self.sortable then
    actions[#actions + 1] = { icon = "sort", callback = function() self:showSortMenu() end }
  end
  for _i, action in ipairs(type(self.actions) == "table" and self.actions or {}) do
    actions[#actions + 1] = { icon = action.icon or "sync", callback = action.callback }
  end
  local bar = TopBar.new {
    width = sw, title = self:displayTitle(), on_back = function() self:onClose() end, actions = actions,
  }
  self.title_bar = bar
  self.close_button = bar.back_button
  self.sort_button = self.sortable and bar.action_buttons[1] or nil
  local body_h = sh - bar:getSize().h

  self.items = self:buildItems()
  self.row_h = ROW_H
  for _i, item in ipairs(self.items) do
    if item.reason then self.row_h = ROW_H_REASON break end
  end
  self.per_page = self:rowsPerPage(body_h)
  self.pages = math.max(1, math.ceil(#self.items / self.per_page))
  self.page = math.max(1, math.min(self.page or 1, self.pages))
  self.body_region = Geom:new { x = 0, y = bar:getSize().h, w = sw, h = body_h }

  local width = self.pages > 1 and (sw - ScrollControl.gutter()) or sw
  self.rows = {}
  self.more_button = nil
  self.covers:begin()

  local list = VerticalGroup:new { align = "left" }
  if self.empty_state then
    table.insert(list, CenterContainer:new { dimen = Geom:new { w = sw, h = body_h },
      Theme.mmdText(self.empty_state, "text", 21, { width = sw - 2 * Theme.margin, secondary = true }) })
  else
    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(#self.items, first + self.per_page - 1)
    for i = first, last do
      local item = self.items[i]
      if item.kind == "more" then
        table.insert(list, self:buildMore(width))
      else
        table.insert(list, self:buildRow(item, width))
        self.rows[#self.rows + 1] = item.tap
      end
    end
    -- the footer sits at the same place on every page, under the rows' space
    local shown_first, shown_last = 0, 0
    for i = first, last do
      if self.items[i].kind == "book" then
        shown_first = shown_first == 0 and i or shown_first
        shown_last = i
      end
    end
    if shown_first > 0 then
      local total = tostring(#self.entries) .. (self.has_more and "+" or "")
      local room = self.per_page * self.row_h
      table.insert(list, Theme.span(room - (last - first + 1) * self.row_h + px(8)))
      table.insert(list, HorizontalGroup:new { Theme.hspan(SIDE),
        Theme.mmdText(string.format(_("Showing %d to %d of %s"), shown_first, shown_last, total), "text", 15,
          { secondary = true, width = width - 2 * SIDE }) })
    end
  end
  self.list = list

  local content = list
  if self.pages > 1 then
    local control = ScrollControl.paged {
      height = body_h,
      pages = function() return self.pages end,
      page = function() return self.page end,
      go = function(page) self:setPage(page) end,
    }
    control.overlap_offset = { sw - ScrollControl.gutter(), 0 }
    self.control = control
    content = OverlapGroup:new { dimen = Geom:new { w = sw, h = body_h }, allow_mirroring = false, list, control }
  else
    self.control = nil
  end
  self.covers:finish()

  self.frame = FrameContainer:new {
    width = sw, height = sh, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", bar, content },
  }
  self[1] = self.frame

  -- keyboard / d-pad focus: the rows on this page, then Close
  self.layout = {}
  for _i, row in ipairs(self.rows) do table.insert(self.layout, { row }) end
  if self.more_button then table.insert(self.layout, { self.more_button }) end
  table.insert(self.layout, { self.close_button })
end

-- Show page `n` (clamped): only the list changes, so only its area is refreshed.
function ShelfDialog:setPage(n)
  local page = math.max(1, math.min(n, self.pages))
  if page == self.page then return end
  self.page = page
  self:rebuild(false)
end

function ShelfDialog:onNextPage()
  self:setPage(self.page + 1)
  return true
end

function ShelfDialog:onPrevPage()
  self:setPage(self.page - 1)
  return true
end

function ShelfDialog:onSwipeShelf(_, ges)
  if not (ges and ges.direction) then return false end
  if ges.direction == "north" then
    self:setPage(self.page + 1)
    return true
  elseif ges.direction == "south" then
    self:setPage(self.page - 1)
    return true
  end
  return false
end

-- Build again from the current state. `whole == false` repaints just the list, else the whole screen
-- (the title may have changed).
function ShelfDialog:rebuild(whole)
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  if whole == false then
    local region = self.body_region
    UIManager:setDirty(self, function() return "ui", region end)
  else
    UIManager:setDirty(self, "ui")
  end
end

--
-- Replace the rows after the first page lands.
--
-- The dialog is built and shown empty, so this is what fills it. `keep_position` stays on the page
-- being viewed (rows that arrive while the reader is already browsing must not send them back to
-- page one); otherwise it goes back to the first.
--
function ShelfDialog:setEntries(entries, has_more, keep_position)
  self.entries = entries or {}
  self.has_more = has_more and #self.entries > 0
  self.empty_state = nil
  if not keep_position then self.page = 1 end
  self:rebuild()
end

--
-- An empty shelf is a real answer, not a failure: a line saying so, where the rows would be. Without
-- it the screen is a title bar over a blank list, which reads as a bug rather than as "you have not
-- added anything here yet".
--
function ShelfDialog:setEmptyState(message)
  self.empty_state = message
  self.has_more = false
  self.entries = {}
  self.page = 1
  self:rebuild()
end

--
-- The sort menu: every order of a shelf, the current one ticked, in a popover under the sort icon.
--
function ShelfDialog:showSortMenu()
  if self.sort_menu then
    self.sort_menu:close()
    self.sort_menu = nil
  end
  local current = self.sort_key or ShelfSort.DEFAULT
  local items = {}
  for _i, option in ipairs(ShelfSort.OPTIONS) do
    items[#items + 1] = {
      label = option.label,
      current = option.key == current,
      callback = function()
        self.sort_menu = nil
        self:setSort(option.key)
      end,
    }
  end
  -- under the sort icon, at the right edge of the screen
  local bar_h = self.title_bar:getSize().h
  local anchor = self.sort_button and self.sort_button.dimen
  local x = anchor and anchor.x and (anchor.x + anchor.w) or (self.width - px(8))
  self.sort_menu = Popover.show {
    items = items, x = math.min(self.width - px(8), x), y = bar_h, width = math.min(px(420), self.width - px(16)),
    on_dismiss = function() self.sort_menu = nil end,
  }
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
  self.page = 1
  self:rebuild()
end

--
-- Fetch the next page and append it. Guarded by self.loading so a double tap
-- cannot fire two overlapping requests. The new rows start on the next page.
--
function ShelfDialog:loadMore()
  if self.loading or not self.has_more or not self.fetch_page then
    return
  end

  self.loading = true

  local page_offset = self.offset
  self.fetch_page(page_offset, self.page_size, function(entries, err, has_more)
    self.loading = false
    if self.closed then return end

    if err or not entries then
      StatusDialogs.error(_("Could not load more books"))
      return
    end

    local before = #self.entries
    self.offset = page_offset + #entries
    self.entries = Shelf.appendPage(self.entries, entries, has_more and #entries > 0)
    self.has_more = has_more and #entries > 0 or false
    -- on to the first of the new rows
    self.page = math.floor(before / self.per_page) + 1
    self:rebuild()
  end)
end

function ShelfDialog:onCloseWidget()
  self.closed = true
  self.covers:release()
  UIManager:setDirty(nil, "ui")
end

function ShelfDialog:onCloseShelf()
  return self:onClose()
end

function ShelfDialog:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

return ShelfDialog
