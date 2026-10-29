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

r.finish()
