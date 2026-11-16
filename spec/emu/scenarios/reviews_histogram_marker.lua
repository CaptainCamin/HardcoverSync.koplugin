--[[--
The Reviews histogram with the issue-#312 distribution: the bar count and the
average marker are checked by their painted rectangles, not by eye. The count
gets its own lane under the average's words, so the two cannot collide at any
CI screen size.

Screen: reviews_histogram_marker.
]]

local fixtures = require("fixtures")

local function centre(d) return d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2) end

return {
  name = "reviews_histogram_marker",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings, overrides = { getShelf = function() return {}, nil, false end } })
    fixtures.books_by_id[103].rating = 4.1
    fixtures.books_by_id[103].ratings_count = 95
    fixtures.books_by_id[103].ratings_distribution = {
      { rating = 3.0, count = 4 }, { rating = 3.5, count = 24 }, { rating = 4.0, count = 27 },
      { rating = 4.5, count = 24 }, { rating = 5.0, count = 16 },
    }

    -- Chart labels are painted by the canvas, not kept in the widget tree, so
    -- remember where each one was last painted while this screen is built.
    local Theme = require("hardcover/lib/ui/theme")
    local mmdText = Theme.mmdText
    local created = {}
    Theme.mmdText = function(...)
      local widget = mmdText(...)
      local paint = widget.paintTo
      widget.paintTo = function(self, bb, x, y)
        self._emu_chart_rect = { x = x, y = y, w = self:getSize().w, h = self:getSize().h }
        return paint(self, bb, x, y)
      end
      created[#created + 1] = widget
      return widget
    end

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local ReviewStore = require("hardcover/lib/review_store")
    local db = SqliteStore:new { path = os.getenv("KO_HOME") .. "/reviews.sqlite3" }
    db:clear()
    local store = ReviewStore:new { db = db }
    local manager = DialogManager:new { settings = settings, review_store = store }

    manager:showBookDetail(103)
    emu:pump()
    local details = emu.UIManager:getTopmostVisibleWidget()
    assert(details and details.reviews_heading, "the details screen has no Reviews heading")
    emu:shot("reviews_histogram_details")
    assert(emu:tap(centre(details.reviews_heading.dimen)), "tapping Reviews did nothing")
    emu:pump()

    local dialog = emu.UIManager:getTopmostVisibleWidget()
    assert(dialog and dialog.name == "hardcover_reviews_dialog", "Reviews did not open")
    assert(dialog.summary and dialog.summary.distribution and dialog.summary.distribution.total == 95,
      "the histogram fixture was not used")
    emu:shot("reviews_histogram_marker")

    Theme.mmdText = mmdText
    local counts, average_rect = {}, nil
    for _, widget in ipairs(created) do
      local rect = widget._emu_chart_rect
      if rect and widget.text == "27" then counts[#counts + 1] = rect end
      if rect and widget.text == "avg 4.1" then average_rect = average_rect or rect end
    end
    assert(#counts > 0, "the peak bar's count was not painted")
    assert(average_rect, "the average label was not painted")
    local count_rect, closest = nil, math.huge
    for _, rect in ipairs(counts) do
      local distance = math.abs((rect.y + math.floor(rect.h / 2)) - (average_rect.y + math.floor(average_rect.h / 2)))
      if distance < closest then count_rect, closest = rect, distance end
    end
    assert(count_rect.y > average_rect.y,
      string.format("the count (%d,%d) is not below the average (%d,%d)",
        count_rect.x, count_rect.y, average_rect.x, average_rect.y))
    local overlap, overlap_x, overlap_y = emu.Tree.overlaps(count_rect, average_rect, 0)
    assert(not overlap,
      string.format("count and average labels overlap by %dx%d: count %d,%d %dx%d, avg %d,%d %dx%d",
        overlap_x, overlap_y, count_rect.x, count_rect.y, count_rect.w, count_rect.h,
        average_rect.x, average_rect.y, average_rect.w, average_rect.h))

    emu:closeAll()
  end,
}
