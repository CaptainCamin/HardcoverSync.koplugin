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
local TopContainer = require("ui/widget/container/topcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local T = require("ffi/util").template

local Button = require("hardcover/lib/ui/components/button")
local Clamp = require("hardcover/lib/ui/clamp")
local Reviews = require("hardcover/lib/reviews")
local ScrollBody = require("hardcover/lib/ui/scroll_body")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

local ReviewsDialog = InputContainer:extend {
  name = "hardcover_reviews_dialog",
  title = _("Reviews"),
  summary = nil,       -- { title, rating, count, distribution }: the book, shown above page one
  hint = nil,          -- a small grey note under the summary
  cache_note = nil,    -- when the saved copy is from; absent after a successful fetch
  offline = false,
  reviews = nil,       -- normalised (Reviews.normalize), in display order
  message = nil,       -- a single non-interactive message: loading, empty
  has_more = false,
  loading = false,
  offset = 0,          -- how many rows the server has already given us
  page_size = Reviews.PAGE_SIZE,
  fetch_page = nil,    -- function(offset, limit, callback(rows, err))
  close_callback = nil,
  mine = nil,          -- { rating, text, spoilers, posted_at, rating_state, review_state, review_id }
  on_rating = nil,     -- function(stars)
  on_review = nil,     -- function()
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

-- The model: one item per review, then the Load more item when there is more. What a tap on a card
-- does is picked from here (the cards' buttons call onSelectItem with their item).
function ReviewsDialog:buildItems()
  local items = {}
  if self.message then
    items[1] = { text = self.message, message = true }
    return items
  end
  for _, review in ipairs(self:communityReviews()) do
    local text, action = Reviews.rowText(review, self.revealed[review.id or review])
    items[#items + 1] = { text = text, review = review, action = action }
  end
  if self.has_more and not self.offline then
    items[#items + 1] = {
      text = self.loading and _("Loading reviews\226\128\166") or _(Reviews.LOAD_MORE),
      action = "more",
    }
  end
  return items
end

function ReviewsDialog:onSelectItem(item)
  if not item or self.message then return end
  if item.action == "more" then
    self:loadMore()
  elseif item.action == "reveal" then
    self.revealed[item.review.id or item.review] = true
    self:refresh()
  elseif item.action == "full" then
    self:showFull(item.review)
  end
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

-- True when a community row is the reader's own review: the same id when we have one, or the
-- same words (the server's row and the saved draft are often the same text).
function ReviewsDialog:isOwnReview(review)
  local mine = self.mine
  if type(mine) ~= "table" or type(review) ~= "table" then return false end
  if mine.review_id and review.id and tostring(mine.review_id) == tostring(review.id) then return true end
  local text = type(mine.text) == "string" and mine.text or ""
  return text ~= "" and review.text == text
end

function ReviewsDialog:communityReviews()
  local out = {}
  for _, review in ipairs(self.reviews or {}) do
    if not self:isOwnReview(review) then out[#out + 1] = review end
  end
  return out
end

function ReviewsDialog:communityHeader(width, count)
  local right = count > 0 and Theme.mmdText(T(count == 1 and _("1 review") or _("%1 reviews"), count),
    "text", 18, { secondary = true }) or nil
  return Theme.sectionHeader(_("Community reviews"), width, right)
end

-- Your own review and rating, before the community list. The heading says when it was posted,
-- that it is saved on this device, or that it needs a decision; the stars are the same control as
-- on the book's page.
function ReviewsDialog:buildYourBlock(width)
  local mine = self.mine
  if type(mine) ~= "table" then return nil end
  local state = mine.review_state
  if not state and mine.posted_at then state = T(_("Posted %1"), tostring(mine.posted_at)) end
  local state_widget = state and Theme.mmdText(state, "text", 18,
    { secondary = true, width = math.max(0, width - Theme.space.m) }) or nil
  local heading = Theme.sectionHeader(_("Your review"), width, state_widget)

  local label_w = math.max(0, width - 5 * Theme.TOUCH_MIN)
  local rating = tonumber(mine.rating)
  local rating_state = mine.rating_state or (rating and _("Tap to change") or _("Tap a star"))
  local label = VerticalGroup:new { align = "left",
    Theme.mmdText(_("Your rating"), "strong", 21, { width = label_w }),
    Theme.span(Theme.px(2)),
    Theme.mmdText(rating_state, "text", 18, { secondary = true, width = label_w }),
  }
  if self.on_rating then
    label = TapRow:new { callback = function() self.on_rating(nil) end,
      LeftContainer:new { dimen = Geom:new { w = label_w, h = Theme.TOUCH_MIN }, label } }
  end
  local stars = HorizontalGroup:new { align = "center" }
  for i = 1, 5 do
    local name = rating and (rating >= i and "star-filled" or (rating >= i - 0.5 and "star-half" or "star"))
      or "star"
    local star = CenterContainer:new {
      dimen = Geom:new { w = Theme.TOUCH_MIN, h = Theme.TOUCH_MIN },
      Theme.icon(name, Theme.px(28)),
    }
    if self.on_rating then
      star = TapRow:new { callback = function() self.on_rating(i) end, star }
    end
    stars[#stars + 1] = star
  end
  local rating_row = HorizontalGroup:new { align = "center", label }
  for _, star in ipairs(stars) do rating_row[#rating_row + 1] = star end

  local review_text = type(mine.text) == "string" and mine.text or ""
  local body
  if review_text ~= "" then
    body = Clamp.text { text = review_text, face = Theme.face("small"), width = width, lines = 3 }
  else
    body = Theme.mmdText(_("No written review. Your rating counts on its own; add words any time."),
      "text", 18, { secondary = true, width = width })
  end
  local spoiler_note
  if review_text ~= "" and mine.spoilers then
    spoiler_note = Theme.mmdText(_("Contains spoilers"), "small", 18, { secondary = true, width = width })
  end
  local button = Button.new {
    label = review_text ~= "" and _("Edit your review") or _("Write your review"),
    w = width, h = Theme.TOUCH_MIN, primary = review_text == "",
    callback = function() if self.on_review then self.on_review() end end,
  }
  self.your_review_button = button
  self.your_rating_row = rating_row
  self.your_rating_stars = stars
  self.your_review_text = review_text
  self.your_review_state = state
  self.your_rating_state = rating_state
  local block = VerticalGroup:new { align = "left",
    heading, Theme.span("s"), rating_row, Theme.span("m"), body,
  }
  if spoiler_note then block[#block + 1] = Theme.span("xs"); block[#block + 1] = spoiler_note end
  block[#block + 1] = Theme.span("m")
  block[#block + 1] = button
  block[#block + 1] = Theme.span("m")
  self.your_review_block = block
  return block
end

-- The height one card is always given, so the cards line up and the page steps are even: the rule
-- and room above, the head line, three lines of text, the foot and room below.
function ReviewsDialog:cardMetrics(width)
  if self.metrics and self.metrics.width == width then return self.metrics end
  local face = Theme.face("body")
  local probe = TextBoxWidget:new { text = "A", face = face, width = width, alignment = "left" }
  local line_h = probe.line_height_px or math.floor(face.size * 1.3)
  probe:free()
  local head_h = text("Ag", "title", { bold = true }):getSize().h
  local foot_h = Theme.TOUCH_MIN
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
        label = Reviews.SPOILER_PROMPT, w = width, h = Theme.TOUCH_MIN, size = 18,
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
    local more = Button.new { label = _(Reviews.READ_MORE), w = Theme.px(120), h = Theme.TOUCH_MIN,
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
  if self.has_more and not self.offline then
    table.insert(group, Button.new { label = self.loading and _("Loading reviews\226\128\166") or _(Reviews.LOAD_MORE),
      w = width, h = Theme.mmd.button.height.medium, callback = function() self:loadMore() end })
    self.more_button = group[#group]
  else
    self.more_button = nil
    local done = text(self.has_more and _("More reviews need a connection") or _("No more reviews"),
      "body", { grey = true, width = width })
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
  if type(summary) ~= "table" and not self.hint and not self.cache_note then return nil end
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
  if self.cache_note then
    table.insert(group, TextBoxWidget:new { text = self.cache_note, face = Theme.face("small"),
      fgcolor = Theme.secondary(), width = width })
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
  local own = self:buildYourBlock(width)
  if own then table.insert(content, own) end
  local community = self:communityReviews()
  if own or #community > 0 or self.message then
    table.insert(content, self:communityHeader(width, #community))
    if #community == 0 then
      table.insert(content, Theme.span("s"))
      table.insert(content, Theme.mmdText(self.message or _("No community reviews yet."),
        "text", 18, { secondary = true, width = width }))
      table.insert(content, Theme.span("m"))
    end
  end
  for _i, review in ipairs(community) do
    table.insert(content, self:buildCard(review, width))
  end
  if #community > 0 or self.has_more then
    table.insert(content, self:buildFooter(width))
  end
  return content
end

-- How tall buildContent(width) comes out, without building the cards: each is cardMetrics' height.
-- Past `limit` the summary and footer are not built to be counted.
function ReviewsDialog:contentHeight(width, limit)
  local community = self:communityReviews()
  local h = Theme.space.m + #community * self:cardMetrics(width).height
  local own = self:buildYourBlock(width)
  if own then h = h + own:getSize().h; pcall(own.free, own) end
  if own or #community > 0 or self.message then
    local header = self:communityHeader(width, #community)
    h = h + header:getSize().h
    pcall(header.free, header)
  end
  if limit and h > limit then return h end
  local footer = (#community > 0 or self.has_more) and self:buildFooter(width) or false
  for _i, block in ipairs({ self:buildSummary(width) or false, footer }) do
    if block then
      h = h + block:getSize().h
      if type(block.free) == "function" then pcall(block.free, block) end
    end
  end
  return h
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
  if self.message and not self.mine then
    body = CenterContainer:new { dimen = Geom:new { w = self.width, h = room },
      TextBoxWidget:new {
        text = self.message .. (self.cache_note and ("\n\n" .. self.cache_note) or ""),
        face = Theme.face("body"), fgcolor = Theme.secondary(), width = self.width - 2 * M,
      } }
  else
    body, self.scroll = ScrollBody.layout {
      width = self.width, room = room, margin = M, show_parent = self,
      build = function(width) return self:buildContent(width) end,
      height = function(width, limit) return self:contentHeight(width, limit) end,
    }
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
  self.items = self:buildItems()
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

-- A rating or review just saved: update the own section without closing the page.
function ReviewsDialog:setMine(values)
  self.mine = self.mine or {}
  for key, value in pairs(values or {}) do
    if value == false then self.mine[key] = nil else self.mine[key] = value end
  end
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
  self.reviews = Reviews.appendPage(offset == 0 and {} or self.reviews, rows)
  self.offset = offset + (raw_count or #rows)
  self.has_more = Reviews.hasMore(raw_count, self.page_size)

  if #self.reviews == 0 and not self.has_more and not self.mine then
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
  }, "full")
end

--
-- Fetch the next page. Guarded so a double tap cannot fire two requests.
--
function ReviewsDialog:loadMore()
  if self.loading or self.offline or not self.has_more or not self.fetch_page then return end

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
