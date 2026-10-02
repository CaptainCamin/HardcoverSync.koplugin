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
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Lists = require("hardcover/lib/lists")
local Shelf = require("hardcover/lib/shelf")
local SeriesCarousel = require("hardcover/lib/ui/series_carousel")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local BookDetailDialog = FocusManager:extend {
  name = "hardcover_book_detail",
  title = _("Book details"),
  detail = nil,
  -- called with no arguments when Reviews is tapped; no callback, no button
  on_reviews = nil,
  -- called with no arguments when Lists is tapped (the lists to put the book on);
  -- no callback, no button
  on_lists = nil,
  -- present only when the Z-library plugin is installed (see hardcover/lib/zlibrary.lua)
  on_zlibrary = nil,
  -- tapping the series pill, the status pill or the author: called with the
  -- dialog and what to look for (the series' name, the status id, the author's
  -- name). No callback, nothing tappable.
  on_series = nil,
  on_status = nil,
  on_author = nil,
  width = nil,
  height = nil,
}

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

  -- the family's title bar; its X is the Close button (the loading screen has
  -- one too, so a slow fetch can always be left)
  local title_bar = Theme.titleBar {
    title = self.title,
    close_callback = function() self:onCloseDetail() end,
    show_parent = self,
  }
  self.title_bar = title_bar
  self.close_button = title_bar.right_button

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
      fgcolor = Theme.DARK_GREY,
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

  --[[--
  The width the content may use.

  ScrollableContainer treats any content wider than its viewport as scrolling
  sideways and draws a horizontal scrollbar -- and once the page also scrolls
  vertically, its vertical scrollbar takes 3 * scroll_bar_width off that
  viewport. Content as wide as the page is therefore always "too wide" by that
  gutter. Everything below is laid out in `width`, which leaves it free; the
  left margin is added by an inset around the whole column.
  ]]
  local gutter = 3 * (ScrollableContainer.scroll_bar_width or Screen:scaleBySize(6))
  local width = screen_w - 2 * M - gutter
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
  local cover_width = math.floor(width * 0.34)
  local cover_height = math.floor(cover_width * 1.5)
  local cover_gap = Theme.space.l
  -- the frame around the cover adds its border on both sides of the picture box
  local cover_border = Theme.line.hair
  local text_width = width - cover_width - 2 * cover_border - cover_gap

  -- TextWidget is one line and reads max_width, not width; anything that may be
  -- long (a title, an author list) is a TextBoxWidget, which wraps to width.
  local function wrapped(text, size, bold, grey)
    return TextBoxWidget:new {
      text = text,
      face = Theme.face(size),
      bold = bold,
      width = text_width,
      alignment = "left",
      fgcolor = grey and Theme.DARK_GREY or Theme.BLACK,
    }
  end

  local column = VerticalGroup:new { align = "left" }
  local function addTo(group, widget)
    if widget then table.insert(group, widget) end
  end

  -- the header scrolls with the page, so taps are cut to what is showing (see
  -- viewport.lua)
  local viewport = function() return self.scroll and self.scroll.dimen end
  -- `widget` made tappable when there is a handler and something to hand it
  local function tappable(field, widget, handler, arg)
    self[field] = nil
    if not (handler and arg) then return widget end
    self[field] = Theme.touchable(widget, text_width, function() handler(self, arg) end, viewport)
    return self[field]
  end

  self.title_text = wrapped(summary.title, "display", true)
  addTo(column, self.title_text)
  if summary.subtitle then
    self.subtitle_text = wrapped(summary.subtitle, "body", false, true)
    addTo(column, Theme.span("xs"))
    addTo(column, self.subtitle_text)
  else
    self.subtitle_text = nil
  end
  if summary.authors then
    self.authors_text = wrapped(summary.authors, "title")
    addTo(column, Theme.span("s"))
    -- tappable: a hairline under the name says so, quietly
    local author = self.authors_text
    if self.on_author and summary.first_author then
      author = VerticalGroup:new {
        align = "left",
        self.authors_text,
        Theme.span("xs"),
        Theme.rule(text_width, false),
      }
    end
    addTo(column, tappable("author_tap", author, self.on_author, summary.first_author))
  else
    self.authors_text = nil
  end
  if summary.facts then
    self.facts_text = wrapped(summary.facts, "small", false, true)
    addTo(column, Theme.span("xs"))
    addTo(column, self.facts_text)
  else
    self.facts_text = nil
  end

  -- the series and where the book is on your shelves: pills, the current status
  -- filled; each opens the search for that series / the shelf for that status
  self.series_text = nil
  self.status_text = nil
  if summary.series then
    self.series_text = Theme.pill(summary.series, { max_width = text_width - 2 * Theme.space.m })
    addTo(column, Theme.span("s"))
    addTo(column, tappable("series_tap", self.series_text, self.on_series, summary.series_title))
  end
  local status_id = (self.detail or {}).status_id
  if status_id then
    self.status_text = Theme.pill(Shelf.statusLabel(status_id), { filled = true, max_width = text_width - 2 * Theme.space.m })
    addTo(column, tappable("status_tap", self.status_text, self.on_status, status_id))
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

  -- what everyone makes of it, then what you make of it: three figures between
  -- hairlines
  local cell_w = math.floor(width / 3)
  local cells = HorizontalGroup:new {}
  for _, stat in ipairs(Shelf.detailStats(self.detail)) do
    table.insert(cells, CenterContainer:new {
      dimen = Geom:new { w = cell_w, h = Screen:scaleBySize(78) },
      Theme.stat(stat[1], stat[2], cell_w),
    })
  end
  self.stats_strip = VerticalGroup:new {
    align = "left",
    Theme.rule(width, false),
    cells,
    Theme.rule(width, false),
  }

  local function heading(text, right)
    return Theme.sectionHeader(text, width, right)
  end

  -- description: a heading, then the whole text. It is not clipped to a height
  -- (a TextBoxWidget given one hides the rest, and the scroll container around
  -- it cannot reveal it); it is as tall as the text and the body scrolls.
  self.description_text = nil
  if summary.description then
    self.description_text = TextBoxWidget:new {
      text = summary.description,
      face = Theme.face("body"),
      width = width,
      alignment = "left",
    }
  end

  --[[--
  Details: what the header does not already say, as a two column grid.

  A fixed label column, so the values line up whatever the labels say: the label
  sits in a container of set width instead of sizing the column to its own text.
  The value wraps, so a long value stays on screen.
  ]]
  self.meta_rows = {}
  local label_width = math.floor(width * 0.32)
  for _, row in ipairs(Shelf.extraRows(book)) do
    local label = TextWidget:new {
      text = row.label,
      face = Theme.face("small"),
      max_width = label_width,
      fgcolor = Theme.DARK_GREY,
    }
    local label_cell = LeftContainer:new {
      dimen = Geom:new { w = label_width, h = label:getSize().h },
      label,
    }
    local value = TextBoxWidget:new {
      text = tostring(row.value),
      face = Theme.face("small"),
      width = width - label_width - Theme.space.m,
      alignment = "left",
    }
    table.insert(self.meta_rows, HorizontalGroup:new {
      align = "top",
      label_cell,
      HorizontalSpan:new { width = Theme.space.m },
      value,
    })
  end

  -- The action bar: Shelf (filled, the main one), then Lists and Reviews, then
  -- Z-library when that plugin is there, sharing the width equally. They scroll with the
  -- page, so each tap is cut to the visible area (see viewport.lua) or one
  -- scrolled away could catch a tap meant for what is over it.
  local labels = { { "shelf_button", Shelf.shelfButtonText((self.detail or {}).status_id), "on_shelf", true } }
  self.shelf_button, self.lists_button, self.reviews_button, self.zlibrary_button = nil, nil, nil, nil
  if self.on_lists then
    labels[#labels + 1] = { "lists_button", _("Lists"), "on_lists" }
  end
  if self.on_reviews then
    labels[#labels + 1] = { "reviews_button", _("Reviews"), "on_reviews" }
  end
  if self.on_zlibrary then
    labels[#labels + 1] = { "zlibrary_button", _("Z-library"), "on_zlibrary" }
  end
  local gap = Theme.space.s
  -- equal shares, except that Shelf (the longest label, "Shelf: Currently
  -- Reading") takes what its words need, up to half the bar, and the rest
  -- share what is left
  local n = #labels
  local widths = {}
  local equal = math.floor((width - (n - 1) * gap) / n)
  local shelf_w = equal
  if n > 1 then
    local words = TextWidget:new { text = labels[1][2], face = Theme.face("small"), bold = true }
    local need = words:getSize().w + 2 * Theme.space.l
    words:free()
    shelf_w = math.min(math.max(equal, need), math.floor(width / 2))
  end
  widths[1] = shelf_w
  for i = 2, n do
    widths[i] = math.floor((width - shelf_w - (n - 1) * gap) / (n - 1))
  end
  local action_bar = HorizontalGroup:new {}
  for i, spec in ipairs(labels) do
    local field, text, handler, primary = spec[1], spec[2], spec[3], spec[4]
    local button = Theme.button(text, widths[i], {
      filled = primary,
      viewport = viewport,
      callback = function()
        local fn = self[handler]
        if fn then fn(self) end
      end,
    })
    self[field] = button
    if i > 1 then table.insert(action_bar, HorizontalSpan:new { width = gap }) end
    table.insert(action_bar, button)
  end
  self.action_bar = action_bar

  -- Built by appending, never as one table constructor: most things here are
  -- optional, and a nil in the middle of a constructor is a hole that
  -- VerticalGroup's ipairs stops at, so everything after it silently vanished.
  local content = VerticalGroup:new { align = "left" }
  local function add(widget)
    if widget then table.insert(content, widget) end
  end
  self.content_group = content

  add(header)
  add(Theme.span("l"))
  add(self.stats_strip)
  add(Theme.span("m"))
  add(action_bar)

  if self.description_text then
    add(Theme.span("l"))
    add(heading(_("About")))
    add(Theme.span("s"))
    add(self.description_text)
  end

  -- "More in this series": a strip of covers, paged with arrows; tapping one
  -- opens that book. Below About, so the book itself comes first.
  self.carousel = nil
  if self.series_card then
    self.carousel = SeriesCarousel:new {
      card = self.series_card,
      width = width,
      -- what the scroll area is showing: taps outside it are not ours
      viewport = viewport,
      on_open = function(book_id)
        if self.on_open_book then self.on_open_book(book_id) end
      end,
      image_loader = self.image_loader or require("hardcover/lib/ui/image_loader"),
      on_change = function() UIManager:setDirty(self, "ui") end,
    }
    add(Theme.span("l"))
    add(self.carousel.widget)
  end

  if #self.meta_rows > 0 then
    add(Theme.span("l"))
    add(heading(_("Details")))
    add(Theme.span("xs"))
    for _, row in ipairs(self.meta_rows) do
      add(Theme.span("xs"))
      add(row)
      add(Theme.span("xs"))
      add(Theme.rule(width, false))
    end
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

  -- a fullscreen white frame: a bare container would let the reader UI show
  -- through behind the page
  self.frame = FrameContainer:new {
    width = screen_w,
    height = screen_h,
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new { align = "left", title_bar, scroll },
  }

  -- keyboard / d-pad focus: the action bar, the carousel's arrows (when it
  -- pages), then Close
  self.layout = {}
  local actions = {}
  for _, spec in ipairs(labels) do actions[#actions + 1] = self[spec[1]] end
  table.insert(self.layout, actions)
  if self.carousel and self.carousel.paged then
    table.insert(self.layout, { self.carousel.prev, self.carousel.next })
  end
  table.insert(self.layout, { self.close_button })

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
  local _, halt = loader:loadImages({ cover.url }, function(_, content)
    if self.closed or not self.cover_cell then return end

    local RenderImage = require("ui/renderimage")
    local bb = RenderImage:renderImageData(content, #content, false, width, height)
    if not bb then return end

    self:placeCover(bb, width, height)
  end)
  self.cover_halt = halt
end

function BookDetailDialog:placeCover(bb, width, height)
  self.cover_bb = bb
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
  UIManager:setDirty(self, "ui")
end

-- Stop fetching and give back the pictures' memory (the cover, and the
-- carousel's covers).
function BookDetailDialog:releaseCover()
  if self.carousel then
    self.carousel:release()
    self.carousel = nil
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

  self:init()

  UIManager:setDirty(self, "ui")
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