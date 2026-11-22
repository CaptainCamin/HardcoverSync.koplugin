-- The landing screen for a reader with no account on this device.
--
-- It says what the plugin does before asking for a sign-in, and keeps one primary
-- way in. The shell gives it the top bar and, when there are no other tabs to
-- show, leaves out the navigation bar (ui/shell.lua).

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local Hosted = require("hardcover/lib/ui/hosted")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Theme = require("hardcover/lib/ui/theme")

local px = Theme.px
local space = Theme.space

local WelcomeBody = InputContainer:extend {
  name = "hardcover_welcome",
  sign_in_cb = nil,
}

local function paragraph(text, width)
  local face, bold = Theme.mmdFace("text", Theme.type.body)
  return TextBoxWidget:new {
    text = text, face = face, bold = bold, width = width,
    fgcolor = Theme.secondary(),
  }
end

-- An informational row: an icon, a black label and one line about it. Nothing
-- here is tappable, so it is a drawn row rather than a list item with no action.
-- The icon sits in a fixed-width slot as tall as the label, so it lines up with
-- the bold line rather than the two lines of words.
local function feature(icon_name, label, detail, width)
  local slot_w = Theme.TOUCH_MIN
  local text_w = width - slot_w - space.s
  local title = Theme.mmdText(label, "strong", 20, { width = text_w })
  local icon = CenterContainer:new { dimen = Geom:new { w = slot_w, h = title:getSize().h },
    Theme.icon(icon_name, px(24)) }
  local words = VerticalGroup:new { align = "left",
    title,
    Theme.span("xs"),
    paragraph(detail, text_w),
  }
  return VerticalGroup:new { align = "left",
    HorizontalGroup:new { align = "top", icon, Theme.hspan("s"), words },
    Theme.span("l"),
    Theme.dottedRule(width),
    Theme.span("s"),
  }
end

function WelcomeBody:init()
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }

  local side = Theme.margin
  local width = w - 2 * side
  local intro = VerticalGroup:new { align = "left",
    Theme.span("m"),
    Theme.mmdText(_("Welcome to Hardcover Sync"), "strong", Theme.type.display, { width = width }),
    Theme.span("s"),
    paragraph(_("Hardcover Sync connects the books on this reader to your Hardcover account."), width),
  }
  local head = ListItem.section(_("What it does"), w, space.xl)

  local features = {
    { "book-open", _("Track your reading"), _("Log pages and mark books read without leaving your book.") },
    { "shelves", _("Keep shelves in sync"), _("Your Hardcover shelves stay in sync.") },
    { "stats", _("See your progress"), _("Reading goals, ratings and notes travel with your account.") },
  }

  self.sign_in_button = Button.new {
    label = _("Sign in to Hardcover"), w = width, h = Button.HEIGHT, primary = true,
    callback = function() if self.sign_in_cb then self.sign_in_cb() end end,
  }
  local sign_in = VerticalGroup:new { align = "left",
    Theme.span("xl"),
    self.sign_in_button,
  }

  local head_gap = Theme.span("m")
  local column = VerticalGroup:new { align = "left" }
  column[#column + 1] = HorizontalGroup:new { Theme.hspan(side), intro }
  column[#column + 1] = head
  column[#column + 1] = head_gap

  -- Rows keep their height; on a short panel the last explanation drops away
  -- before the sign-in button does.
  local used = intro:getSize().h + head:getSize().h + head_gap:getSize().h
    + sign_in:getSize().h
  for _, item in ipairs(features) do
    local row = feature(item[1], item[2], item[3], width)
    local row_h = row:getSize().h
    if used + row_h > h then break end
    column[#column + 1] = HorizontalGroup:new { Theme.hspan(side), row }
    used = used + row_h
  end
  column[#column + 1] = HorizontalGroup:new { Theme.hspan(side), sign_in }
  column:resetLayout()

  self.frame = FrameContainer:new {
    width = w, height = h, background = Theme.WHITE,
    bordersize = 0, padding = 0, margin = 0, column,
  }
  self[1] = self.frame
end

function WelcomeBody:onShow() end

function WelcomeBody:onClose()
  return true -- the shell leaves, not a tab
end

return WelcomeBody
