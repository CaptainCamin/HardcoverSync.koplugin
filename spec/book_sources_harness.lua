-- Choosing between the Z-library, Anna's Archive and Kindle Fetch plugins.
--
-- Run with:  lua spec/book_sources_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local BookSources = require("hardcover/lib/book_sources")

local function zlib()
  local p = { got = {} }
  function p:performSearch(q) self.got[#self.got + 1] = q end
  function p:showMultiSearchDialog() end
  return p
end
local function annas()
  local p = { got = {} }
  function p:performSearch(q) self.got[#self.got + 1] = q end
  function p:displaySearchResults() end
  function p:downloadBook() end
  return p
end
local function kindle()
  local p = { got = {} }
  function p:searchFrom(q, page) self.got[#self.got + 1] = q .. "#" .. page end
  function p:searchInBackground() end
  return p
end
local BOOK = { title = "Kindred", authors = "Octavia E. Butler" }

print("\n== finding each plugin by what it can do ==")

check("each one is found and none is mistaken for another", function()
  local z, a, k = zlib(), annas(), kindle()
  local ui = { {}, z, a, k }
  assert(BookSources.find(ui, "zlibrary") == z)
  assert(BookSources.find(ui, "annas") == a)
  assert(BookSources.find(ui, "kindlefetch") == k)
  assert(BookSources.find({ a }, "zlibrary") == nil and BookSources.find({ z }, "annas") == nil)
  assert(BookSources.find(nil, "annas") == nil and BookSources.find({}, "nope") == nil)
end)

print("\n== resolving the choice ==")

check("a chosen source is used when installed, even if another is too", function()
  local z, a = zlib(), annas()
  local source, instance = BookSources.resolve({ z, a }, "annas")
  assert(source.id == "annas" and instance == a)
end)

check("a chosen source that is not installed does not fall back", function()
  assert(BookSources.resolve({ zlib() }, "annas") == nil)
  assert(not BookSources.available({ zlib() }, "kindlefetch"))
end)

check("auto takes the first installed one", function()
  assert(BookSources.resolve({ kindle(), annas() }, "auto").id == "annas")
  assert(BookSources.resolve({ kindle() }, nil).id == "kindlefetch")
  assert(BookSources.resolve({}, "auto") == nil)
end)

check("the label names the source, or the choice when it is missing", function()
  assert(BookSources.label({ annas() }, "auto") == "Anna's Archive")
  assert(BookSources.label({}, "kindlefetch") == "Kindle Fetch")
  assert(BookSources.label({}, "auto") == "Z-library")
end)

print("\n== searching ==")

check("each plugin gets the query its own way", function()
  local z, a, k = zlib(), annas(), kindle()
  assert(BookSources.search({ z }, BOOK, "zlibrary") == true and z.got[1] == "Kindred Octavia E. Butler")
  assert(BookSources.search({ a }, BOOK, "annas") == true and a.got[1] == "Kindred Octavia E. Butler")
  assert(BookSources.search({ k }, BOOK, "kindlefetch") == true and k.got[1] == "Kindred Octavia E. Butler#1")
end)

check("not installed and no title are reported, with the label", function()
  local ok, why, label = BookSources.search({}, BOOK, "annas")
  assert(ok == nil and why == "not_installed" and label == "Anna's Archive")
  ok, why = BookSources.search({ annas() }, { authors = "X" }, "annas")
  assert(ok == nil and why == "no_title")
end)

check("a plugin that raises is reported as failed", function()
  local a = annas()
  function a:performSearch() error("boom") end
  local ok, why = BookSources.search({ a }, BOOK, "annas")
  assert(ok == nil and why == "failed")
end)

check("Z-library's search screen is the fallback when its search raises", function()
  local z, dialogs = zlib(), {}
  function z:performSearch() error("boom") end
  function z:showMultiSearchDialog(_, q) dialogs[#dialogs + 1] = q end
  assert(BookSources.search({ z }, { title = "Kindred" }, "zlibrary") == true and dialogs[1] == "Kindred")
end)

r.finish()
