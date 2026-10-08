--[[--
The library database on the real SQLite: a file made by 1.7.0-beta.1 (schema 1) is
brought up to date without losing its lists, and the shelf table works against the real
library (order, moves, NULL ratings, eviction keeping shelf books).

No screens.
]]

-- The exact statements 1.7.0-beta.1 created its file with (schema version 1).
local BETA1 = {
  "CREATE TABLE IF NOT EXISTS books (book_id INTEGER PRIMARY KEY, row TEXT NOT NULL, saved_at INTEGER)",
  "CREATE TABLE IF NOT EXISTS details (book_id INTEGER NOT NULL, edition_id INTEGER NOT NULL, data TEXT NOT NULL, opened_at INTEGER, PRIMARY KEY (book_id, edition_id))",
  "CREATE TABLE IF NOT EXISTS blobs (key TEXT PRIMARY KEY, data TEXT NOT NULL)",
  "CREATE TABLE IF NOT EXISTS refs (owner TEXT NOT NULL, book_id INTEGER NOT NULL)",
  "CREATE INDEX IF NOT EXISTS refs_owner ON refs (owner)",
  "CREATE INDEX IF NOT EXISTS refs_book ON refs (book_id)",
  "CREATE INDEX IF NOT EXISTS details_opened ON details (opened_at)",
}

return {
  name = "library_store",

  run = function(emu)
    local SQ3 = require("lua-ljsqlite3/init")
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local BookStore = require("hardcover/lib/book_store")
    local ListStore = require("hardcover/lib/list_store")
    local ShelfStore = require("hardcover/lib/shelf_store")

    local path = emu.DataStorage:getSettingsDir() .. "/hardcoversync_library_migration.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(path .. suffix) end

    -- ------------------------------------------------------------ a beta.1 file
    local conn = SQ3.open(path)
    for _, statement in ipairs(BETA1) do conn:exec(statement) end
    conn:exec("PRAGMA user_version=1;")
    conn:exec([[INSERT INTO books (book_id, row, saved_at) VALUES (1, '{"book_id":1,"title":"Kept from beta 1"}', 1)]])
    conn:exec([[INSERT INTO blobs (key, data) VALUES ('list:7:70', '{"fingerprint":"T|1","complete":true,"saved_at":1,"members":[{"book_id":1,"position":0}]}')]])
    conn:exec([[INSERT INTO blobs (key, data) VALUES ('lists:7', '{"mine":[{"id":70,"name":"Old list","count":1,"source":"mine"}],"following":[],"saved_at":1}')]])
    conn:exec([[INSERT INTO refs (owner, book_id) VALUES ('list:7:70', 1)]])
    conn:close()

    -- ------------------------------------------------------------ opened by this version
    local db = SqliteStore:new { path = path }
    local books = BookStore:new { db = db }
    local lists = ListStore:new { db = db, books = books }
    local shelves = ShelfStore:new { db = db, books = books }

    local entries = lists:entries(7, { id = 70, ranked = false })
    assert(entries and #entries == 1 and entries[1].title == "Kept from beta 1", "beta 1's saved list was lost")
    assert(lists:index(7).mine[1].name == "Old list", "beta 1's index was lost")
    local missing = books:missing({ 1 })
    assert(#missing == 0, "a beta 1 book counts as partial")
    local version = SQ3.open(path):rowexec("PRAGMA user_version;")
    assert(tonumber(version) == SqliteStore.SCHEMA_VERSION, "the file is at version " .. tostring(version))

    -- ------------------------------------------------------------ shelves on the real library
    local FP = "3|T|9.0"
    assert(shelves:putEntries(7, 3, {
      { user_book_id = 11, book_id = 2, title = "Two", user_rating = 4.5, date_added = "2026-01-02" },
      { user_book_id = 12, book_id = 3, title = "Three", date_added = "2026-01-01" }, -- no rating: a NULL
      { user_book_id = 13, book_id = 4, title = "Four", user_rating = 4.5, date_added = "2025-12-31" },
    }, true, FP), "putEntries")
    local read = shelves:entries(7, 3)
    assert(#read == 3 and read[1].book_id == 2 and read[2].book_id == 3 and read[3].book_id == 4, "order")
    assert(read[2].user_rating == nil and read[3].user_rating == 4.5, "a NULL rating shifted the columns")
    assert(read[2].user_book_id == 12 and read[2].date_added == "2026-01-01", "columns after a NULL")
    local m = shelves:member(7, 3)
    assert(m and m.status_id == 3 and m.rating == nil and type(m.user_book_id) == "number", "member")

    shelves:moveBook(7, 3, 2)
    assert(shelves:member(7, 3).status_id == 2 and shelves:entries(7, 2) == nil, "a moved book needs no saved shelf")
    shelves:putEntries(7, 2, {}, true, "0||")
    shelves:moveBook(7, 4, 2)
    local reading = shelves:entries(7, 2)
    assert(#reading == 1 and reading[1].book_id == 4, "moved into a saved shelf")
    assert(#shelves:entries(7, 3) == 1, "the moved books are still on Read")

    -- saving a list must not drop shelf books
    lists:putEntries(7, { id = 71, fingerprint = "x" }, { { book_id = 9, title = "Listed" } }, true)
    assert(books:rows({ 2 })[2] and books:rows({ 9 })[9] and books:rows({ 1 })[1], "eviction dropped a held book")

    -- the old file's cut synopses are partial
    books:saveRows({ { book_id = 20, title = "Cut" } }, true)
    local m20 = books:missing({ 20 })
    assert(#m20 == 1, "a partial row counted as saved")

    assert(books:clear() and shelves:entries(7, 3) == nil and shelves:member(7, 2) == nil, "clear")
    db:close()
    print("  library_store: beta 1 file migrated to version " .. SqliteStore.SCHEMA_VERSION .. "; shelves OK")
  end,
}
