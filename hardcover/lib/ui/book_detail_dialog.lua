-- Read-only detail view for a single Hardcover book: description, metadata,
-- and the reader's own status/rating.
--
-- Follows the plugin's existing dialog conventions (see journal_dialog.lua and
-- the skill's e-ink rules): one fullscreen frame so the reader UI does not show
-- through, text updated in place via setText rather than by rebuilding layout,
-- and Back handled through FocusManager's key_events.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local T = require("ffi/util").template

local BookSyncState = require("hardcover/lib/book_sync_state")
local Button = require("hardcover/lib/ui/components/button")
local Chip = require("hardcover/lib/ui/components/chip")
local Clamp = require("hardcover/lib/ui/clamp")
local DetailsScreen = require("hardcover/lib/ui/details_screen")
local Draw = require("hardcover/lib/ui/components/draw")
local Section = require("hardcover/lib/ui/components/section")
local Lists = require("hardcover/lib/lists")
local Note = require("hardcover/lib/ui/components/note")
local PendingStatus = require("hardcover/lib/pending_status")
local ReadHistory = require("hardcover/lib/read_history")
local Refresh = require("hardcover/lib/ui/refresh")
local Shelf = require("hardcover/lib/shelf")
local SeriesCarousel = require("hardcover/lib/ui/series_carousel")
local TapRow = require("hardcover/lib/ui/tap_row")
local TextScreen = require("hardcover/lib/ui/text_screen")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

-- the page is the same size for every book: About is cut to this many lines, the genres to this
-- many names, and Details lists this many rows, with a Read more / +N more / All details for the rest
local ABOUT_LINES = 3
local TAGS_SHOWN = 3
local DETAIL_ROWS = 5

--[[--
The width the page's content may use, on a screen `screen_w` wide.

ScrollableContainer treats any content wider than its viewport as scrolling
sideways and draws a horizontal scrollbar -- and once the page also scrolls
vertically, its vertical scrollbar takes 3 * scroll_bar_width off that
viewport. Content as wide as the page is therefore always "too wide" by that
gutter. Everything on the page is laid out in this width, which leaves it free;
the left margin is added by an inset around the whole column.

A page that fits the screen does not scroll, so it has no vertical scrollbar and no
gutter to keep free: `reserve` is false for it and the content reaches the right margin.
`reserve` defaults to true (the page that scrolls).
]]
local function contentWidth(screen_w, reserve)
  local gutter = reserve == false and 0 or ScrollControl.gutter()
  return screen_w - 2 * Theme.margin - gutter
end

local section = Section.new

local BookDetailDialog = FocusManager:extend {
  name = "hardcover_book_detail",
  title = _("Book details"),
  detail = nil,
  -- called with no arguments when the Reviews heading is tapped; no callback, no heading action
  on_reviews = nil,
  -- called with the dialog when "Your review" is tapped (write, change or remove your own review);
  -- no callback, no button
  on_review = nil,
  -- called with the dialog when the sync note's Review button is tapped
  on_decision = nil,
  -- called with the dialog when the reading row is tapped; no callback, no reading row action
  on_reads = nil,
  -- { queues = { sync_queue, rating_queue, review_queue }, book_id, user_id } for BookSyncState
  state_opts = nil,
  sync_state = nil,
  -- called with no arguments when "Lists" is chosen in the Add sheet (the lists to put the book on);
  -- no callback, no Lists row
  on_lists = nil,
  -- kept for the reader panel's link actions; the details page no longer offers an Edition button
  on_edition = nil,
  on_refresh = nil, -- the title bar's reload icon; nil hides it
  -- called with the dialog when Open is tapped (the book is on this device: a file the plugin linked
  -- to it); no callback, no button
  on_open = nil,
  -- called with the dialog when Find on device is tapped (look for the book among the files on this
  -- device); no callback, no button. Offered only when the book is not already on it.
  on_find = nil,
  -- present only when the chosen download plugin (Z-library, Anna's Archive or Kindle Fetch; see
  -- hardcover/lib/book_sources.lua) is installed. Named for the first one it served.
  on_zlibrary = nil,
  -- what that button says
  source_label = "Z-library",
  -- tapping your rating: called with the dialog. No callback, not tappable.
  on_rating = nil,
  width = nil,
  height = nil,
}

--
-- The picture box of a book's cover, on a screen `screen_w` wide: width and height.
-- This is the one place its size is worked out. The header draws the box at this size,
-- and loadCover asks the image service for a picture of exactly this size, so the two
-- cannot drift apart. A plain function (no dialog), so the emulator fixtures can use it.
--
-- the cover's share of the page's width: a thumbnail, so the title and the buttons are on the first screen
BookDetailDialog.COVER_SHARE = 0.27

function BookDetailDialog.coverBox(screen_w, reserve)
  local cover_width = math.floor(contentWidth(screen_w, reserve) * BookDetailDialog.COVER_SHARE)
  return cover_width, math.floor(cover_width * 1.5)
end


-- The reading row: where the reader is, in one fixed 96 px tap row that opens Reading history.
function BookDetailDialog:buildReadingRow(summary, width, viewport)
  local chevron = Draw.chevron("right")
  local side = Theme.space.m
  local inner = width - 2 * side
  local text_w = inner - chevron:getSize().w - Theme.space.s
  local pct_text = summary.pct and Theme.mmdText(tostring(summary.pct) .. "%", "strong", 18) or nil
  local label_w = text_w - (pct_text and (pct_text:getSize().w + Theme.space.s) or 0)
  local label = Theme.mmdText(summary.label, "strong", 21, { width = math.max(0, label_w) })
  local line1 = HorizontalGroup:new { align = "center", label }
  if pct_text then
    line1[#line1 + 1] = HorizontalSpan:new { width = math.max(0, text_w - label:getSize().w - pct_text:getSize().w) }
    line1[#line1 + 1] = pct_text
  end
  local bar = Theme.progress { width = text_w, height = Theme.px(12),
    percentage = (summary.pct or 0) / 100 }
  local support = Theme.mmdText(summary.support or "", "text", 18, { secondary = true, width = text_w })
  local line3 = HorizontalGroup:new { align = "center", support,
    HorizontalSpan:new { width = math.max(0, text_w - support:getSize().w) },
    Theme.hspan(Theme.space.s), chevron }
  local inner_group = VerticalGroup:new { align = "left",
    line1, Theme.span(Theme.px(6)), bar, Theme.span(Theme.px(6)), line3 }
  local pad = math.max(0, Theme.px(96) - inner_group:getSize().h)
  local row = VerticalGroup:new { align = "left",
    Theme.span(math.floor(pad / 2)),
    HorizontalGroup:new { Theme.hspan(side), inner_group },
    Theme.span(pad - math.floor(pad / 2)),
  }
  self.reading_label, self.reading_bar, self.reading_support = label, bar, support
  local tap = TapRow:new {
    callback = function() if self.on_reads then self.on_reads(self) end end,
    viewport = viewport, text = _("Reading"), row,
  }
  if not self.on_reads then tap.ges_events = {} end
  return tap
end

-- A dotted note when this book has a question, with one solid Review button into the one list.
function BookDetailDialog:buildSyncNote(width)
  local state = self.sync_state
  if not (state and state.decision and self.on_decision) then return nil end
  self.sync_note_title = _("Needs your decision")
  return Note.new {
    width = width,
    icon = Draw.icon("warning", Theme.px(26)),
    title = self.sync_note_title,
    text = table.concat(state.note_lines, "\n"),
    text_wrap = true,
    dotted = true,
    action = { label = _("Review"), callback = function()
      if self.on_decision then self.on_decision(self) end
    end },
  }
end

-- The compact reviews section: a heading row that opens the reviews page, one line with the
-- average and both counts, and one Write/Edit button. No chart and no individual reviews here.
function BookDetailDialog:reviewsBlock(width, viewport, book)
  local reviews_count = tonumber(book.reviews_count) or 0
  local ratings_count = tonumber(book.ratings_count) or 0
  local average = tonumber(book.rating)
  local row_h = Theme.px(48)
  local chevron = Draw.chevron("right")
  local all_text = reviews_count > 0 and Theme.mmdText(T(_("All %1 reviews"), reviews_count), "text", 18,
    { secondary = true }) or nil
  local all_w = all_text and all_text:getSize().w or 0
  local label = Theme.mmdText(_("Reviews"), "strong", 21,
    { width = math.max(0, width - all_w - (all_text and Theme.space.s or 0) - chevron:getSize().w) })
  local line = HorizontalGroup:new { align = "center", label }
  if all_text then
    line[#line + 1] = HorizontalSpan:new { width = math.max(0,
      width - label:getSize().w - all_w - chevron:getSize().w) }
    line[#line + 1] = all_text
    line[#line + 1] = Theme.hspan(Theme.space.s)
  end
  line[#line + 1] = chevron
  local heading = TapRow:new {
    callback = function() if self.on_reviews then self.on_reviews(self) end end,
    viewport = viewport, text = _("Reviews"),
    LeftContainer:new { dimen = Geom:new { w = width, h = row_h }, line },
  }
  if not self.on_reviews then heading.ges_events = {} end
  self.reviews_heading = heading

  local average_part = average and ratings_count > 0 and Theme.mmdText(string.format("%.1f", average), "strong", 21)
    or nil
  local stars = HorizontalGroup:new { align = "center" }
  if average and ratings_count > 0 then
    for i = 1, 5 do
      local name = average >= i and "star-filled" or (average >= i - 0.5 and "star-half" or "star")
      stars[#stars + 1] = Theme.icon(name, Theme.px(16))
      if i < 5 then stars[#stars + 1] = Theme.hspan(Theme.px(2)) end
    end
  end
  self.reviews_average = average_part
  self.reviews_counts = Theme.mmdText(T(_("%1 ratings · %2 reviews"), ratings_count, reviews_count),
    "text", 18, { secondary = true })
  local average_line = HorizontalGroup:new { align = "center" }
  if average_part then
    average_line[#average_line + 1] = average_part
    average_line[#average_line + 1] = Theme.hspan(Theme.space.s)
    average_line[#average_line + 1] = stars
    average_line[#average_line + 1] = Theme.hspan(Theme.space.s)
  end
  average_line[#average_line + 1] = self.reviews_counts

  local has_review = type((self.detail or {}).user_review) == "string" and self.detail.user_review ~= ""
  self.review_button = self.on_review and Button.new {
    label = has_review and _("Edit your review") or _("Write your review"),
    w = width, h = Theme.TOUCH_MIN, viewport = viewport,
    callback = function() if self.on_review then self.on_review(self) end end,
  } or nil
  local block = VerticalGroup:new { align = "left", Theme.span("m"), heading, Theme.dottedRule(width),
    Theme.span(Theme.space.s), average_line, Theme.span(Theme.space.m) }
  if self.review_button then block[#block + 1] = self.review_button end
  block[#block + 1] = Theme.span("m")
  self.reviews_section = block
  return block
end

function BookDetailDialog:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  self.width = screen_w
  self.height = screen_h

  -- The event name picks the handler: CloseDetail runs onCloseDetail. This was
  -- CloseDialog, which has no handler, so the Back key did nothing -- including
  -- on the loading screen, which has no button, leaving a slow or hung fetch
  -- with no way out.
  self.key_events.CloseDetail = { { "Back" } }

  -- the MMD top bar: back (it is the Close button, and the loading screen has one too, so a slow
  -- fetch can always be left) and the reload icon when the details can be fetched again (they may
  -- be shown from the device)
  local title_bar = TopBar.new {
    width = screen_w,
    title = self.title,
    on_back = function() self:onCloseDetail() end,
    actions = self.on_refresh and { { icon = "sync", callback = function() self.on_refresh(self) end } } or nil,
  }
  self.title_bar = title_bar
  self.close_button = title_bar.back_button

  --[[--
  Loading state.

  The dialog is shown before its detail is fetched, so init runs once with
  self.loading set and again from setDetail. Re-running init is safe here and is
  the whole reason the body is built here rather than incrementally patched:
  the widgets are pure functions of self.detail, so rebuilding them cannot leave
  a stale one behind. It is NOT the right pattern for live text updates, where
  rebuilding per keystroke would throw away FocusManager's focus.
  ]]
  if self.loading then
    self.loading_text = TextWidget:new {
      text = _("Loading book details…"),
      face = Theme.face("body"),
      max_width = screen_w - 2 * M,
      fgcolor = Theme.secondary(),
    }
    self.loading_frame = FrameContainer:new {
      width = screen_w,
      height = screen_h,
      background = Blitbuffer.COLOR_WHITE,
      bordersize = 0,
      padding = 0,
      margin = 0,
      VerticalGroup:new {
        align = "left",
        title_bar,
        CenterContainer:new {
          dimen = Geom:new { w = screen_w, h = screen_h - title_bar:getSize().h },
          self.loading_text,
        },
      },
    }
    self[1] = self.loading_frame
    return
  end

  self.loading = false
  self.closed = false

  local summary = Shelf.detailSummary(self.detail)
  local book = (self.detail or {}).book or {}
  self.sync_state = nil
  if self.state_opts then
    self.sync_state = BookSyncState.forBook(self.state_opts.queues, self.state_opts.book_id or book.book_id,
      (self.detail or {}).user_book_id, self.state_opts.user_id)
  end

  -- everything below is laid out in this width (see contentWidth above)
  -- The strip at the right is kept for the scroll control only when the page scrolls. That is not
  -- known until the page is built, so it is built without the strip first and built again with it
  -- when it turns out taller than the screen (see the end of init).
  local reserve = self.reserve_gutter == true
  local width = contentWidth(screen_w, reserve)
  self.content_width = width

  --[[--
  Header: the cover beside the title block, like a book's back cover.

  Every line is a finished string from Shelf.detailSummary or nil, so this only
  lays out what exists. The cover box is sized up front and filled in when the
  image arrives, so the text does not move when it does.
  ]]
  -- The cover box is always there, so every book's header looks the same: the
  -- picture when there is one, and a generic book icon while it loads, if it
  -- never does (offline, a failed fetch), or when the book has no cover at all.
  local cover_width, cover_height = BookDetailDialog.coverBox(screen_w, reserve)
  local cover_gap = Theme.space.l
  -- the frame around the cover adds its border on both sides of the picture box
  local cover_border = Theme.line.hair
  local text_width = width - cover_width - 2 * cover_border - cover_gap

  -- TextWidget is one line and reads max_width, not width; anything that may be
  -- long (a title, an author list) is a TextBoxWidget, which wraps to width. `title` is Lato
  -- Black (Theme.title), `strong` too at the body size.
  local function wrapped(text, size, bold, grey, kind)
    local face, ask_bold = Theme.face(size), bold
    if kind == "title" then
      face, ask_bold = Theme.title(size)
    elseif kind == "strong" then
      face, ask_bold = Theme.mmdFace("strong", Theme.type[size] or size)
    end
    return TextBoxWidget:new {
      text = text,
      face = face,
      bold = ask_bold,
      width = text_width,
      alignment = "left",
      fgcolor = grey and Theme.secondary() or Theme.BLACK,
    }
  end

  local column = VerticalGroup:new { align = "left" }
  local function addTo(group, widget)
    if widget then table.insert(group, widget) end
  end

  -- the header scrolls with the page, so taps are cut to what is showing (see
  -- viewport.lua)
  local viewport = function() return self.scroll and self.scroll.dimen end

  local title_face, title_bold = Theme.title("display")
  self.title_text = Clamp.text {
    text = summary.title, face = title_face, bold = title_bold, width = text_width, lines = 2,
  }
  addTo(column, self.title_text)
  if summary.subtitle then
    self.subtitle_text = wrapped(summary.subtitle, "body", false, true)
    addTo(column, Theme.span("xs"))
    addTo(column, self.subtitle_text)
  else
    self.subtitle_text = nil
  end
  -- the author and the series sit right under the title, plain text (the owner: not tappable)
  if summary.authors then
    self.authors_text = wrapped(summary.authors, "small")
    addTo(column, Theme.span("xs"))
    addTo(column, self.authors_text)
  else
    self.authors_text = nil
  end
  self.series_text = nil
  if summary.series then
    self.series_text = wrapped(summary.series, "small", false, true)
    addTo(column, Theme.span("xs"))
    addTo(column, self.series_text)
  end
  -- where the book is on your shelves: a filled pill with the status, or an outlined "Not on a shelf"
  -- so the line is there for every book (not tappable; the Shelf button below is how it changes)
  local status_id = (self.detail or {}).status_id
  local chevron_down = Draw.chevron("down")
  local chip_width = math.max(0, text_width - chevron_down:getSize().w - Theme.space.s)
  self.status_text = Chip.new {
    label = status_id and Shelf.statusLabel(status_id) or _("Not on a shelf"),
    selected = status_id ~= nil, size = 15, width = chip_width,
  }
  local shelf_line = HorizontalGroup:new { align = "center", self.status_text,
    Theme.hspan(Theme.space.s), chevron_down }
  self.shelf_tap = Theme.touchable(shelf_line, text_width, function()
    if self.on_shelf then self.on_shelf(self) end
  end, viewport)
  if not self.on_shelf then self.shelf_tap.ges_events = {} end
  addTo(column, Theme.span("s"))
  addTo(column, self.shelf_tap)
  -- The edition is on the reading row; the facts line is only for a book with no reading history
  local known_reads = self.detail and type(self.detail.reads) == "table" and #self.detail.reads > 0
  if summary.facts and not known_reads then
    self.facts_text = wrapped(summary.facts, "small", false, true)
    addTo(column, Theme.span("s"))
    addTo(column, self.facts_text)
  else
    self.facts_text = nil
  end

  -- which of your lists the book is on, once that is known (the lists picker
  -- loads it; see setLists)
  self.lists_text = nil
  local on_lists = Lists.onNames((self.detail or {}).lists)
  if on_lists then
    self.lists_text = wrapped(string.format(_("On your lists: %s"), on_lists), "small", false, true)
    addTo(column, Theme.span("s"))
    addTo(column, self.lists_text)
  end

  -- a box of the cover's size holding the placeholder; loadCover swaps the
  -- picture in if one arrives
  local icon_size = math.floor(cover_width * 0.5)
  self.cover_cell = FrameContainer:new {
    bordersize = cover_border,
    padding = 0,
    margin = 0,
    CenterContainer:new {
      dimen = Geom:new { w = cover_width, h = cover_height },
      IconWidget:new { icon = "book.opened", width = icon_size, height = icon_size },
    },
  }
  local header = HorizontalGroup:new {
    align = "top",
    self.cover_cell,
    HorizontalSpan:new { width = cover_gap },
    column,
  }

  -- what you make of it: five visible stars (half ones too), the whole row a tap to rate
  local mine = tonumber((self.detail or {}).user_rating) or 0
  local star_cell = Theme.TOUCH_MIN
  local star_total = 5 * star_cell
  local rating_label_w = math.max(0, text_width - star_total)
  local rating_state = self.sync_state and self.sync_state.rating_state
    or (mine > 0 and _("Tap to change") or _("Tap a star"))
  self.rating_label_text = mine > 0 and _("Your rating") or _("Rate it")
  self.rating_state_text = rating_state

  -- The label is two lines and the stars are five TOUCH_MIN cells. On a narrow page they do not
  -- share a line without cutting the state ("Waiting to s…"), so the stars move under the label
  -- rather than shrink below the touch target.
  local label_probe = Theme.mmdText(self.rating_label_text, "strong", 21)
  local state_probe = Theme.mmdText(rating_state, "text", 18)
  local label_needed = math.max(label_probe:getSize().w, state_probe:getSize().w)
  label_probe:free()
  state_probe:free()
  local stacked = rating_label_w < label_needed
  local label_w = stacked and text_width or rating_label_w
  local rating_label = VerticalGroup:new { align = "left",
    Theme.mmdText(self.rating_label_text, "strong", 21, { width = label_w }),
    Theme.span(Theme.px(2)),
    Theme.mmdText(rating_state, "text", 18, { secondary = true, width = label_w }),
  }
  self.rating_tap = nil
  if self.on_rating then
    local label_h = math.max(star_cell, rating_label:getSize().h)
    rating_label = TapRow:new { callback = function() self.on_rating(self) end, viewport = viewport,
      LeftContainer:new { dimen = Geom:new { w = label_w, h = label_h }, rating_label } }
    self.rating_tap = rating_label
  end
  local stars_row = HorizontalGroup:new { align = "center" }
  for i = 1, 5 do
    local name = mine >= i and "star-filled" or (mine >= i - 0.5 and "star-half" or "star")
    local star = CenterContainer:new {
      dimen = Geom:new { w = star_cell, h = star_cell },
      Theme.icon(name, Theme.px(28)),
    }
    if self.on_rating then
      star = TapRow:new { callback = function() self.on_rating(self, i) end, viewport = viewport, star }
    end
    table.insert(stars_row, star)
  end
  if stacked then
    self.rating_row = VerticalGroup:new { align = "left", rating_label, stars_row }
    addTo(column, Theme.span("s"))
    addTo(column, rating_label)
    addTo(column, Theme.span(Theme.px(4)))
    addTo(column, stars_row)
  else
    local rating_row = HorizontalGroup:new { align = "center", rating_label }
    if rating_label_w == 0 then table.remove(rating_row) end
    for _, star in ipairs(stars_row) do table.insert(rating_row, star) end
    self.rating_row = rating_row
    addTo(column, Theme.span("s"))
    addTo(column, rating_row)
  end

  -- one row of actions: the filled way to read it (Open, else Find on device), then the outlined
  -- Download when it applies and Lists when that can open. The round buttons are gone: Shelf is the
  -- chip beside the cover, Reviews is its section, and reading history is the reading row below.
  self.open_button, self.find_button, self.zlibrary_button = nil, nil, nil
  self.lists_button = nil
  self.add_button, self.reviews_button, self.review_button, self.edition_button = nil, nil, nil, nil
  self.decision_button = nil
  local action_bar = VerticalGroup:new { align = "left" }
  local action_fields = {}
  local primary_field, primary_label, primary_handler
  if self.on_open then
    primary_field, primary_label, primary_handler = "open_button", _("Open"), "on_open"
  elseif self.on_find then
    primary_field, primary_label, primary_handler = "find_button", _("Find on device"), "on_find"
  end
  local download = self.on_zlibrary and not self.on_open
  local count = (primary_field and 1 or 0) + (download and 1 or 0) + (self.on_lists and 1 or 0)
  local gap = Theme.space.s
  local button_w = count > 0 and math.floor((width - gap * (count - 1)) / count) or width
  local buttons = {}
  if primary_field then
    self[primary_field] = Button.new {
      label = primary_label, w = button_w, h = Theme.TOUCH_MIN, size = 19, primary = true,
      viewport = viewport,
      callback = function()
        local fn = self[primary_handler]
        if fn then fn(self) end
      end,
    }
    buttons[#buttons + 1] = self[primary_field]
    action_fields[#action_fields + 1] = primary_field
  end
  if download then
    self.zlibrary_button = Button.new {
      label = _("Download"), w = button_w, h = Theme.TOUCH_MIN, size = 19, viewport = viewport,
      callback = function() if self.on_zlibrary then self.on_zlibrary(self) end end,
    }
    buttons[#buttons + 1] = self.zlibrary_button
    action_fields[#action_fields + 1] = "zlibrary_button"
  end
  if self.on_lists then
    self.lists_button = Button.new {
      label = _("Lists"), w = button_w, h = Theme.TOUCH_MIN, size = 19, viewport = viewport,
      callback = function() if self.on_lists then self.on_lists(self) end end,
    }
    buttons[#buttons + 1] = self.lists_button
    action_fields[#action_fields + 1] = "lists_button"
  end
  if #buttons > 0 then
    local row = HorizontalGroup:new { align = "top" }
    for index, button in ipairs(buttons) do
      if index > 1 then row[#row + 1] = Theme.hspan(gap) end
      row[#row + 1] = button
    end
    action_bar[#action_bar + 1] = row
  end
  self.action_bar = action_bar
  self.action_rows = { action_fields }

  -- The reading row opens Reading history. Its page comes from the newest queued page first, so
  -- offline reading shows at once; otherwise the current read's page. A read edit waiting in the
  -- queue is laid over the saved history too.
  self.reading_row, self.reading_summary = nil, nil
  if (self.detail or {}).user_book_id then
    local queue = self.state_opts and self.state_opts.queues and self.state_opts.queues.sync_queue
    local user_id = self.state_opts and self.state_opts.user_id
    local reads = self.detail.reads or {}
    if queue and queue.readActions then
      local actions = queue:readActions(book.book_id)
      if #actions > 0 then reads = ReadHistory.project(reads, actions) end
    end
    local page
    for _, checkpoint in ipairs(PendingStatus.pages(queue, user_id)) do
      if tostring(checkpoint.book_id) == tostring(book.book_id) then page = checkpoint.page end
    end
    self.reading_summary = ReadHistory.summary(reads, {
      pages = book.pages, format = book.edition_format,
      state = self.sync_state and self.sync_state.read_state, page = page,
    })
    self.reading_row = self:buildReadingRow(self.reading_summary, width, viewport)
  end
  self.sync_note = self:buildSyncNote(width)

  -- About: three lines at most, so the block is the same height for every book; Read more sits on
  -- the heading line and opens the whole synopsis on a screen of its own
  self.description_text, self.about_more = nil, nil
  local about
  if summary.description then
    local clamped, cut = Clamp.text {
      text = summary.description, face = Theme.face("small"), width = width, lines = ABOUT_LINES,
    }
    self.description_text = clamped
    if cut then
      local more_w = Screen:scaleBySize(140)
      self.about_more = Button.new {
        label = _("Read more"), w = more_w, h = Theme.px(48), size = 18, viewport = viewport,
        callback = function()
          UIManager:show(TextScreen:new { title = _("About"), heading = summary.title, text = summary.description }, "full")
        end,
      }
    end
    about = section(_("About"), width, { right = self.about_more })
    table.insert(about, clamped)
  end

  -- the genres, one line, with "+N more" for the rest (and the moods and content warnings)
  local tags = self:tagsBlock(width, viewport, summary.title)
  local reviews = self:reviewsBlock(width, viewport, book)

  -- Built by appending, never as one table constructor: most things here are
  -- optional, and a nil in the middle of a constructor is a hole that
  -- VerticalGroup's ipairs stops at, so everything after it silently vanished.
  -- Each block carries its own space above it, so the scroll control's pages land on a block's
  -- edge and never between a gap and what follows it.
  local content = VerticalGroup:new { align = "left" }
  local function add(widget)
    if widget then table.insert(content, widget) end
  end
  self.content_group = content

  add(VerticalGroup:new { align = "left", Theme.span("s"), header })
  add(VerticalGroup:new { align = "left", Theme.span("s"), action_bar })
  if self.reading_row then add(VerticalGroup:new { align = "left", Theme.span("s"), self.reading_row }) end
  if self.sync_note then add(VerticalGroup:new { align = "left", Theme.span("s"), self.sync_note }) end
  add(about)
  add(tags)
  add(reviews)

  -- Strips of covers, paged with arrows; tapping one opens that book. Below About, so
  -- the book itself comes first: "More in this series", then "Similar to <title>".
  self.carousel, self.similar_carousel = nil, nil
  self.carousel_block, self.similar_block = nil, nil
  local function strip(card, on_open)
    return SeriesCarousel:new {
      card = card,
      width = width,
      -- what the scroll area is showing: taps outside it are not ours
      viewport = viewport,
      on_open = function(book_id)
        if on_open then on_open(book_id) end
      end,
      image_loader = self.image_loader or require("hardcover/lib/ui/image_loader"),
      -- a cover or a turned page redraws its own box, not the panel. A cover is a
      -- picture, so its box is drawn dithered, and so is the page from then on.
      on_change = function(get_dimen, picture)
        if picture then self.dithered = true end
        if get_dimen then
          Refresh.box(self, get_dimen, viewport, nil, picture)
        else
          UIManager:setDirty(self, "ui")
        end
      end,
    }
  end
  self.build_strip = strip -- setSimilar swaps the "Similar to" strip in place with it
  if self.series_card then
    self.carousel = strip(self.series_card, self.on_open_book)
    self.carousel_block = section(nil, width)
    table.insert(self.carousel_block, self.carousel.widget)
    add(self.carousel_block)
  end
  if self.similar_card then
    self.similar_carousel = strip(self.similar_card, self.on_open_similar)
    self.similar_block = section(nil, width)
    table.insert(self.similar_block, self.similar_carousel.widget)
    add(self.similar_block)
  end

  -- Details: the first five rows, each the same height with a dotted rule, then All details for
  -- the rest
  self.meta_rows, self.all_details = {}, nil
  local extra = Shelf.extraRows(book)
  if #extra > 0 then
    local label_width = math.floor(width * 0.32)
    local value_width = width - label_width - Theme.space.m
    local row_h = Theme.px(56)
    local details = section(_("Details"), width)
    for i = 1, math.min(#extra, DETAIL_ROWS) do
      local row = extra[i]
      local line = HorizontalGroup:new {
        align = "center",
        LeftContainer:new {
          dimen = Geom:new { w = label_width, h = row_h },
          TextWidget:new { text = row.label, face = Theme.face("small"), max_width = label_width, fgcolor = Theme.secondary() },
        },
        HorizontalSpan:new { width = Theme.space.m },
        LeftContainer:new {
          dimen = Geom:new { w = value_width, h = row_h },
          TextWidget:new { text = tostring(row.value), face = Theme.face("small"), max_width = value_width },
        },
      }
      local entry = VerticalGroup:new { align = "left", line, Theme.dottedRule(width) }
      table.insert(self.meta_rows, entry)
      table.insert(details, entry)
    end
    if #extra > DETAIL_ROWS then
      local row = HorizontalGroup:new {
        align = "center",
        LeftContainer:new {
          dimen = Geom:new { w = width - Theme.TOUCH_MIN, h = Theme.px(64) },
          Theme.mmdText(_("All details"), "strong", 21, { width = width - Theme.TOUCH_MIN }),
        },
        CenterContainer:new { dimen = Geom:new { w = Theme.TOUCH_MIN, h = Theme.px(64) }, Draw.chevron("right") },
      }
      self.all_details = TapRow:new {
        viewport = viewport,
        callback = function()
          UIManager:show(DetailsScreen:new { title = _("All details"), rows = extra }, "full")
        end,
        row,
      }
      table.insert(details, self.all_details)
    end
    add(details)
  end

  add(Theme.span("xl"))

  --[[--
  A full description plus every metadata row overflows a small e-ink screen, so
  the body scrolls under the title bar.

  ScrollableContainer takes its size from an explicit `dimen`, NOT from
  width/height -- initState reads self.dimen.w/h and paintTo writes
  self.dimen.x/y. Passing width/height therefore leaves dimen nil and the first
  paint dies with "attempt to index field 'dimen' (a nil value)", so the dialog
  never appeared at all.
  ]]
  local scroll = ScrollableContainer:new {
    dimen = Geom:new {
      x = 0,
      y = 0,
      w = screen_w,
      h = screen_h - title_bar:getSize().h,
    },
    show_parent = self,
    HorizontalGroup:new { Theme.hspan(M), content },
  }

  self.scroll = scroll
  self.scroll_body = ScrollControl.wrap(scroll, content)

  -- a fullscreen white frame: a bare container would let the reader UI show
  -- through behind the page
  self.frame = FrameContainer:new {
    width = screen_w,
    height = screen_h,
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new { align = "left", title_bar, self.scroll_body },
  }

  -- keyboard / d-pad focus: the buttons, the carousel's arrows (when it pages), then Close
  self.layout = {}
  for _i, fields in ipairs(self.action_rows or {}) do
    local row = {}
    for _j, field in ipairs(fields) do row[#row + 1] = self[field] end
    if #row > 0 then table.insert(self.layout, row) end
  end
  if self.reading_row then table.insert(self.layout, { self.reading_row }) end
  if self.reviews_heading then table.insert(self.layout, { self.reviews_heading }) end
  for _i, strip in ipairs({ self.carousel or false, self.similar_carousel or false }) do
    if strip and strip.paged then
      table.insert(self.layout, { strip.prev, strip.next })
    end
  end
  table.insert(self.layout, { self.close_button })

  if not reserve and content:getSize().h > screen_h - title_bar:getSize().h then
    self.reserve_gutter = true
    -- the strips of this first build have started fetching their covers; the second build makes
    -- its own, and these would decode again and refresh a box that is never on screen
    self:releaseCover()
    return self:init()
  end

  self[1] = self.frame

  if self.kept_cover then
    -- a rebuild that keeps the picture it already has (see setStatus)
    local bb = self.kept_cover
    self.kept_cover = nil
    self:placeCover(bb, cover_width, cover_height)
  else
    self:loadCover(summary.cover, cover_width, cover_height)
  end
end

--
-- The genres as one line with "+N more", under a Genres heading. Moods and content warnings
-- are in what "+N more" opens (a book with no genres leads with its moods, then its warnings).
-- nil when Hardcover has no tags for the book.
--
function BookDetailDialog:tagsBlock(width, viewport, title)
  self.tags_more = nil
  local book = self.detail and self.detail.book
  if not book then return nil end
  local Community = require("hardcover/lib/community")
  local tags = Community.tags(book)
  local sections = {}
  for _i, spec in ipairs({
    { tags.genres, _("Genres") }, { tags.moods, _("Moods") }, { tags.warnings, _("Content warnings") },
  }) do
    if #spec[1] > 0 then
      local labels = {}
      for i, t in ipairs(spec[1]) do labels[i] = t.tag end
      sections[#sections + 1] = { name = spec[2], labels = labels }
    end
  end
  if #sections == 0 then return nil end

  local lead = sections[1]
  local shown = math.min(#lead.labels, TAGS_SHOWN)
  local total = 0
  for _i, s in ipairs(sections) do total = total + #s.labels end
  local hidden = total - shown

  local block = section(lead.name, width)
  local line_w = width
  local more
  if hidden > 0 then
    local more_w = Screen:scaleBySize(130)
    more = Button.new {
      label = string.format(_("+%d more"), hidden), w = more_w, h = Theme.px(48), size = 18, viewport = viewport,
      callback = function()
        local parts = {}
        for _i, s in ipairs(sections) do
          parts[#parts + 1] = s.name .. "\n" .. table.concat(s.labels, " · ")
        end
        UIManager:show(TextScreen:new { title = _("Tags"), heading = title, text = table.concat(parts, "\n\n") }, "full")
      end,
    }
    self.tags_more = more
    line_w = width - more_w - Theme.space.m
  end
  local names = {}
  for i = 1, shown do names[i] = lead.labels[i] end
  local line = HorizontalGroup:new {
    align = "center",
    LeftContainer:new {
      dimen = Geom:new { w = line_w, h = Theme.TOUCH_MIN },
      TextWidget:new { text = table.concat(names, " · "), face = Theme.face("small"), max_width = line_w },
    },
  }
  if more then
    table.insert(line, HorizontalSpan:new { width = Theme.space.m })
    table.insert(line, more)
  end
  table.insert(block, line)
  return block
end

--
-- Fetch the cover and drop it into its box.
--
-- The loader answers from the on-disk cover cache first and does not touch the
-- network when offline, so a cover you have seen shows without a connection.
-- Everything it hands back is guarded on the dialog still being open: it can be
-- closed (and its buffer freed) while the image is on its way.
--
function BookDetailDialog:loadCover(cover, width, height)
  if not (cover and self.cover_cell) then return end

  local loader = self.image_loader or require("hardcover/lib/ui/image_loader")
  -- the box is the size the cover is drawn at, so the picture comes back that size
  local _, halt = loader:loadImages({ cover.url }, function(_, content)
    if self.closed or not self.cover_cell then return end

    local RenderImage = require("ui/renderimage")
    local bb = RenderImage:renderImageData(content, #content, false, width, height)
    if not bb then return end

    self:placeCover(bb, width, height)
  end, { size = "large", box = { w = width, h = height } })
  self.cover_halt = halt
end

function BookDetailDialog:placeCover(bb, width, height)
  self.cover_bb = bb
  -- a picture on this screen: its repaints are dithered from now on (see refresh.lua)
  self.dithered = true
  -- scale_factor 0 fits the picture inside the box keeping its proportions;
  -- image_disposable is off because this dialog owns (and frees) the buffer
  self.cover_cell[1] = CenterContainer:new {
    dimen = Geom:new { w = width, h = height },
    ImageWidget:new {
      image = bb,
      image_disposable = false,
      width = width,
      height = height,
      scale_factor = 0,
    },
  }
  -- only the cover's box changed, and it is a picture: drawn dithered
  local cell = self.cover_cell
  Refresh.box(self, function() return cell.dimen end, function() return self.scroll and self.scroll.dimen end, nil, true)
end

-- Stop fetching and give back the pictures' memory (the cover, and the
-- carousel's covers).
function BookDetailDialog:releaseCover()
  if self.carousel then
    self.carousel:release()
    self.carousel = nil
  end
  if self.similar_carousel then
    self.similar_carousel:release()
    self.similar_carousel = nil
  end
  if self.cover_halt then
    self.cover_halt()
    self.cover_halt = nil
  end
  if self.cover_bb and self.cover_bb.free then
    self.cover_bb:free()
  end
  self.cover_bb = nil
end

--
-- Show the rest of the series once it has been fetched.
--
-- `card` is Shelf.seriesCard's result (nil clears it); `on_open_book(book_id)`
-- is called when a row is tapped.
--
function BookDetailDialog:setSeries(card, on_open_book)
  self.series_card = card
  self.on_open_book = on_open_book

  -- The series arrives after the screen is up, and the reader may already have
  -- scrolled; a rebuild starts a new scroll container at the top, so carry the
  -- position across.
  local offset = self.scroll and self.scroll.getScrolledOffset and self.scroll:getScrolledOffset()
  self:rebuild()
  if offset and self.scroll and self.scroll.setScrolledOffset then
    self.scroll:setScrolledOffset(offset)
  end
end

--
-- Show "Similar to <title>" once it has been fetched.
--
-- `card` is Recommendations.card's result (nil clears it); `on_open(book_id)` is called
-- when a cover is tapped. Like the series, it arrives after the screen is up.
--
function BookDetailDialog:setSimilar(card, on_open)
  local old = self.similar_carousel
  self.similar_card = card
  self.on_open_similar = on_open

  -- The books arriving where the loading placeholder is: the same size, so swap the strip
  -- in place and redraw just its box, not the whole panel.
  if old and card and not card.loading and old.card.loading and self.similar_block then
    for i, child in ipairs(self.similar_block) do
      if child == old.widget then
        local strip = self.build_strip(card, on_open)
        self.similar_block[i] = strip.widget
        -- the strip's rectangle: its covers' box (the only part with a position) and the
        -- heading above it, which is the rest of the strip's height
        local holder = old.holder.dimen
        local where = holder and holder.x and {
          x = holder.x, y = holder.y - (old.widget:getSize().h - holder.h), w = holder.w, h = old.widget:getSize().h,
        }
        old:release()
        self.similar_carousel = strip
        -- its arrows join the focus rows, after the series' and before Close
        if strip.paged and self.layout then
          table.insert(self.layout, #self.layout, { strip.prev, strip.next })
        end
        -- the strip's own box (same place, same size), clipped to what the page shows; never
        -- the whole panel (a strip not yet painted has no position, and gets none)
        if where then
          Refresh.box(self, function() return where end, function() return self.scroll and self.scroll.dimen end)
        end
        return
      end
    end
  end

  local offset = self.scroll and self.scroll.getScrolledOffset and self.scroll:getScrolledOffset()
  self:rebuild()
  if offset and self.scroll and self.scroll.setScrolledOffset then
    self.scroll:setScrolledOffset(offset)
  end
end

-- Rebuild the whole body from the current state, dropping what it held.
-- `keep_cover` carries the cover picture across instead of fetching it again.
function BookDetailDialog:rebuild(keep_cover)
  local kept = keep_cover and self.cover_bb or nil
  if kept then self.cover_bb = nil end -- so releaseCover does not free it
  -- a rebuild means a new cover box; drop the old picture and any fetch for it
  self:releaseCover()
  self.kept_cover = kept

  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil

  -- the page is measured again: what it holds may have changed (a status, a series, a rating)
  self.reserve_gutter = nil
  self:init()

  UIManager:setDirty(self, "ui")
end

--
-- What waits in the queues changed (an edit was kept, sent, or decided): draw the page again from
-- the same detail, keeping the cover and where the reader had scrolled to.
function BookDetailDialog:refreshState()
  local offset = self.scroll and self.scroll.getScrolledOffset and self.scroll:getScrolledOffset()
  self:rebuild(true)
  if offset and self.scroll and self.scroll.setScrolledOffset then
    self.scroll:setScrolledOffset(offset)
  end
end

--
-- The book's place in the library changed: `status_id` is the new status, nil
-- when it was taken out; `user_book_id` is its library record. Updates the
-- status line and the shelf button, keeping the cover and the scroll position.
--
function BookDetailDialog:setStatus(status_id, user_book_id)
  local detail = self.detail or {}
  self.detail = detail
  detail.status_id = status_id
  detail.user_book_id = status_id and user_book_id or nil
  if not status_id then detail.user_rating = nil end

  local offset = self.scroll and self.scroll.getScrolledOffset and self.scroll:getScrolledOffset()
  self:rebuild(true)
  if offset and self.scroll and self.scroll.setScrolledOffset then
    self.scroll:setScrolledOffset(offset)
  end
end

--
-- Your rating changed (0 clears it). Keeps the cover and the scroll position.
--
function BookDetailDialog:setRating(rating)
  local detail = self.detail or {}
  self.detail = detail
  detail.user_rating = (tonumber(rating) or 0) > 0 and rating or nil

  local offset = self.scroll and self.scroll.getScrolledOffset and self.scroll:getScrolledOffset()
  self:rebuild(true)
  if offset and self.scroll and self.scroll.setScrolledOffset then
    self.scroll:setScrolledOffset(offset)
  end
end

-- The lists the book is on are known (or changed): `rows` is Lists.membership's
-- result, kept on the detail so the picker does not ask again and the line under
-- the status can name them. Keeps the cover and the scroll position.
--
function BookDetailDialog:setLists(rows)
  local detail = self.detail or {}
  self.detail = detail
  detail.lists = rows

  local offset = self.scroll and self.scroll.getScrolledOffset and self.scroll:getScrolledOffset()
  self:rebuild(true)
  if offset and self.scroll and self.scroll.setScrolledOffset then
    self.scroll:setScrolledOffset(offset)
  end
end

--
-- Fill in the detail after the fetch lands.
--
-- Rebuilds by re-running init, which is correct here because every widget in the
-- body is a pure function of self.detail -- see the note in init. Freeing the
-- old body first matters: Menu/ScrollableContainer hold Blitbuffers, and leaving
-- them for the garbage collector is how a dialog ends up painting a freed
-- widget's _bb.
--
function BookDetailDialog:setDetail(detail)
  self.detail = detail
  self.loading = false
  self:rebuild()
end

function BookDetailDialog:onShowDetail()
  UIManager:show(self)
  UIManager:setDirty(self, "ui")
end

-- UIManager:close() repaints whatever was underneath into the framebuffer, but
-- queues no refresh of its own: with no mode given, _refresh() drops it. Stock
-- widgets queue theirs from here, and this one extends FocusManager, which does
-- not. Without it the dialog stays on the e-ink panel after it has closed,
-- until something else refreshes that area.
function BookDetailDialog:onCloseWidget()
  self.closed = true
  self:releaseCover()
  UIManager:setDirty(nil, "ui")
end

function BookDetailDialog:onCloseDetail()
  UIManager:close(self)
  return true
end

function BookDetailDialog:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

-- Delegates to StatusDialogs, which is where every other error message in the
-- plugin is built. This was a third implementation of the same thing, with no
-- timeout at all -- so a message shown here had no defined lifetime and no
-- guaranteed icon.
function BookDetailDialog:showError(message)
  return StatusDialogs.error(message)
end

return BookDetailDialog
