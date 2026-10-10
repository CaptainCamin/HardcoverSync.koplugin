-- Is a book on this device: the plugin's table of linked files, and opening one.
--
-- Run with:  lua spec/on_device_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local OnDevice = require("hardcover/lib/on_device")
local everything = function() return true end

check("a linked file for the book is found", function()
  local books = { ["/b/dune.epub"] = { book_id = 7 }, ["/b/other.epub"] = { book_id = 8 } }
  assert(OnDevice.file(books, 7, everything) == "/b/dune.epub")
  assert(OnDevice.file(books, 9, everything) == nil, "found a book that is not there")
end)

check("a file that is gone is skipped", function()
  local books = { ["/b/gone.epub"] = { book_id = 7 }, ["/b/here.epub"] = { book_id = 7 } }
  assert(OnDevice.file(books, 7, function(f) return f == "/b/here.epub" end) == "/b/here.epub")
  assert(OnDevice.file(books, 7, function() return false end) == nil)
end)

check("two files for one book: always the same one (name order)", function()
  local books = { ["/b/z.epub"] = { book_id = 7 }, ["/b/a.epub"] = { book_id = 7 }, ["/b/m.epub"] = { book_id = 7 } }
  for _ = 1, 5 do assert(OnDevice.file(books, 7, everything) == "/b/a.epub") end
end)

check("nothing to look in, or no id: nil, never an error", function()
  assert(OnDevice.file(nil, 7, everything) == nil)
  assert(OnDevice.file({}, nil, everything) == nil)
  assert(OnDevice.file({ ["/b/x"] = "not a table" }, 7, everything) == nil)
end)

r.finish()
