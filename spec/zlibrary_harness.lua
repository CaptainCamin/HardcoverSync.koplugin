-- Handing a book to the Z-library plugin's search.
--
-- Run with:  lua spec/zlibrary_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local Zlibrary = require("hardcover/lib/zlibrary")

local function fakePlugin(opts)
  opts = opts or {}
  local p = { searched = {}, dialogs = {} }
  function p:performSearch(q)
    if opts.search_raises then error("boom") end
    self.searched[#self.searched + 1] = q
  end
  function p:showMultiSearchDialog(pos, q)
    self.dialogs[#self.dialogs + 1] = q
  end
  return p
end

print("\n== the search text ==")

check("title then first author", function()
  assert(Zlibrary.query({ title = "Raven Stratagem", authors = "Yoon Ha Lee, Emily Woo Zeller" }) == "Raven Stratagem Yoon Ha Lee")
end)

check("no author: just the title", function()
  assert(Zlibrary.query({ title = "Snuff" }) == "Snuff")
  assert(Zlibrary.query({ title = "Snuff", authors = "" }) == "Snuff")
end)

check("whitespace is tidied", function()
  assert(Zlibrary.query({ title = "  A   Wizard\nof Earthsea ", authors = " Ursula K. Le Guin " }) == "A Wizard of Earthsea Ursula K. Le Guin")
end)

check("nothing to search for gives nil", function()
  assert(Zlibrary.query(nil) == nil and Zlibrary.query({}) == nil and Zlibrary.query({ title = "   " }) == nil)
end)

print("\n== finding the plugin ==")

check("it is found by what it can do, wherever it sits in the UI", function()
  local p = fakePlugin()
  local ui = { {}, { name = "something else" }, p }
  assert(Zlibrary.find(ui) == p and Zlibrary.available(ui))
end)

check("a plugin without the methods is not mistaken for it", function()
  assert(Zlibrary.find({ { performSearch = function() end } }) == nil)
  assert(Zlibrary.find({ {}, "x", 3 }) == nil)
  assert(Zlibrary.find(nil) == nil and not Zlibrary.available({}))
end)

print("\n== searching ==")

check("it runs the plugin's own search with the book's text", function()
  local p = fakePlugin()
  local ok = Zlibrary.search({ p }, { title = "Kindred", authors = "Octavia E. Butler" })
  assert(ok == true and p.searched[1] == "Kindred Octavia E. Butler" and #p.dialogs == 0)
end)

check("not installed says so, without raising", function()
  local ok, why = Zlibrary.search({}, { title = "Kindred" })
  assert(ok == nil and why == "not_installed")
end)

check("a book with no title says so, and nothing is searched", function()
  local p = fakePlugin()
  local ok, why = Zlibrary.search({ p }, { authors = "X" })
  assert(ok == nil and why == "no_title" and #p.searched == 0)
end)

check("if its search raises, its search screen opens with the text instead", function()
  local p = fakePlugin { search_raises = true }
  local ok = Zlibrary.search({ p }, { title = "Kindred" })
  assert(ok == true and p.dialogs[1] == "Kindred", "fallback not used")
end)

r.finish()
