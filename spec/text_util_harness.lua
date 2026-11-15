-- Shared text helpers.
--
-- Run with: luajit spec/text_util_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local TextUtil = require("hardcover/lib/text_util")

r.test("trim removes edge whitespace and keeps the middle", function()
  assert(TextUtil.trim("  one\ttwo  ") == "one\ttwo")
  assert(TextUtil.trim(" \t\r\n") == "")
end)

r.test("trim returns one value", function()
  local trimmed, extra = TextUtil.trim("  x  ")
  assert(trimmed == "x" and extra == nil)
end)

r.finish()
