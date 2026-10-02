-- The words of the sync-conflict questions, and the page conversion that goes
-- with "jump to Hardcover's page". (The queue side is in sync_queue_harness.lua.)
--
-- Run with:  lua spec/sync_conflicts_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
package.preload["ffi/util"] = function()
  return { template = function(t, ...)
    local args = { ... }
    return (tostring(t):gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
  end }
end

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SyncConflicts = require("hardcover/lib/sync_conflicts")

local results = { passed = 0, failed = 0 }
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.passed = results.passed + 1
    print("  [ok  ] " .. name)
  else
    results.failed = results.failed + 1
    print("  [FAIL] " .. name .. "\n         " .. tostring(err))
  end
end
local function eq(a, b, label)
  if a ~= b then error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function has(text, part, label)
  if not tostring(text):find(part, 1, true) then
    error((label or "text") .. " lacks '" .. part .. "': " .. tostring(text), 2)
  end
end

print("\n== sync conflict wording ==")

check("a book is named by its title, else by its file", function()
  eq(SyncConflicts.title("/b/x.epub", { title = "Dune" }), "Dune", "title")
  eq(SyncConflicts.title("/books/The Hobbit.epub", {}), "The Hobbit", "file name")
end)

check("a page conflict names both pages and offers the three answers", function()
  local d = SyncConflicts.describe("/b/x.epub", { title = "Dune", conflict = { kind = "page", local_page = 100, cloud_page = 240 } })
  has(d.title, "Dune"); has(d.title, "100"); has(d.title, "240")
  eq(#d.rows, 3, "rows")
  eq(d.rows[1].id, "cloud", "first"); eq(d.rows[2].id, "local", "second"); eq(d.rows[3].id, "later", "third")
  has(d.rows[1].text, "240"); has(d.rows[2].text, "100")
end)

check("a re-read question says what Hardcover has and asks plainly", function()
  local d = SyncConflicts.describe("/b/x.epub", { title = "Dune",
    conflict = { kind = "reread", local_page = 12, cloud_status = HARDCOVER.STATUS.FINISHED } })
  has(d.title, "Read"); has(d.title, "re-reading")
  eq(d.rows[1].id, "yes", "yes"); eq(d.rows[2].id, "no", "no"); eq(d.rows[3].id, "later", "later")
  local dnf = SyncConflicts.describe("/b/x.epub", { conflict = { kind = "reread", local_page = 1, cloud_status = HARDCOVER.STATUS.DNF } })
  has(dnf.title, "Did not finish")
end)

check("no conflict, no question", function()
  eq(SyncConflicts.describe("/b/x.epub", { mapped_page = 3 }), nil, "describe")
end)

check("the notice counts the books", function()
  has(SyncConflicts.notice(1), "1 book")
  has(SyncConflicts.notice(3), "3 books")
  has(SyncConflicts.menuText(2), "(2)")
end)

check("an edition page becomes a position in the file", function()
  eq(SyncConflicts.documentPage(150, 300, 600), 300, "halfway")
  eq(SyncConflicts.documentPage(999, 300, 600), 600, "never past the end")
  eq(SyncConflicts.documentPage(1, 300, 10), 1, "never before the start")
  eq(SyncConflicts.documentPage(10, nil, 600), nil, "unknown edition length")
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
