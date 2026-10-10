-- Other readers' reviews of one book: one scrolling list under the MMD top bar.
--
-- The book and how it is rated come first (the figure, the stars and, when the book has the
-- tallies, a histogram with the average marked) and scroll away like the rest. Then one card per
-- review, every card the same height: who, stars and date, three lines of the text, likes, and a
-- Read more when there is more to read. Last comes a visible "Load more reviews" button while the
-- server has more, and "No more reviews" once everything is here. The page scrolls by whole blocks
-- with the scroll control (the same one every long screen uses); a dotted triangle means that end
-- is reached.
--
-- Tapping what a card offers does the one useful thing for it:
--
--   * a spoiler that is still hidden: reveals it (a Contains-spoilers bar until then, and hidden
--     again whenever the dialog is opened afresh);
--   * a long review: Read more opens the whole text on a screen of its own;
--   * the last block, "Load more reviews": fetches the next page, and the list grows where it is.
--
-- The dialog fetches nothing itself. `fetch_page(offset, limit, callback)` is supplied by
-- DialogManager, which owns the offline check and the retry. Row text and what each tap does come
-- from hardcover/lib/reviews.lua.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local Clamp = require("hardcover/lib/ui/clamp")
local Reviews = require("hardcover/lib/reviews")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

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
}

function ReviewsDialog:init()
  self.reviews = self.reviews or {}
  self.revealed = self.revealed or {}
  self.width = Screen:getWidth()
  self.height = Screen:getHeight()
  self.dimen = Geom:new { x = 0, y = 0, w = self.width, h = self.height }
  self.key_events.CloseReviews = { { "Back" } }
  self:refresh()
end

local text = Theme.text

local function rowOf(left, right, width)
  local gap = math.max(0, width - left:getSize().w - right:getSize().w)
  return HorizontalGroup:new { align = "center", left, Theme.hspan(gap), right }
end

-- five stars as icons, filled, half or outline for a rating (0.5 steps)
local function starRow(rating, size)
  local row = HorizontalGroup:new { align = "center" }
  for i = 1, 5 do
    local name = rating >= i and "star-filled" or (rating >= i - 0.5 and "star-half" or "star")
    row[#row + 1] = Theme.icon(name, size)
  end
  return row
end

local CARD_LINES = 3

-- The height one card is always given, so the cards line up and the page steps are even: the rule
-- and room above, the head line, three lines of text, the foot and room below.
function ReviewsDialog:cardMetrics(width)
  if self.metrics and self.metrics.width == width then return self.metrics end
  local face = Theme.face("body")
  local probe = TextBoxWidget:new { text = "A", face = face, width = width, alignment = "left" }
  local line_h = probe.line_height_px or math.floor(face.size * 1.3)
  probe:free()
  local head_h = text("Ag", "title", { bold = true }):getSize().h
  local foot_h = Screen:scaleBySize(48)
  local gap_s, gap_m = Theme.space.s, Theme.space.m
  self.metrics = {
    width = width, line_h = line_h, head_h = head_h, foot_h = foot_h,
    height = Theme.line.hair + gap_m + head_h + gap_s + CARD_LINES * line_h + gap_s + foot_h + gap_m,
  }
  return self.metrics
end

-- One review as a block of fixed height: who, stars and date; the clamped text (or the spoiler
-- bar); likes and Read more.
function ReviewsDialog:buildCard(review, width)
  local m = self:cardMetrics(width)
  local card = VerticalGroup:new { align = "left" }
  table.insert(card, Theme.rule(width, false))
  table.insert(card, Theme.span("m"))

  local date = review.date and text(review.date, "small", { grey = true }) or nil
  local date_w = date and (date:getSize().w + Theme.space.m) or 0
  local stars = review.rating_value and HorizontalGroup:new { align = "center",
    Theme.icon("star-filled", Theme.px(18)), Theme.hspan(Theme.px(4)),
    text((review.rating:gsub("%*$", "")), "body", { bold = true }) } or nil
  local stars_w = stars and (stars:getSize().w + Theme.space.m) or 0
  local name = text(review.reviewer, "title", { bold = true, width = width - date_w - stars_w })
  local head = HorizontalGroup:new { align = "center", name }
  if stars then
    table.insert(head, Theme.hspan("m"))
    table.insert(head, stars)
  end
  table.insert(card, date and rowOf(head, date, width) or head)
  table.insert(card, Theme.span("s"))

  local hidden = review.has_spoilers and not self.revealed[review.id or review]
  local cut = false
  local body_h = CARD_LINES * m.line_h
  if hidden then
    table.insert(card, TopContainer:new {
      dimen = Geom:new { w = width, h = body_h },
      Button.new {
        label = Reviews.SPOILER_PROMPT, w = width, h = Screen:scaleBySize(48), size = 18,
        callback = function()
          self.revealed[review.id or review] = true
          self:refresh()
        end,
      },
    })
  else
    local body
    body, cut = Clamp.text { text = review.excerpt, face = Theme.face("body"), width = width, lines = CARD_LINES }
    table.insert(card, TopContainer:new { dimen = Geom:new { w = width, h = body_h }, body })
  end
  table.insert(card, Theme.span("s"))

  -- the foot: likes, and Read more when there is more to read
  local likes = text(review.likes or " ", "small", { bold = true })
  local foot
  if (cut or review.truncated) and not hidden then
    local more = Button.new { label = _(Reviews.READ_MORE), w = Screen:scaleBySize(120), h = Screen:scaleBySize(40),
      size = 18, callback = function() self:showFull(review) end }
    foot = rowOf(likes, more, width)
  else
    foot = likes
  end
  table.insert(card, LeftContainer:new { dimen = Geom:new { w = width, h = m.foot_h }, foot })
  table.insert(card, Theme.span("m"))
  return card
end

-- The last block: a visible way to ask for more, or the word that there is none.
function ReviewsDialog:buildFooter(width)
  local group = VerticalGroup:new { align = "left", Theme.rule(width, false), Theme.span("m") }
  if self.has_more then
    table.insert(group, Button.new { label = self.loading and _("Loading reviews\226\128\166") or _(Reviews.LOAD_MORE),
      w = width, h = Screen:scaleBySize(56), callback = function() self:loadMore() end })
    self.more_button = group[#group]
  else
    self.more_button = nil
    local done = text(_("No more reviews"), "body", { grey = true })
    table.insert(group, Theme.span(math.floor((Theme.BUTTON_H - done:getSize().h) / 2)))
    table.insert(group, HorizontalGroup:new { Theme.hspan(math.max(0, math.floor((width - done:getSize().w) / 2))), done })
    table.insert(group, Theme.span(math.ceil((Theme.BUTTON_H - done:getSize().h) / 2)))
  end
  table.insert(group, Theme.span("xl"))
  return group
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
      starRow(summary.rating, Theme.px(22)),
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

-- The list as blocks, one child each, laid out in `width`.
function ReviewsDialog:buildContent(width)
  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("m"))
  local summary = self:buildSummary(width)
  if summary then table.insert(content, summary) end
  for _i, review in ipairs(self.reviews) do
    table.insert(content, self:buildCard(review, width))
  end
  table.insert(content, self:buildFooter(width))
  return content
end

-- Build the screen from the current state: a message, or the list (scrolling when it is longer
-- than the screen).
function ReviewsDialog:build()
  local M = Theme.margin
  local bar = TopBar.new { width = self.width, title = self.title, on_back = function() self:onClose() end }
  self.title_bar = bar
  local room = self.height - bar:getSize().h
  local body
  self.scroll = nil
  if self.message then
    body = CenterContainer:new { dimen = Geom:new { w = self.width, h = room },
      text(self.message, "body", { grey = true, width = self.width - 2 * M }) }
  else
    local width = self.width - 2 * M
    local content = self:buildContent(width)
    if content:getSize().h > room then
      width = self.width - 2 * M - ScrollControl.gutter()
      content = self:buildContent(width)
      self.scroll = ScrollableContainer:new {
        dimen = Geom:new { x = 0, y = 0, w = self.width, h = room }, show_parent = self,
      }
      self.scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
      body = ScrollControl.wrap(self.scroll, content)
    else
      body = HorizontalGroup:new { Theme.hspan(M), content }
    end
  end
  self.frame = FrameContainer:new {
    width = self.width, height = self.height, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", bar, body },
  }
  self[1] = self.frame
end

-- Rebuild everything from the current state, staying where the page was scrolled to.
function ReviewsDialog:refresh()
  local offset = self.scroll and self.scroll:getScrolledOffset()
  if self[1] and type(self[1].free) == "function" then pcall(function() self[1]:free() end) end
  self[1] = nil
  self:build()
  if offset and self.scroll then self.scroll:setScrolledOffset(offset) end
  UIManager:setDirty(self, "ui")
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
  self.reviews = Reviews.appendPage(self.reviews, rows)
  self.offset = offset + (raw_count or #rows)
  self.has_more = Reviews.hasMore(raw_count, self.page_size)

  if #self.reviews == 0 then
    self:setMessage(_("No reviews yet"))
    return
  end
  self:refresh()
end

-- The whole review on a screen of its own, over this list.
function ReviewsDialog:showFull(review)
  UIManager:show(require("hardcover/lib/ui/text_screen"):new {
    title = _("Review"),
    heading = Reviews.headline(review),
    text = review.text,
  })
end

--
-- Fetch the next page. Guarded so a double tap cannot fire two requests.
--
function ReviewsDialog:loadMore()
  if self.loading or not self.has_more or not self.fetch_page then return end

  self.loading = true
  self:refresh()

  local offset = self.offset
  self.fetch_page(offset, self.page_size, function(rows, err, raw_count)
    self.loading = false
    if err or not rows then
      -- put the "Load more" button back; DialogManager offers the retry
      self:refresh()
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
