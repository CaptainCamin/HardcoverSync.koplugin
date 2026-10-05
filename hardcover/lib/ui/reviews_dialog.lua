-- Other readers' reviews of one book: a full-screen list of review cards, as
-- many to a page as fit, paged with Previous / Next.
--
-- Not a Menu any more and not scrolled: the cards are laid out whole (name,
-- stars, date, the excerpt, likes and a Read more button), measured, and dealt
-- out into pages, so every tappable thing is where it is drawn and there are no
-- shifted tap ranges to clip (see viewport.lua for the trouble those cause).
--
-- The model is `self.items`, one entry per card (plus a last "Load more" one),
-- exactly what the Menu rows were: { text, review, action }. Tapping what a
-- card offers does the one useful thing for it:
--
--   * a spoiler that is still hidden: reveals it (a Contains-spoilers bar until
--     then, and hidden again whenever the list is rebuilt from scratch);
--   * a long review: Read more opens the whole text in a scrollable viewer;
--   * the last card, "Load more reviews": fetches the next page.
--
-- The dialog fetches nothing itself. `fetch_page(offset, limit, callback)` is
-- supplied by DialogManager, which owns the offline check and the retry. An
-- optional `summary` ({ title, rating, count }, from Reviews.summary) heads the
-- first page: the book and how it is rated: the figure, the star glyphs and, when the
-- book has the tallies, how many readers gave each rating (a histogram).
--
-- Row text and what each tap does come from hardcover/lib/reviews.lua.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Reviews = require("hardcover/lib/reviews")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local ReviewsDialog = InputContainer:extend {
  name = "hardcover_reviews_dialog",
  title = _("Reviews"),
  summary = nil,       -- { title, rating, count, distribution }: the book, shown above page one
  hint = nil,          -- a small grey note under the summary
  reviews = nil,       -- normalised (Reviews.normalize), in display order
  message = nil,       -- a single non-interactive message: loading, empty
  has_more = false,
  loading = false,
  offset = 0,          -- how many rows the server has already given us
  page_size = Reviews.PAGE_SIZE,
  fetch_page = nil,    -- function(offset, limit, callback(rows, err))
  close_callback = nil,
  page = 1,
}

function ReviewsDialog:init()
  self.reviews = self.reviews or {}
  self.revealed = self.revealed or {}
  self.width = Screen:getWidth()
  self.height = Screen:getHeight()
  self.page = 1
  self.dimen = Geom:new { x = 0, y = 0, w = self.width, h = self.height }

  self.key_events.CloseReviews = { { "Back" } }
  self.key_events.NextPage = { { "RPgFwd" } }
  self.key_events.PrevPage = { { "RPgBack" } }
  if Device:isTouchDevice() then
    -- a swipe turns the page, as in every other list
    self.ges_events = self.ges_events or {}
    self.ges_events.Swipe = {
      GestureRange:new { ges = "swipe", range = self.dimen },
    }
  end

  self.title_bar = Theme.titleBar {
    title = self.title,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }
  self.close_button = self.title_bar.right_button

  self:refresh()
end

-- The model: one item per card, then the Load more item when there is more.
-- (`mandatory` is gone with the Menu it was for.)
function ReviewsDialog:buildItems()
  local items = {}
  if self.message then
    items[1] = { text = self.message, message = true }
    return items
  end

  for _, review in ipairs(self.reviews) do
    local text, action = Reviews.rowText(review, self.revealed[review.id or review])
    items[#items + 1] = { text = text, review = review, action = action }
  end
  if self.has_more then
    items[#items + 1] = {
      text = self.loading and _("Loading reviews\226\128\166") or _(Reviews.LOAD_MORE),
      action = "more",
    }
  end
  return items
end

------------------------------------------------------------------ the cards

local text = Theme.text

local function rowOf(left, right, width)
  local gap = math.max(0, width - left:getSize().w - right:getSize().w)
  return HorizontalGroup:new { align = "center", left, Theme.hspan(gap), right }
end

-- One review: who, stars and date; the excerpt (or the spoiler bar); likes and
-- Read more.
function ReviewsDialog:buildCard(item, width)
  local review = item.review
  local card = VerticalGroup:new { align = "left" }
  table.insert(card, Theme.rule(width, false))
  table.insert(card, Theme.span("m"))

  -- the head: name and stars at the left, the date at the right
  local date = review.date and text(review.date, "small", { grey = true }) or nil
  local date_w = date and (date:getSize().w + Theme.space.m) or 0
  local stars = review.rating_value and text(
    "\226\152\133 " .. (review.rating:gsub("%*$", "")), "body", { bold = true }) or nil
  local stars_w = stars and (stars:getSize().w + Theme.space.m) or 0
  local name = text(review.reviewer, "title", { bold = true, width = width - date_w - stars_w })
  local head = HorizontalGroup:new { align = "center", name }
  if stars then
    table.insert(head, Theme.hspan("m"))
    table.insert(head, stars)
  end
  if date then
    table.insert(card, rowOf(head, date, width))
  else
    table.insert(card, head)
  end
  table.insert(card, Theme.span("s"))

  -- the body
  local hidden = review.has_spoilers and not self.revealed[review.id or review]
  if hidden then
    table.insert(card, Theme.button(Reviews.SPOILER_PROMPT, width, {
      h = Screen:scaleBySize(46),
      callback = function() self:onSelectItem(item) end,
    }))
  else
    table.insert(card, TextBoxWidget:new {
      text = review.excerpt,
      face = Theme.face("body"),
      width = width,
      alignment = "left",
    })
  end
  table.insert(card, Theme.span("s"))

  -- the foot: likes, and Read more when there is more to read
  local likes = text(review.likes or " ", "small", { bold = true })
  local more
  if review.truncated and not hidden then
    more = Theme.button(_(Reviews.READ_MORE), Screen:scaleBySize(110), {
      h = Screen:scaleBySize(46),
      callback = function() self:showFull(review) end,
    })
  end
  if more then
    table.insert(card, rowOf(likes, more, width))
  else
    table.insert(card, likes)
  end
  table.insert(card, Theme.span("m"))
  return card
end

-- The Load more card: one full-width button.
function ReviewsDialog:buildMore(item, width)
  local button = Theme.button(item.text, width, {
    h = Theme.BUTTON_H,
    callback = function() self:onSelectItem(item) end,
  })
  return VerticalGroup:new {
    align = "left",
    Theme.rule(width, false),
    Theme.span("m"),
    button,
    Theme.span("m"),
  }
end

-- The book and its rating, above the first card.
function ReviewsDialog:buildSummary(width)
  local summary = self.summary
  if type(summary) ~= "table" and not self.hint then return nil end
  summary = type(summary) == "table" and summary or {}
  local group = VerticalGroup:new { align = "left" }
  if summary.title then
    table.insert(group, Theme.sectionHeader(summary.title, width))
    table.insert(group, Theme.span("m"))
  end
  if summary.rating then
    local figure = text(string.format("%.1f", summary.rating), "display", { bold = true })
    local label = summary.count
      and string.format(_("%d ratings"), summary.count) or _("rating")
    local beside = VerticalGroup:new {
      align = "left",
      text(Reviews.stars(summary.rating), "title"),
      text(label, "small", { grey = true, width = width }),
    }
    table.insert(group, HorizontalGroup:new { align = "center", figure, Theme.hspan("l"), beside })
    table.insert(group, Theme.span("m"))
  end
  -- how the ratings are spread, with the average marked
  local dist = summary.distribution
  if dist then
    local ChartWidgets = require("hardcover/lib/ui/chart_widgets")
    table.insert(group, ChartWidgets.columns {
      width = width, height = Theme.px(150), values = dist.counts,
      labels = { "0.5", "1", "1.5", "2", "2.5", "3", "3.5", "4", "4.5", "5" },
      marker = { at = dist.average * 2, text = string.format(_("avg %.1f"), dist.average) },
    })
    table.insert(group, Theme.span("m"))
  end
  -- a note about the screen itself (reviewers' names are hidden until the
  -- reader signs in again)
  if self.hint then
    table.insert(group, text(self.hint, "small", { grey = true, width = width }))
    table.insert(group, Theme.span("m"))
  end
  return group
end

------------------------------------------------------------------ the pages

-- Lay every card out, then deal them into pages that fit. Rebuilt whenever the
-- items change; turning a page only re-assembles the cards already built.
function ReviewsDialog:layout()
  local M = Theme.margin
  local width = self.width - 2 * M
  self.items = self:buildItems()

  self.pager_h = Theme.BUTTON_H + Theme.space.m * 2
  local room = self.height - self.title_bar:getSize().h - self.pager_h

  self.pages = {}
  if self.message then
    self.pages[1] = { widgets = {}, message = self.message }
    return
  end

  local summary = self:buildSummary(width)
  local current = { widgets = {}, first = 1 }
  local used = 0
  if summary then
    current.summary = summary
    used = summary:getSize().h
  end
  for i, item in ipairs(self.items) do
    local widget = item.review and self:buildCard(item, width) or self:buildMore(item, width)
    local h = widget:getSize().h
    -- a card that does not fit starts the next page (unless it is the only one)
    if used + h > room and #current.widgets > 0 then
      self.pages[#self.pages + 1] = current
      current = { widgets = {}, first = i }
      used = 0
    end
    table.insert(current.widgets, widget)
    current.last = i
    used = used + h
  end
  self.pages[#self.pages + 1] = current
  self.page = math.max(1, math.min(self.page, #self.pages))
end

-- Show page `n` of the cards in the dialog's frame.
function ReviewsDialog:showPage(n)
  local M = Theme.margin
  local width = self.width - 2 * M
  self.page = math.max(1, math.min(n or self.page, #self.pages))
  local page = self.pages[self.page]

  local body = VerticalGroup:new { align = "left" }
  local body_h = self.height - self.title_bar:getSize().h - self.pager_h
  if page.message then
    table.insert(body, CenterContainer:new {
      dimen = Geom:new { w = self.width, h = body_h },
      text(page.message, "body", { grey = true, width = width }),
    })
  else
    table.insert(body, Theme.span("m"))
    if page.summary then table.insert(body, page.summary) end
    for _, widget in ipairs(page.widgets) do table.insert(body, widget) end
  end
  body:resetLayout()

  -- the pager: Previous at the left, where you are in the middle, Next at the
  -- right; an end that has nowhere to go is left blank
  local button_w = Screen:scaleBySize(120)
  local pager = HorizontalGroup:new { align = "center" }
  local function slot(button)
    return button or Theme.hspan(button_w)
  end
  local has_prev, has_next = self.page > 1, self.page < #self.pages
  self.prev_button = has_prev and Theme.button(_("Previous"), button_w, {
    callback = function() self:showPage(self.page - 1); UIManager:setDirty(self, "ui") end,
  }) or nil
  self.next_button = has_next and Theme.button(_("Next"), button_w, {
    callback = function() self:showPage(self.page + 1); UIManager:setDirty(self, "ui") end,
  }) or nil
  local label = text(string.format(_("Page %d of %d"), self.page, #self.pages), "small", { bold = true })
  local middle_w = width - 2 * button_w
  table.insert(pager, slot(self.prev_button))
  table.insert(pager, CenterContainer:new {
    dimen = Geom:new { w = middle_w, h = Theme.BUTTON_H },
    label,
  })
  table.insert(pager, slot(self.next_button))
  self.page_label = label

  local footer = VerticalGroup:new {
    align = "left",
    HorizontalGroup:new { Theme.hspan(M), Theme.rule(width, true) },
    Theme.span("m"),
    HorizontalGroup:new { Theme.hspan(M), #self.pages > 1 and pager or Theme.span(Theme.BUTTON_H) },
  }

  self.body_h = body_h
  self.frame = FrameContainer:new {
    width = self.width,
    height = self.height,
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new {
      align = "left",
      self.title_bar,
      -- the body hangs from the top of its box, inset by the margin
      TopContainer:new {
        dimen = Geom:new { w = self.width, h = body_h },
        HorizontalGroup:new { Theme.hspan(M), body },
      },
      footer,
    },
  }
  self[1] = self.frame
end

-- Rebuild everything from the current state. `item_number` stays on the page
-- that holds that item; otherwise the current page is kept.
function ReviewsDialog:refresh(item_number)
  self:layout()
  if item_number then
    for n, page in ipairs(self.pages) do
      if page.first and item_number >= page.first and item_number <= (page.last or 0) then
        self.page = n
        break
      end
    end
  end
  self:showPage()
  UIManager:setDirty(self, "ui")
end

-- The number of the first item on the page being viewed, to stay on it across a
-- rebuild.
function ReviewsDialog:currentItemNumber()
  local page = self.pages and self.pages[self.page]
  return page and page.first
end

function ReviewsDialog:onNextPage()
  if self.pages and self.page < #self.pages then
    self:showPage(self.page + 1)
    UIManager:setDirty(self, "ui")
  end
  return true
end

function ReviewsDialog:onPrevPage()
  if self.pages and self.page > 1 then
    self:showPage(self.page - 1)
    UIManager:setDirty(self, "ui")
  end
  return true
end

function ReviewsDialog:onSwipe(_, ges)
  local direction = ges and ges.direction
  if direction == "west" then
    return self:onNextPage()
  elseif direction == "east" then
    return self:onPrevPage()
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

-- UIManager:close() queues no refresh of its own; without this the screen stays
-- on the panel after it has closed.
function ReviewsDialog:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

function ReviewsDialog:onCloseReviews()
  return self:onClose()
end

function ReviewsDialog:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

return ReviewsDialog
