-- Where a scrolling page is, for moving it by whole views (a swipe up or down).

local ScrollPager = {}

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

return ScrollPager
