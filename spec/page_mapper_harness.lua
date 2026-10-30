-- PageMapper:getMappedPage: the proportional mapping when the file and the edition differ in length.
--
-- Run with:  lua spec/page_mapper_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local PageMapper = require("hardcover/lib/page_mapper")
local mapper = PageMapper:new({ state = {}, ui = {} })
mapper.checkIgnorePagemap = function() end

r.check("early pages of a longer file never map to page 0", mapper:getMappedPage(1, 1000, 300) == 1)
r.check("a page in the middle maps proportionally", mapper:getMappedPage(500, 1000, 300) == 150)
r.check("the last page maps to the last remote page", mapper:getMappedPage(1000, 1000, 300) == 300)
r.check("without remote pages the page is unchanged", mapper:getMappedPage(7, 1000, nil) == 7)
r.check("zero remote pages are unknown", mapper:getMappedPage(26, 304, 0) == 26)
r.check("zero remote pages unmap without division", mapper:getUnmappedPage(26, 304, 0) == 26)
local percent, page = mapper:getRemotePagePercent(26, 304, 0)
r.check("zero remote pages yield local progress", percent == 26 / 304 and page == 26)
mapper.state.page_map = { [26] = 17 }
mapper.state.page_map_range = { last_page = 26, real_page = 40 }
percent, page = mapper:getRemotePagePercent(26, 304, 0)
r.check("zero remote pages preserve page labels", percent == 129 / 304 and page == 17)
r.check("zero remote pages use the final page label", mapper:getMappedPage(27, 304, 0) == 40)

r.finish()
