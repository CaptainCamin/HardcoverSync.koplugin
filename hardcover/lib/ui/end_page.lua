-- The page shown when a book ends and "Hardcover end page" is the End of document action.
-- A full screen: the book and where it stands, the rating, a review, and the one question.
--
-- opts.model(): { heading, title, author?, status, note?, rating?, rows = { { text, run } },
--   primary = { text, run, stay? }, secondary? = { text, run } }; stay: the page stays open after the tap
-- Rebuilt from model() on every render(), so a tap that changes the book shows at once.
-- Back and the close X leave without changing anything.

local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local UIManager = require("ui/uimanager")
local VerticalSpan = require("ui/widget/verticalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local EndPage = InputContainer:extend {
  name = "hardcover_end_page",
  opts = nil,
}

function EndPage:init()
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.ClosePage = { { "Back" } }
  self:render()
end

function EndPage:row(text, run, width)
  local h = Theme.px(64)
  local label = Theme.mmdText(text, "text", 21, { width = width - Theme.TOUCH_MIN })
  local line = HorizontalGroup:new { align = "center", label,
    Theme.hspan(math.max(0, width - label:getSize().w - Theme.px(24))), Theme.icon("chevron-right", Theme.px(24)) }
  return VerticalGroup:new { align = "left",
    TapRow:new { callback = run,
      CenterContainer:new { dimen = Geom:new { w = width, h = h }, line } },
    Theme.rule(width) }
end

function EndPage:render()
  local model = self.opts.model()
  local sw, sh = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local width = sw - 2 * M

  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("m"))
  local head = Theme.mmdText(model.heading, "strong", 22, { width = width - Theme.TOUCH_MIN })
  local close = TapRow:new { callback = function() self:onClosePage() end,
    dimen = Geom:new { w = Theme.TOUCH_MIN, h = Theme.TOUCH_MIN },
    Theme.box(Theme.TOUCH_MIN, Theme.TOUCH_MIN, Theme.icon("close", Theme.mmd.top_bar.icon), { border = 0 }) }
  table.insert(content, HorizontalGroup:new { align = "center", head,
    Theme.hspan(math.max(0, width - head:getSize().w - close:getSize().w)), close })
  table.insert(content, Theme.rule(width, true))
  table.insert(content, Theme.span("l"))

  local cw, ch = Theme.px(100), Theme.px(150)
  local text_w = width - cw - Theme.space.m
  local info = VerticalGroup:new { align = "left",
    Theme.mmdText(model.title, "strong", 28, { width = text_w }) }
  if model.author then
    table.insert(info, Theme.span("xs"))
    table.insert(info, Theme.mmdText(model.author, "text", 20, { secondary = true, width = text_w }))
  end
  table.insert(info, Theme.span("m"))
  local pill = Theme.mmdText(model.status, "strong", 19, { width = text_w - Theme.space.l })
  table.insert(info, Theme.box(pill:getSize().w + Theme.space.l, pill:getSize().h + Theme.space.s, pill,
    { radius = 20 }))
  table.insert(content, HorizontalGroup:new { align = "top",
    Theme.box(cw, ch, Theme.icon("book", math.floor(cw / 2)), { radius = 0 }),
    Theme.hspan(Theme.space.m), info })
  table.insert(content, Theme.span("l"))
  table.insert(content, Theme.rule(width))

  local rating = tonumber(model.rating)
  for _i, row in ipairs(model.rows) do
    local text = row.text
    if row.rating then
      text = rating and rating > 0 and (text .. ": " .. tostring(rating) .. " / 5") or text
    end
    table.insert(content, self:row(text, row.run, width))
  end

  local used = content:getSize().h
  content:resetLayout() -- getSize caches; more rows follow
  local buttons_h = Button.HEIGHT * (model.secondary and 2 or 1) + Theme.space.l * 2 + (model.note and Theme.px(60) or 0)
  table.insert(content, VerticalSpan:new { width = math.max(Theme.space.m, sh - used - buttons_h) })
  if model.note then
    table.insert(content, Theme.mmdText(model.note, "text", 18, { secondary = true, width = width }))
    table.insert(content, Theme.span("m"))
  end
  table.insert(content, Button.new { label = model.primary.text, w = width, primary = true,
    callback = function()
      if model.primary.stay then model.primary.run() else self:run(model.primary.run) end
    end })
  if model.secondary then
    table.insert(content, Theme.span("s"))
    table.insert(content, Button.new { label = model.secondary.text, w = width,
      callback = function() self:run(model.secondary.run) end })
  end

  self[1] = FrameContainer:new {
    background = Theme.WHITE, bordersize = 0, padding = 0, margin = 0,
    width = sw, height = sh,
    HorizontalGroup:new { Theme.hspan(M), content },
  }
  UIManager:setDirty(self, "ui")
end

-- A button answers the question: do it, then leave.
function EndPage:run(fn)
  UIManager:close(self)
  UIManager:setDirty(nil, "full")
  if fn then fn() end
end

function EndPage:onClosePage()
  UIManager:close(self)
  UIManager:setDirty(nil, "full")
  return true
end

local Dialog = {}

function Dialog.show(opts)
  local page = EndPage:new { opts = opts }
  UIManager:show(page, "full")
  return page
end

return Dialog
