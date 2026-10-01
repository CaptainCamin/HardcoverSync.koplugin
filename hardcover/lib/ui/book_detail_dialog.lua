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
local InfoMessage = require("ui/widget/infomessage")
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

local Screen = Device.screen

local BookDetailDialog = FocusManager:extend {
  name = "hardcover_book_detail",
  title = _("Book details"),
  detail = nil,
  width = nil,
  height = nil,
}

function BookDetailDialog:init()
  self.width = Screen:getWidth() - Screen:scaleBySize(40)
  self.height = Screen:getHeight() - Screen:scaleBySize(60)

  self.key_events.CloseDialog = { { "Back" } }

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
      width = self.width,
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

  local detail = self.detail or {}
  local book = detail.book or {}

  self.title_text = TextWidget:new {
    text = book.title or _("Unknown title"),
    face = Font:getFace("cfont", 20),
    width = self.width,
    is_title = true,
  }

  if book.subtitle and book.subtitle ~= "" then
    self.subtitle_text = TextWidget:new {
      text = book.subtitle,
      face = Font:getFace("cfont", 16),
      width = self.width,
    }
  end

  -- the reader's own standing with the book, above the metadata table
  local status_bits = {}
  if detail.status_id then
    table.insert(status_bits, Shelf.statusLabel(detail.status_id))
  end
  if detail.user_rating and detail.user_rating > 0 then
    table.insert(status_bits, tostring(detail.user_rating) .. "*")
  end

  self.status_text = TextWidget:new {
    text = table.concat(status_bits, "  "),
    face = Font:getFace("smallinfofont"),
    width = self.width,
  }

  --[[--
  Metadata rows: a fixed two column grid, label then value.

  The description is skipped here. Shelf.detailRows emits it as one of its
  rows, but the dialog gives it a dedicated wrapping box further down -- so
  leaving it in printed the whole description twice, once crammed into a
  two-column grid cell and once properly wrapped. Filtering it out at the
  display layer leaves Shelf.detailRows complete for any other caller that
  genuinely wants the description as a row.
  ]]
  local rows = Shelf.detailRows(book)
  self.meta_rows = {}

  for _, row in ipairs(rows) do
    if row.label ~= "Description" then
      local label = TextWidget:new {
        text = row.label,
        face = Font:getFace("cfont", 15),
        width = math.floor(self.width * 0.32),
      }
      local value = TextWidget:new {
        text = tostring(row.value),
        face = Font:getFace("cfont", 15),
        width = self.width - label.width - 20,
      }
      table.insert(self.meta_rows, HorizontalGroup:new { label, HorizontalSpan:new { width = 10 }, value })
    end
  end

  -- description is the only free text field, so it gets its own wrapping box
  self.description_text = nil
  if book.description and book.description ~= "" then
    self.description_text = TextBoxWidget:new {
      text = book.description,
      face = Font:getFace("cfont", 15),
      width = self.width - 20,
      height = math.floor(self.height * 0.3),
      alignment = "left",
    }
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

  local button_row = HorizontalGroup:new {
    close_button,
  }

  local content = VerticalGroup:new {
    self.title_text,
    self.subtitle_text,
    self.status_text,
    VerticalSpan:new { height = 10 },
  }

  for _, row in ipairs(self.meta_rows) do
    table.insert(content, row)
  end

  if self.description_text then
    table.insert(content, VerticalSpan:new { height = 10 })
    table.insert(content, self.description_text)
  end

  table.insert(content, VerticalSpan:new { height = 10 })

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

  self.layout = { { close_button } }

  self[1] = self.frame
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

  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil

  self:init()

  UIManager:setDirty(self, "ui")
end

function BookDetailDialog:onShowDetail()
  UIManager:show(self)
  UIManager:setDirty(self, "ui")
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