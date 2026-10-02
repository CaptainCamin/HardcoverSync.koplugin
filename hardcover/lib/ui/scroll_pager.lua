-- A "Page 1 of 2" bar with previous and next buttons, for a page that scrolls.
--
-- A scrolling page is moved by swiping, and a swipe is easy to miss on e-ink (it has to
-- be quick and long enough, and nothing on the page says it can be done). The lists and
-- shelves have a footer with page buttons; this gives a scrolling page the same, so
-- there is always a visible, tappable way to the rest of it. It moves the page by a
-- whole view at a time, as a swipe does, and says where the page is.
--
-- It follows the page: a swipe, a drag or the scroll bar changes the label too (the
-- container's own bookkeeping is hooked, and if a KOReader without that hook is
-- running the label simply updates when a button is used).

local Device = require("device")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local T = require("ffi/util").template
local _ = require("gettext")

local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local ScrollPager = {}

-- the bar's height, so the page can leave room for it
ScrollPager.HEIGHT = Theme.BUTTON_H + 2 * Theme.space.s

local PREV, NEXT = "\226\128\185", "\226\128\186" -- single angle quotes

--
-- Where a scroll container is: { page, pages, offset, max, step }. `step` is the
-- distance a button (or a swipe) moves. Sizes are known once the container has worked
-- them out (initState, which it does itself on first paint).
--
function ScrollPager.position(scroll)
  if scroll._is_scrollable == nil then scroll:initState() end
  local step = scroll._crop_h or scroll.dimen.h
  local max = scroll._max_scroll_offset_y or 0
  local offset = scroll:getScrolledOffset().y or 0
  local pages = (max > 0 and step > 0) and math.ceil((max + step) / step) or 1
  local page
  if offset <= 0 then
    page = 1
  elseif offset >= max then
    page = pages
  else
    page = math.min(pages, math.floor(offset / step) + 1)
  end
  return { page = page, pages = pages, offset = offset, max = max, step = step }
end

--
-- Build the bar for `scroll`, `width` wide. Returns { widget, refresh, go }:
-- `widget` goes under the scroll area, `refresh()` redraws the label and buttons from
-- where the page is, `go(delta)` moves by whole views (-1 up, 1 down).
--
function ScrollPager.new(scroll, width)
  local pager = {}

  local holder = CenterContainer:new { dimen = Geom:new { w = width, h = ScrollPager.HEIGHT } }

  function pager.go(delta)
    local p = ScrollPager.position(scroll)
    local target = math.max(0, math.min(p.max, p.offset + delta * p.step))
    if target == p.offset then return end
    -- scrollToRatio puts the middle of the view at a point of the whole page
    scroll:scrollToRatio(nil, (target + p.step / 2) / (p.max + p.step))
    pager.refresh()
  end

  local function build()
    local p = ScrollPager.position(scroll)
    local button_w = Theme.BUTTON_H + Theme.space.l
    local label = TextWidget:new {
      text = T(_("Page %1 of %2"), p.page, p.pages),
      face = Theme.face("small"),
      bold = true,
      fgcolor = Theme.BLACK,
    }
    local gap = Theme.space.l
    return HorizontalGroup:new {
      align = "center",
      Theme.button(PREV, button_w, {
        size = "title", enabled = p.page > 1, callback = function() pager.go(-1) end,
      }),
      Theme.hspan(gap),
      label,
      Theme.hspan(gap),
      Theme.button(NEXT, button_w, {
        size = "title", enabled = p.page < p.pages, callback = function() pager.go(1) end,
      }),
    }
  end

  function pager.refresh()
    holder[1] = build()
    UIManager:setDirty(holder, "ui")
  end

  holder[1] = build()
  pager.holder = holder
  pager.widget = VerticalGroup:new {
    align = "left",
    Theme.rule(width, false),
    holder,
  }

  -- follow swipes, drags and the scroll bar: the container tells its scroll bars
  -- whenever the page moves
  if type(scroll._updateScrollBars) == "function" then
    local original = scroll._updateScrollBars
    scroll._updateScrollBars = function(self, ...)
      local result = original(self, ...)
      pager.refresh()
      return result
    end
  end

  return pager
end

return ScrollPager
