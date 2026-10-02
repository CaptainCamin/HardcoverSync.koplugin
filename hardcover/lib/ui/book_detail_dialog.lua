-- Read-only detail view for a single Hardcover book: description, metadata,
-- and the reader's own status/rating.
--
-- Follows the plugin's existing dialog conventions (see journal_dialog.lua and
-- the skill's e-ink rules): one fullscreen frame so the reader UI does not show
-- through, text updated in place via setText rather than by rebuilding layout,
-- and Back handled through FocusManager's key_events.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local LeftContainer = require("ui/widget/container/leftcontainer")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Shelf = require("hardcover/lib/shelf")
local SeriesCarousel = require("hardcover/lib/ui/series_carousel")
local Viewport = require("hardcover/lib/ui/viewport")

local Screen = Device.screen

local BookDetailDialog = FocusManager:extend {
  name = "hardcover_book_detail",
  title = _("Book details"),
  detail = nil,
  -- called with no arguments when Reviews is tapped; no callback, no button
  on_reviews = nil,
  width = nil,
  height = nil,
}

function BookDetailDialog:init()
  self.width = Screen:getWidth() - Screen:scaleBySize(40)
  self.height = Screen:getHeight() - Screen:scaleBySize(60)

  -- The event name picks the handler: CloseDetail runs onCloseDetail. This was
  -- CloseDialog, which has no handler, so the Back key did nothing -- including
  -- on the loading screen, which has no button, leaving a slow or hung fetch
  -- with no way out.
  self.key_events.CloseDetail = { { "Back" } }

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
      face = Font:getFace("cfont", 18),
      max_width = self.width,
    }
    self.loading_frame = FrameContainer:new {
      width = Screen:getWidth(),
      height = Screen:getHeight(),
      background = Blitbuffer.COLOR_WHITE,
      bordersize = 0,
      padding = 0,
      margin = 0,
      CenterContainer:new {
        dimen = Screen:getSize(),
        VerticalGroup:new { self.loading_text },
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
  viewport. Content as wide as the dialog is therefore always "too wide" by that
  gutter. Everything below is laid out in `width`, which leaves it free.
  ]]
  local gutter = 3 * (ScrollableContainer.scroll_bar_width or Screen:scaleBySize(6))
  local width = self.width - gutter
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
  local cover_width = math.floor(width * 0.30)
  local cover_height = math.floor(cover_width * 1.5)
  local cover_gap = 15
  -- the frame around the cover adds its border on both sides of the picture box
  local cover_border = Size.border.thin
  local text_width = width - cover_width - 2 * cover_border - cover_gap

  -- TextWidget is one line and reads max_width, not width; anything that may be
  -- long (a title, an author list) is a TextBoxWidget, which wraps to width.
  local function wrapped(text, size, bold)
    return TextBoxWidget:new {
      text = text,
      face = Font:getFace("cfont", size),
      bold = bold,
      width = text_width,
      alignment = "left",
    }
  end

  local column = VerticalGroup:new { align = "left" }
  local function addTo(group, widget)
    if widget then table.insert(group, widget) end
  end

  self.title_text = wrapped(summary.title, 22, true)
  addTo(column, self.title_text)
  if summary.subtitle then
    self.subtitle_text = wrapped(summary.subtitle, 16)
    addTo(column, self.subtitle_text)
  else
    self.subtitle_text = nil
  end
  if summary.authors then
    self.authors_text = wrapped(_("by") .. " " .. summary.authors, 17)
    addTo(column, VerticalSpan:new { width = 6 })
    addTo(column, self.authors_text)
  else
    self.authors_text = nil
  end
  if summary.series then
    self.series_text = wrapped(summary.series, 15)
    addTo(column, self.series_text)
  else
    self.series_text = nil
  end
  if summary.facts then
    self.facts_text = wrapped(summary.facts, 15)
    addTo(column, VerticalSpan:new { width = 6 })
    addTo(column, self.facts_text)
  else
    self.facts_text = nil
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

  -- the reader's own standing with the book, then what everyone else makes of it
  self.status_text = nil
  if summary.mine then
    self.status_text = TextWidget:new {
      text = summary.mine,
      face = Font:getFace("cfont", 17),
      bold = true,
      max_width = width,
    }
  end
  self.community_text = nil
  if summary.community then
    self.community_text = TextWidget:new {
      text = summary.community,
      face = Font:getFace("cfont", 15),
      max_width = width,
    }
  end

  local function heading(text)
    return TextWidget:new {
      text = text,
      face = Font:getFace("cfont", 17),
      bold = true,
      max_width = width,
    }
  end

  -- description: a heading, then the whole text. It is not clipped to a height
  -- (a TextBoxWidget given one hides the rest, and the scroll container around
  -- it cannot reveal it); it is as tall as the text and the body scrolls.
  self.description_text = nil
  if summary.description then
    self.description_text = TextBoxWidget:new {
      text = summary.description,
      face = Font:getFace("cfont", 16),
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
      face = Font:getFace("cfont", 15),
      max_width = label_width,
    }
    local label_cell = LeftContainer:new {
      dimen = Geom:new { w = label_width, h = label:getSize().h },
      label,
    }
    local value = TextBoxWidget:new {
      text = tostring(row.value),
      face = Font:getFace("cfont", 15),
      width = width - label_width - 20,
      alignment = "left",
    }
    table.insert(self.meta_rows, HorizontalGroup:new {
      align = "top",
      label_cell,
      HorizontalSpan:new { width = 10 },
      value,
    })
  end

  local close_button = Button:new {
    text = _("Close"),
    width = math.floor(self.width * 0.4),
    text_font_size = 18,
    bordersize = Size.border.thin,
    callback = function()
      self:onCloseDetail()
    end,
  }

  self.close_button = close_button

  local button_row = HorizontalGroup:new {
    close_button,
  }

  -- Built by appending, never as one table constructor: most things here are
  -- optional, and a nil in the middle of a constructor is a hole that
  -- VerticalGroup's ipairs stops at, so everything after it silently vanished.
  local content = VerticalGroup:new { align = "left" }
  local function add(widget)
    if widget then table.insert(content, widget) end
  end
  self.content_group = content

  add(header)
  add(VerticalSpan:new { width = 14 })
  add(self.status_text)
  add(self.community_text)

  if self.description_text then
    add(VerticalSpan:new { width = 14 })
    add(heading(_("About")))
    add(VerticalSpan:new { width = 6 })
    add(self.description_text)
  end

  -- Reviews: other readers' opinions, fetched only when asked for. A button
  -- right under About; it scrolls with the page, so its tap is cut to the
  -- visible area (see viewport.lua) or it could catch taps meant for Close.
  self.reviews_button = nil
  if self.on_reviews then
    self.reviews_button = Button:new {
      text = _("Reviews"),
      width = math.floor(width * 0.5),
      text_font_size = 18,
      bordersize = Size.border.thin,
      callback = function()
        if self.on_reviews then self.on_reviews() end
      end,
    }
    Viewport.limitButton(self.reviews_button, function() return self.scroll and self.scroll.dimen end)
    add(VerticalSpan:new { width = 14 })
    add(self.reviews_button)
  end

  -- "More in this series": a strip of covers, paged with arrows; tapping one
  -- opens that book. Below About, so the book itself comes first.
  self.carousel = nil
  if self.series_card then
    self.carousel = SeriesCarousel:new {
      card = self.series_card,
      width = width,
      -- what the scroll area is showing: taps outside it are not ours
      viewport = function() return self.scroll and self.scroll.dimen end,
      on_open = function(book_id)
        if self.on_open_book then self.on_open_book(book_id) end
      end,
      image_loader = self.image_loader or require("hardcover/lib/ui/image_loader"),
      on_change = function() UIManager:setDirty(self, "ui") end,
    }
    add(VerticalSpan:new { width = 14 })
    add(self.carousel.widget)
  end

  if #self.meta_rows > 0 then
    add(VerticalSpan:new { width = 14 })
    add(heading(_("Details")))
    add(VerticalSpan:new { width = 6 })
    for _, row in ipairs(self.meta_rows) do
      add(row)
    end
  end

  add(VerticalSpan:new { width = 10 })

  --[[--
  A full description plus every metadata row overflows a small e-ink screen, so
  the body scrolls and the close button stays pinned below it.

  ScrollableContainer takes its size from an explicit `dimen`, NOT from
  width/height -- initState reads self.dimen.w/h and paintTo writes
  self.dimen.x/y. Passing width/height therefore leaves dimen nil and the first
  paint dies with "attempt to index field 'dimen' (a nil value)", so the dialog
  never appeared at all.

  Two further things this used to get wrong:

    * button_row.height is nil. A HorizontalGroup sizes itself behind getSize();
      it has no .height field, so the subtraction raised "attempt to perform
      arithmetic on field 'height' (a nil value)".

    * button_row was also appended to the scroll's content, so the same widget
      was in two parents: it scrolled away with the body *and* was meant to
      stay pinned. It rendered twice.

  Keep the row out of the content, and resolve its size through getSize().
  ]]
  local button_row_size = button_row:getSize()

  local scroll_height = self.height - button_row_size.h - 20

  local scroll = ScrollableContainer:new {
    dimen = Geom:new {
      x = 0,
      y = 0,
      w = self.width,
      h = scroll_height,
    },
    show_parent = self,
    content,
  }

  self.scroll = scroll

  self.content_container = CenterContainer:new {
    dimen = Screen:getSize(),
    VerticalGroup:new { scroll, button_row },
  }

  -- a fullscreen white frame: a bare CenterContainer would let the reader UI
  -- show through behind the card
  self.frame = FrameContainer:new {
    width = Screen:getWidth(),
    height = Screen:getHeight(),
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    self.content_container,
  }

  -- keyboard / d-pad focus: the carousel's arrows (when it pages), then Close
  self.layout = {}
  if self.carousel and self.carousel.paged then
    table.insert(self.layout, { self.carousel.prev, self.carousel.next })
  end
  if self.reviews_button then
    table.insert(self.layout, { self.reviews_button })
  end
  table.insert(self.layout, { close_button })

  self[1] = self.frame

  self:loadCover(summary.cover, cover_width, cover_height)
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
  end)
  self.cover_halt = halt
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
function BookDetailDialog:rebuild()
  -- a rebuild means a new cover box; drop the old picture and any fetch for it
  self:releaseCover()

  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil

  self:init()

  UIManager:setDirty(self, "ui")
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