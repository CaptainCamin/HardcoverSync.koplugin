-- BUG: a page update with no mapped page erases the queued progress (online: sends null).
--
-- PageMapper:getRemotePagePercent returns a single value (1) when the page map
-- exists and the raw page is past its last page, so in
-- HardcoverApp:pageUpdateEvent (track-by-progress) `mapped_page` is nil and
-- _handlePageUpdate(file, nil) -> Cache:syncPage(file, nil) runs.
-- Offline, SyncQueue:enqueuePage then does `entry.mapped_page = payload.mapped_page`
-- (hardcover/lib/sync_queue.lua), which overwrites the real queued page with nil:
-- the entry becomes "empty" and the earlier progress is gone. Online, the same
-- nil goes to updatePage as `progress_pages: null`.
--
-- Expected: getRemotePagePercent returns the mapped page there, and/or enqueuePage
-- ignores a nil page instead of clearing what is queued.
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
local PageMapper = require("hardcover/lib/page_mapper")

print("\n== nil mapped page ==")

KB.check("getRemotePagePercent past the last mapped page still yields a page", function()
  local pm = PageMapper:new {
    state = { page_map = { [1] = 1, [2] = 2 }, page_map_range = { real_page = 2, last_page = 2 } },
    ui = {},
  }
  pm.checkIgnorePagemap = function() end -- the map is injected directly
  local percent, mapped = pm:getRemotePagePercent(5, 10, 300)
  KB.eq(percent, 1, "percent")
  KB.eq(mapped ~= nil, true, "mapped page (second return value) is nil")
end)

KB.check("enqueuePage with a nil page keeps the page already queued", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 7, edition_id = 3 })
  q:enqueuePage("/books/a.epub", { mapped_page = nil, book_id = 7, edition_id = 3 })
  local entry = q:get("/books/a.epub")
  KB.eq(entry and entry.mapped_page, 120, "queued page after a nil update")
end)

KB.finish("a nil mapped page must not wipe queued progress")
