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

r.test("stripAstral drops four-byte characters (emoji) and tidies the spaces left", function()
  assert(TextUtil.stripAstral("Rat \240\159\144\128") == "Rat ")
  assert(TextUtil.stripAstral("\240\159\144\128") == "")
  assert(TextUtil.stripAstral("A \240\159\144\128 B") == "A B")
  -- BMP characters stay, accents and CJK included
  assert(TextUtil.stripAstral("Star \226\152\133 \195\169 \230\188\162") == "Star \226\152\133 \195\169 \230\188\162")
end)

r.test("stripAstral removes orphaned variation selectors but preserves ZWJ in Indic text", function()
  -- rainbow flag: U+1F3F3 U+FE0F U+200D U+1F308 → astral + FE0F gone, ZWJ remains (caller rejects)
  assert(TextUtil.stripAstral("\240\159\143\179\239\184\143\226\128\141\240\159\140\136") == "\226\128\141")
  -- FE0F after a BMP symbol is stripped (emoji presentation only)
  assert(TextUtil.stripAstral("\226\152\133\239\184\143") == "\226\152\133")
  -- Malayalam chillu N: U+0D28 U+0D4D U+200D — ZWJ between BMP chars is preserved
  assert(TextUtil.stripAstral("\224\180\168\224\181\141\226\128\141") == "\224\180\168\224\181\141\226\128\141")
end)

r.test("stripAstral preserves CJK Extension B characters (the CJK fallback draws them)", function()
  -- U+20BB7 (𠮷) is a legitimate Han character used in names, not emoji
  assert(TextUtil.stripAstral("\240\160\174\183\231\148\176") == "\240\160\174\183\231\148\176")
end)

r.finish()
