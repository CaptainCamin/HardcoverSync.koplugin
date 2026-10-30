-- Local matching shared by the lists index and shelf/list contents.
--
-- Run with: luajit spec/local_search_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
-- ASCII logic here; Unicode matching uses the real utf8proc in the search emulator scenario.
package.preload["ffi/utf8proc"] = function() return { lowercase = string.lower } end
local LocalSearch = require("hardcover/lib/local_search")

r.test("empty queries leave the local collection unchanged", function()
  assert(LocalSearch.matches("", { "Earthsea" }))
  assert(LocalSearch.matches("   ", { "Earthsea" }))
end)

r.test("query words match case-insensitively across title and author fields", function()
  assert(LocalSearch.matches("EARTHSEA le guin", { "A Wizard of Earthsea", "Ursula K. Le Guin" }))
end)

r.test("a missing query word rejects the entry", function()
  assert(not LocalSearch.matches("earthsea dune", { "A Wizard of Earthsea", "Ursula K. Le Guin" }))
end)

r.test("a nil title does not hide a matching author", function()
  assert(LocalSearch.matches("le guin", { nil, "Ursula K. Le Guin" }))
end)

r.test("query punctuation is matched literally", function()
  assert(LocalSearch.matches("a+b", { "A+B" }))
  assert(not LocalSearch.matches("a.b", { "axb" }))
end)

r.finish()
