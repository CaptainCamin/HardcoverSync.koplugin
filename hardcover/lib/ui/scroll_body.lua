-- The body of a long screen: its content laid out once, inside a scroll only when it needs one.
--
-- Content in a scroll is built `ScrollControl.gutter()` narrower, so the control never sits over it.
-- Rather than build at the full width to measure and then build it all again narrower, this builds it
-- once at the width it is shown at:
--   * with `height`, a cheap figure for how tall the content comes out (fixed-height rows), the choice
--     is made before anything is built;
--   * without it, the content is built for the scroll first (a screen that uses this is usually long),
--     and only a page that fits is built again at the full width, as it is shown with no scroll.
--
-- opts {
--   width,        the screen's width
--   room,         the height under the screen's head
--   build,        function(content_w) -> the content (a VerticalGroup whose children are the rows)
--   height,       optional function(content_w, limit) -> its height; may stop counting past `limit`
--   slack,        added to the content's height before it is compared with `room` (default 0)
--   margin,       the left margin (default Theme.margin)
--   show_parent,  for the ScrollableContainer
-- }
-- Returns the body, the ScrollableContainer (nil when the content fits) and the content.

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")

local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Theme = require("hardcover/lib/ui/theme")

local ScrollBody = {}

local function free(widget)
  if type(widget) == "table" and type(widget.free) == "function" then pcall(widget.free, widget) end
end

function ScrollBody.layout(opts)
  local M = opts.margin or Theme.margin
  local slack = opts.slack or 0
  local full_w = opts.width - 2 * M
  local scroll_w = full_w - ScrollControl.gutter()
  local function fits(h) return h + slack <= opts.room end

  local function plain(content)
    return HorizontalGroup:new { Theme.hspan(M), content }, nil, content
  end
  local function scrolled(content)
    local scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = opts.width, h = opts.room }, show_parent = opts.show_parent,
    }
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
    return ScrollControl.wrap(scroll, content), scroll, content
  end

  if opts.height then
    if fits(opts.height(full_w, opts.room - slack)) then return plain(opts.build(full_w)) end
    return scrolled(opts.build(scroll_w))
  end

  local narrow = opts.build(scroll_w)
  if not fits(narrow:getSize().h) then return scrolled(narrow) end
  if scroll_w == full_w then return plain(narrow) end
  local wide = opts.build(full_w)
  if fits(wide:getSize().h) then
    free(narrow)
    return plain(wide)
  end
  free(wide)
  return scrolled(narrow)
end

return ScrollBody
