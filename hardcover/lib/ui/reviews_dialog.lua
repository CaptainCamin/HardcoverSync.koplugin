-- Other readers' reviews of one book: a full-screen list, a few reviews to a page.
--
-- A stock Menu with multi-line rows, paged with its own footer arrows, so there
-- is no scrolling container and no shifted tap ranges to clip (see
-- viewport.lua for the trouble those cause). Each row is one review: who, the
-- stars, the likes, then an excerpt. Tapping a row does the one useful thing
-- for it:
--
--   * a spoiler that is still hidden: reveals it (a Contains-spoilers row until
--     then, and hidden again whenever the list is rebuilt from scratch);
--   * a long review: opens the whole text in a scrollable viewer;
--   * the last row, "Load more reviews": fetches the next page.
--
-- The dialog fetches nothing itself. `fetch_page(offset, limit, callback)` is
-- supplied by DialogManager, which owns the offline check and the retry.
--
-- Row text and what each tap does come from hardcover/lib/reviews.lua.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Reviews = require("hardcover/lib/reviews")

local Screen = Device.screen

local ReviewsDialog = InputContainer:extend {
  name = "hardcover_reviews_dialog",
  title = _("Reviews"),
  reviews = nil,       -- normalised (Reviews.normalize), in display order
  message = nil,       -- a single non-interactive row: loading, empty
  has_more = false,
  loading = false,
  offset = 0,          -- how many rows the server has already given us
  page_size = Reviews.PAGE_SIZE,
  fetch_page = nil,    -- function(offset, limit, callback(rows, err))
  close_callback = nil,
}

function ReviewsDialog:init()
  self.reviews = self.reviews or {}
  self.revealed = self.revealed or {}
  self.width = Screen:getWidth()
  self.height = Screen:getHeight()

  self.menu = Menu:new {
    -- Rows wrap at a fixed font and are cut with an ellipsis if they overflow
    -- (multilines_forced: no shrinking the font to fit, no single-line mode).
    single_line = false,
    multilines_forced = true,
    -- four tall rows: a headline, an excerpt of about six lines and a "Read
    -- more" line fit in one at the default panel size
    items_per_page = 4,
    items_font_size = 20,
    is_enable_shortcut = false,
    title = self.title,
    fullscreen = true,
    is_borderless = true,
    is_popout = false,
    item_table = self:buildItems(),
    width = self.width,
    height = self.height,
    onMenuSelect = function(_, item) self:onSelectItem(item) end,
    close_callback = function() self:onClose() end,
  }

  self.container = CenterContainer:new {
    dimen = Screen:getSize(),
    self.menu,
  }
  self.menu.show_parent = self
  self[1] = self.container
end

-- Rows for the current state. `mandatory` is always a string: Menu draws it
-- unconditionally and a nil there aborts the whole page.
function ReviewsDialog:buildItems()
  local items = {}
  if self.message then
    items[1] = { text = self.message, mandatory = "", dim = true }
    return items
  end

  for _, review in ipairs(self.reviews) do
    local text, action = Reviews.rowText(review, self.revealed[review.id or review])
    items[#items + 1] = { text = text, mandatory = "", review = review, action = action }
  end
  if self.has_more then
    items[#items + 1] = {
      text = self.loading and _("Loading reviews\226\128\166") or _(Reviews.LOAD_MORE),
      mandatory = "",
      action = "more",
    }
  end
  return items
end

-- Swap in the current rows. `item_number` keeps the reader on a page;
-- switchItemTable otherwise goes back to the first one.
function ReviewsDialog:refresh(item_number)
  self.menu:switchItemTable(self.title, self:buildItems(), item_number)
  UIManager:setDirty(self, "ui")
end

-- The number of the row on the page being viewed, to stay on it across a rebuild.
function ReviewsDialog:currentItemNumber()
  if self.menu.page and self.menu.perpage then
    return (self.menu.page - 1) * self.menu.perpage + 1
  end
end

-- A single message in place of the list: "Loading reviews...", "No reviews yet".
function ReviewsDialog:setMessage(message)
  self.message = message
  self.has_more = false
  self:refresh()
end

--
-- Show the first page, or append a later one.
--
-- `rows` is Reviews.normalizeAll's result; `raw_count` is how many rows the
-- server returned (the page may be longer than what is shown if a row had no
-- text), which is what decides whether there may be more.
--
function ReviewsDialog:addPage(rows, raw_count, offset)
  self.message = nil
  local first_new = #self.reviews + 1
  self.reviews = Reviews.appendPage(self.reviews, rows)
  self.offset = offset + (raw_count or #rows)
  self.has_more = Reviews.hasMore(raw_count, self.page_size)

  if #self.reviews == 0 then
    self:setMessage(_("No reviews yet"))
    return
  end

  -- go to the first row of what just arrived when it is a later page
  local item_number = first_new > 1 and first_new or nil
  self:refresh(item_number)
end

function ReviewsDialog:onSelectItem(item)
  if not item or self.message then return end

  if item.action == "more" then
    self:loadMore()
  elseif item.action == "reveal" then
    self.revealed[item.review.id or item.review] = true
    self:refresh(self:currentItemNumber())
  elseif item.action == "full" then
    self:showFull(item.review)
  end
end

-- The whole review in a scrollable viewer, over this list.
function ReviewsDialog:showFull(review)
  UIManager:show(TextViewer:new {
    title = Reviews.headline(review),
    text = review.text,
    width = self.width,
    height = self.height,
    justified = false,
  })
end

--
-- Fetch the next page. Guarded so a double tap cannot fire two requests.
--
function ReviewsDialog:loadMore()
  if self.loading or not self.has_more or not self.fetch_page then return end

  self.loading = true
  local page = self:currentItemNumber()
  self:refresh(page)

  local offset = self.offset
  self.fetch_page(offset, self.page_size, function(rows, err, raw_count)
    self.loading = false
    if err or not rows then
      -- put the "Load more" row back; DialogManager offers the retry
      self:refresh(page)
      return
    end
    self:addPage(rows, raw_count, offset)
  end)
end

function ReviewsDialog:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

return ReviewsDialog
