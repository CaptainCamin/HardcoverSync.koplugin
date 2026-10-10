-- Read-only detail view for a single Hardcover book: description, metadata,
-- and the reader's own status/rating.
--
-- Follows the plugin's existing dialog conventions (see journal_dialog.lua and
-- the skill's e-ink rules): one fullscreen frame so the reader UI does not show
-- through, text updated in place via setText rather than by rebuilding layout,
-- and Back handled through FocusManager's key_events.

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
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
local TopContainer = require("ui/widget/container/topcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local Clamp = require("hardcover/lib/ui/clamp")
local DetailsScreen = require("hardcover/lib/ui/details_screen")
local Draw = require("hardcover/lib/ui/components/draw")
local Lists = require("hardcover/lib/lists")
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
local ABOUT_LINES = 5
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
]]
local function contentWidth(screen_w)
  local gutter = ScrollControl.gutter()
  return screen_w - 2 * Theme.margin - gutter
end

-- A section's start: a dotted rule and a small Black label, tight. (The heavy rule under a heading is
-- for screens of their own.) The page is a stack of these, each one block for the scroll control.
local function section(label, width)
  local group = VerticalGroup:new { align = "left", Theme.span("s"), Theme.dottedRule(width), Theme.span("s") }
  if label then
    table.insert(group, Theme.mmdText(label, "strong", 18, { width = width }))
    table.insert(group, Theme.span("xs"))
  end
  return group
end

local BookDetailDialog = FocusManager:extend {
  name = "hardcover_book_detail",
  title = _("Book details"),
  detail = nil,
  -- called with no arguments when Reviews is tapped; no callback, no button
  on_reviews = nil,
  -- called with no arguments when Lists is tapped (the lists to put the book on);
  -- no callback, no button
  on_lists = nil,
  on_refresh = nil, -- the title bar's reload icon; nil hides it
  -- called with the dialog when On device is tapped (look for the book among the files
  -- on this device); no callback, no button
  on_find = nil,
  -- present only when the Z-library plugin is installed (see hardcover/lib/zlibrary.lua)
  on_zlibrary = nil,
  -- tapping the series or the author: called with the dialog and what to look for (the
  -- series' name, the author's name). No callback, nothing tappable.
  on_series = nil,
  -- tapping your rating: called with the dialog. No callback, not tappable.
  on_rating = nil,
  on_author = nil,
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

function BookDetailDialog.coverBox(screen_w)
  local cover_width = math.floor(contentWidth(screen_w) * BookDetailDialog.COVER_SHARE)
  return cover_width, math.floor(cover_width * 1.5)
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

  -- everything below is laid out in this width (see contentWidth above)
  local width = contentWidth(screen_w)
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
  local cover_width, cover_height = BookDetailDialog.coverBox(screen_w)
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
  -- `widget` made tappable when there is a handler and something to hand it
  -- `edge` puts the words at the "bottom" or "top" of their touch cell (at least 48 tall), so two links
  -- one above the other (the author, the series) can sit as close as lines of text while each keeps
  -- its own full-size target
  local function tappable(field, widget, handler, arg, edge)
    self[field] = nil
    if not (handler and arg) then return widget end
    local cell = Geom:new { w = text_width, h = math.max(widget:getSize().h, Theme.TOUCH_MIN) }
    local Holder = edge == "bottom" and BottomContainer or (edge == "top" and TopContainer or LeftContainer)
    self[field] = TapRow:new {
      callback = function() handler(self, arg) end, viewport = viewport,
      Holder:new { dimen = cell, widget },
    }
    return self[field]
  end

  self.title_text = wrapped(summary.title, "display", true, false, "title")
  addTo(column, self.title_text)
  if summary.subtitle then
    self.subtitle_text = wrapped(summary.subtitle, "body", false, true)
    addTo(column, Theme.span("xs"))
    addTo(column, self.subtitle_text)
  else
    self.subtitle_text = nil
  end
  -- the author and the series sit right under the title, in the plain body size; each opens a
  -- search, which is not marked with an underline (an underline alone does not read as a link)
  if summary.authors then
    self.authors_text = wrapped(summary.authors, "small")
    addTo(column, tappable("author_tap", self.authors_text, self.on_author, summary.first_author, "bottom"))
  else
    self.authors_text = nil
  end
  self.series_text = nil
  self.status_text = nil
  if summary.series then
    self.series_text = wrapped(summary.series, "small", false, true)
    addTo(column, tappable("series_tap", self.series_text, self.on_series, summary.series_title, "top"))
  end
  if summary.facts then
    self.facts_text = wrapped(summary.facts, "small", false, true)
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
  local stars = HorizontalGroup:new { align = "center" }
  for i = 1, 5 do
    local name = mine >= i and "star-filled" or (mine >= i - 0.5 and "star-half" or "star")
    table.insert(stars, CenterContainer:new {
      dimen = Geom:new { w = star_cell, h = star_cell },
      Theme.icon(name, Theme.px(28)),
    })
  end
  local rating_row = HorizontalGroup:new {
    align = "center",
    LeftContainer:new {
      dimen = Geom:new { w = width - 5 * star_cell, h = star_cell },
      Theme.mmdText(_("Your rating"), "strong", 21, { width = width - 5 * star_cell }),
    },
    stars,
  }
  self.rating_tap = nil
  if self.on_rating then
    rating_row = TapRow:new { callback = function() self:on_rating() end, viewport = viewport, rating_row }
    self.rating_tap = rating_row
  end

  -- the buttons: Shelf (filled, the one main action, and where the book is on your shelves) over
  -- Reviews, both the width of the page; then Lists, On device and Z-library (when that plugin is
  -- there) as one row of smaller ones. They scroll with the page, so each tap is cut to the
  -- visible area (see viewport.lua) or one scrolled away could catch a tap meant for what is over it.
  self.shelf_button, self.lists_button, self.reviews_button, self.zlibrary_button = nil, nil, nil, nil
  self.find_button = nil
  local function button(field, text, handler, opts)
    opts = opts or {}
    local b = Button.new {
      label = text, w = opts.w or width, h = opts.h or Theme.TOUCH_MIN, size = opts.size or 19, primary = opts.primary,
      viewport = viewport,
      callback = function()
        local fn = self[handler]
        if fn then fn(self) end
      end,
    }
    self[field] = b
    return b
  end
  local action_bar = VerticalGroup:new { align = "left" }
  table.insert(action_bar, button("shelf_button", Shelf.shelfButtonText((self.detail or {}).status_id), "on_shelf",
    { primary = true }))
  if self.on_reviews then
    table.insert(action_bar, Theme.span("s"))
    table.insert(action_bar, button("reviews_button", _("Reviews"), "on_reviews"))
  end
  local small = {}
  if self.on_lists then small[#small + 1] = { "lists_button", _("Lists"), "on_lists" } end
  if self.on_find then small[#small + 1] = { "find_button", _("On device"), "on_find" } end
  if self.on_zlibrary then small[#small + 1] = { "zlibrary_button", _("Z-library"), "on_zlibrary" } end
  local small_row
  if #small > 0 then
    local gap = Theme.space.s
    local each = math.floor((width - (#small - 1) * gap) / #small)
    small_row = HorizontalGroup:new { align = "top" }
    for i, spec in ipairs(small) do
      if i > 1 then table.insert(small_row, HorizontalSpan:new { width = gap }) end
      table.insert(small_row, button(spec[1], spec[2], spec[3], { w = each, h = Theme.px(48), size = 18 }))
    end
    table.insert(action_bar, Theme.span("s"))
    table.insert(action_bar, small_row)
  end
  self.action_bar = action_bar

  -- About: five lines at most, so the block is the same height for every book; a Read more opens
  -- the whole synopsis on a screen of its own
  self.description_text, self.about_more = nil, nil
  local about
  if summary.description then
    local clamped, cut = Clamp.text {
      text = summary.description, face = Theme.face("small"), width = width, lines = ABOUT_LINES,
    }
    self.description_text = clamped
    about = section(_("About"), width)
    table.insert(about, clamped)
    if cut then
      local more_w = Screen:scaleBySize(140)
      self.about_more = Button.new {
        label = _("Read more"), w = more_w, h = Theme.px(48), size = 18, viewport = viewport,
        callback = function()
          UIManager:show(TextScreen:new { title = _("About"), heading = summary.title, text = summary.description })
        end,
      }
      table.insert(about, Theme.span("s"))
      table.insert(about, HorizontalGroup:new { HorizontalSpan:new { width = width - more_w }, self.about_more })
    end
  end

  -- the genres, one line, with "+N more" for the rest (and the moods and content warnings)
  local tags = self:tagsBlock(width, viewport, summary.title)

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
  add(VerticalGroup:new { align = "left", Theme.span("xs"), rating_row })
  add(about)
  add(tags)

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
          UIManager:show(DetailsScreen:new { title = _("All details"), rows = extra })
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
  table.insert(self.layout, { self.shelf_button })
  if self.reviews_button then table.insert(self.layout, { self.reviews_button }) end
  local smalls = {}
  for _i, spec in ipairs(small) do smalls[#smalls + 1] = self[spec[1]] end
  if #smalls > 0 then table.insert(self.layout, smalls) end
  for _i, strip in ipairs({ self.carousel or false, self.similar_carousel or false }) do
    if strip and strip.paged then
      table.insert(self.layout, { strip.prev, strip.next })
    end
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
        UIManager:show(TextScreen:new { title = _("Tags"), heading = title, text = table.concat(parts, "\n\n") })
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