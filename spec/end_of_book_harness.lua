-- What the plugin does at the end of a book, and which end action leaves the asking to someone
-- else. Plain data, no KOReader.
--
-- Run with:  lua spec/end_of_book_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()
local check = r.test

local EndOfBook = require("hardcover/lib/end_of_book")

print("\n== whose end action it is ==")

check("nothing saved, and every KOReader action, is a built-in", function()
  assert(EndOfBook.kind(nil) == "builtin")
  for _, a in ipairs({ "pop-up", "nothing", "book_status", "book_status_file_browser", "delete_file",
    "next_file", "goto_beginning", "file_browser", "mark_read" }) do
    assert(EndOfBook.kind(a) == "builtin", a)
  end
end)

check("this plugin's value is told apart from another plugin's", function()
  assert(EndOfBook.kind(EndOfBook.ACTION) == "hardcover")
  assert(EndOfBook.kind("zen_end_book") == "custom")
end)

print("\n== the end event ==")

check("KOReader's pop-up, saved or not, is checked after the reader answers", function()
  assert(EndOfBook.onEnd(nil, false) == "check_later")
  assert(EndOfBook.onEnd("pop-up", false) == "check_later")
end)

check("mark as finished and either auto-mark switch write Read at once", function()
  assert(EndOfBook.onEnd("mark_read", false) == "mark")
  assert(EndOfBook.onEnd("pop-up", true) == "mark")
  assert(EndOfBook.onEnd(EndOfBook.ACTION, true) == "mark")
  assert(EndOfBook.onEnd("zen_end_book", true) == "mark")
end)

check("an action that shows a page or leaves the book is not a reason to write", function()
  for _, a in ipairs({ "nothing", "book_status", "book_status_file_browser", "delete_file", "next_file",
    "goto_beginning", "file_browser", EndOfBook.ACTION, "zen_end_book" }) do
    assert(EndOfBook.onEnd(a, false) == "none", a)
  end
end)

print("\n== the last-page prompt ==")

check("it is on by default for KOReader's own end actions", function()
  assert(EndOfBook.promptOnLastPage(nil, nil) == true)
  assert(EndOfBook.promptOnLastPage(nil, "pop-up") == true)
  assert(EndOfBook.promptOnLastPage(nil, "book_status") == true)
end)

check("it is off by default when an end page is selected, this plugin's or another's", function()
  assert(EndOfBook.promptOnLastPage(nil, EndOfBook.ACTION) == false)
  assert(EndOfBook.promptOnLastPage(nil, "zen_end_book") == false)
end)

check("the reader's choice wins over the default either way", function()
  assert(EndOfBook.promptOnLastPage(false, "pop-up") == false)
  assert(EndOfBook.promptOnLastPage(true, "zen_end_book") == true)
  assert(EndOfBook.promptOnLastPage(true, EndOfBook.ACTION) == true)
end)

print("\n== the last page ==")

check("only the final page counts, and a book with no pages never does", function()
  assert(EndOfBook.atLastPage(300, 300))
  assert(not EndOfBook.atLastPage(299, 300))
  assert(not EndOfBook.atLastPage(1, 0))
  assert(not EndOfBook.atLastPage(nil, 300))
  assert(not EndOfBook.atLastPage(5, nil))
end)

print("\n== one prompt per book ==")

check("the second trigger for the same book finds it already handled", function()
  local seen = {}
  assert(EndOfBook.once(seen, "/b/a.epub") == true)
  assert(EndOfBook.once(seen, "/b/a.epub") == false)
  assert(EndOfBook.once(seen, "/b/b.epub") == true)
end)

check("a book started again is asked about again", function()
  local seen = {}
  assert(EndOfBook.once(seen, "/b/a.epub") == true)
  EndOfBook.forget(seen, "/b/a.epub")
  assert(EndOfBook.once(seen, "/b/a.epub") == true)
  assert(EndOfBook.once(seen, "/b/b.epub") == true)
end)

r.finish()
