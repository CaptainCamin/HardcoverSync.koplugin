-- Looking for a book among the files on the device: what is searched for, finding
-- KOReader's file searcher, and the ways opening it can go wrong.
--
-- Run with:  lua spec/device_search_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local DeviceSearch = dofile(PLUGIN .. "/hardcover/lib/device_search.lua")

print("\n== what is searched for ==")

check("the title, tidied; no author", function()
  assert(DeviceSearch.query({ title = "  Dune  ", authors = "Frank Herbert" }) == "Dune")
  assert(DeviceSearch.query({ title = "The   Left Hand of Darkness" }) == "The Left Hand of Darkness")
end)

check("a subtitle or a bracketed series suffix is left off", function()
  assert(DeviceSearch.query({ title = "Dune: Deluxe Edition" }) == "Dune")
  assert(DeviceSearch.query({ title = "Ninefox Gambit (The Machineries of Empire, #1)" }) == "Ninefox Gambit")
  assert(DeviceSearch.query({ title = "Unseen [Illustrated]" }) == "Unseen")
end)

check("a title that is only a subtitle marker is kept whole; nothing at all is nil", function()
  assert(DeviceSearch.query({ title = ": odd" }) == ": odd")
  assert(DeviceSearch.query({ title = "   " }) == nil)
  assert(DeviceSearch.query({}) == nil and DeviceSearch.query(nil) == nil and DeviceSearch.query({ title = 5 }) == nil)
end)

print("\n== the searcher ==")

check("found on the UI (file manager or reader), absent otherwise", function()
  local searcher = { onShowFileSearch = function() end }
  assert(DeviceSearch.find({ filesearcher = searcher }) == searcher)
  assert(DeviceSearch.available({ filesearcher = searcher }))
  assert(not DeviceSearch.available({}) and not DeviceSearch.available(nil))
  assert(not DeviceSearch.available({ filesearcher = {} }), "a searcher that cannot search")
end)

check("search opens KOReader's box with the query; the reasons it cannot", function()
  local got
  local ui = { filesearcher = { onShowFileSearch = function(_, text) got = text end } }
  assert(DeviceSearch.search(ui, { title = "Dune: Deluxe" }) == true and got == "Dune")
  local ok, why = DeviceSearch.search(ui, { title = " " })
  assert(ok == nil and why == "no_title")
  ok, why = DeviceSearch.search({}, { title = "Dune" })
  assert(ok == nil and why == "not_available")
  local broken = { filesearcher = { onShowFileSearch = function() error("boom") end } }
  ok, why = DeviceSearch.search(broken, { title = "Dune" })
  assert(ok == nil and why == "failed")
end)

r.finish()
