--[[--
"Link all books on this device" from the real settings screen, with real widgets: tapping the row (the
settings screen hands its callbacks a stand-in menu, and closing that crashed KOReader), the confirmation,
the progress message, the summary, the guess for the books left over and its review, and tapping the
progress message to stop. Then "Save details of linked books" for books linked earlier.

Hardcover is replaced by a fake that answers a batch at a time; the files are real EPUBs (a zip with an
OPF) in a folder made for the run.

Screens: link_all_confirm, link_all_progress, link_all_done, link_all_guessed, link_all_review, link_all_stopped,
save_details_done.
]]

local fixtures = require("fixtures")

-- an EPUB with an ISBN, or (no isbn) with only a title and an author
local function makeEpub(dir, name, isbn, author)
  local opf = dir .. "/" .. name .. ".opf"
  local f = assert(io.open(opf, "w"))
  f:write(string.format([[<package><metadata xmlns:dc="x" xmlns:opf="y">
<dc:title>%s</dc:title>%s%s
</metadata></package>]], name,
    isbn and string.format('\n<dc:identifier opf:scheme="ISBN">%s</dc:identifier>', isbn) or "",
    author and string.format("\n<dc:creator>%s</dc:creator>", author) or ""))
  f:close()
  local epub = dir .. "/" .. name .. ".epub"
  assert(os.execute(string.format("zip -q -j '%s' '%s'", epub, opf)), "zip failed")
  os.remove(opf)
  return epub
end

return {
  name = "link_all_books",

  run = function(emu)
    local NetworkManager = require("ui/network/manager")
    NetworkManager.isConnected = function() return true end

    local home = os.getenv("KO_HOME") .. "/link_home"
    os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "'")
    local files = {}
    for i = 1, 3 do
      files[i] = makeEpub(home, "Fixture Book " .. i, "97800000000" .. string.format("%02d", i))
    end
    -- no identifier: only a guess from its title and author can link it
    files[4] = makeEpub(home, "Guessable Book", nil, "Ann Author")
    G_reader_settings:saveSetting("home_dir", home)

    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })
    -- a home folder kept from an earlier run may remember these files as linked
    for _, file in ipairs(files) do
      settings:updateBookSetting(file, { _delete = { "book_id", "edition_id", "edition_format", "pages", "title" } }, true)
    end

    -- a real library file, for the details
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local BookStore = require("hardcover/lib/book_store")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcoversync_link_all.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(path .. suffix) end
    local book_store = BookStore:new { db = SqliteStore:new { path = path } }

    -- Hardcover: knows the first two books, not the third; answers a batch at a time
    local Api = require("hardcover/lib/hardcover_api")
    local lookups, detail_requests = {}, {}
    Api.findBooksByIdentifiers = function(_, list)
      lookups[#lookups + 1] = #list
      local out = {}
      for i, parsed in ipairs(list) do
        local n = tonumber(tostring(parsed.isbn_13):sub(-2))
        out[i] = n <= 2 and { book_id = 500 + n, edition_id = 600 + n, title = "Hardcover Book " .. n } or false
      end
      return out
    end
    -- guesses: the exact titles are asked for at once, and what that does not settle is searched for
    local title_requests, searches = {}, {}
    local guessable = { book_id = 900, title = "Guessable Book", contributions = { { author = { name = "Ann Author" } } } }
    Api.findBooksByTitles = function(_, titles)
      title_requests[#title_requests + 1] = #titles
      local out = {}
      for _, title in ipairs(titles) do
        if title == "Guessable Book" then out[title] = { guessable } end
      end
      return out
    end
    Api.search = function(_, title)
      searches[#searches + 1] = title
      return {}
    end
    Api.getBookDetails = function(_, items)
      detail_requests[#detail_requests + 1] = #items
      local out = {}
      for _, item in ipairs(items) do
        out[#out + 1] = { book_id = item.book_id, edition_id = item.edition_id, detail = { book = {
          book_id = item.book_id, title = "Hardcover Book", description = "About it", editions_count = 12,
          release_year = 2001 } } }
      end
      return out
    end

    -- no waiting between batches
    local BulkLink = require("hardcover/lib/bulk_link")
    local DetailsSync = require("hardcover/lib/details_sync")
    BulkLink.RATE, BulkLink.GUESS_RATE, DetailsSync.RATE = 0, 0, 0

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings }
    local shelf_downloads = 0
    manager.downloadShelf = function() shelf_downloads = shelf_downloads + 1 end
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      dialog_manager = manager,
      book_store = book_store,
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
    })
    manager.settings_items = function() return menu:getHomeSettingsItems() end

    -- a button by its exact words (the message above it may start with the same word)
    local function tapButton(label)
      for _, node in ipairs(emu:screenNodes()) do
        if node.text == label then
          emu:tapExpecting(node.x + 5, node.y + 5)
          return
        end
      end
      error("no button '" .. label .. "' on screen:\n" .. emu:screenText())
    end

    -- the row, on the real settings screen (scrolled to if it is below the fold)
    local function tapRow(label)
      local screen = manager:showSettings()
      emu:pump()
      emu:screenNodes()
      local Device = require("device")
      local W, H = Device.screen:getWidth(), Device.screen:getHeight()
      local dimen
      for _ = 1, 10 do
        for _, t in ipairs(screen.taps or {}) do
          local d = t.tap and t.tap.dimen
          if t.shows:find(label, 1, true) and d and d.y >= 0 and d.y + d.h <= H - 80 then dimen = d end
        end
        if dimen then break end
        emu:tap(W - 10, H - 20) -- the scroll control's down triangle
        emu:pump()
        emu:screenNodes()
      end
      assert(dimen, "no row '" .. label .. "' on the settings screen")
      emu:tapExpecting(dimen.x + 5, dimen.y + 5)
      emu:pump()
      emu:screenNodes()
    end

    -- ---------------------------------------------------------------- link them all
    tapRow("Link all books on this device")
    emu:expectText("Link 4 books to Hardcover?")
    emu:shot("link_all_confirm")

    tapButton("Link")
    -- the work goes in steps; let it run to its end (it stops at the summary)
    for _ = 1, 200 do
      emu:pump()
      if emu:screenText():find("Linking finished", 1, true) then break end
    end
    emu:screenNodes()
    emu:shot("link_all_done")
    emu:expectText("Linked: 2")
    emu:expectText("No match on Hardcover: 1")
    assert(#lookups == 1 and lookups[1] == 3, "the three books were not looked up in one batch: " .. #lookups)
    assert(settings:readBookSetting(files[1], "book_id") == 501, "book 1 was not linked")
    assert(settings:readBookSetting(files[3], "book_id") == nil, "book 3 was linked though Hardcover has none")

    -- the details of the two linked books, and their shelves
    assert(#detail_requests == 1 and detail_requests[1] == 2, "details: " .. table.concat(detail_requests, ","))
    assert(book_store:hasDetail(501, 601) and book_store:hasDetail(502, 602), "the details were not saved")
    assert(shelf_downloads > 0, "the shelves were not downloaded")

    -- the two left over (Hardcover does not know one, the other has no identifier) can be guessed
    emu:expectText("Guess the other 2")
    tapButton("Guess")
    for _ = 1, 200 do
      emu:pump()
      if emu:screenText():find("Guessing finished", 1, true) then break end
    end
    emu:screenNodes()
    emu:shot("link_all_guessed")
    emu:expectText("Linked by guess: 1")
    assert(settings:readBookSetting(files[4], "book_id") == 900, "the guess was not linked")
    assert(#title_requests == 1 and title_requests[1] == 2, "titles asked for at once: " .. table.concat(title_requests, ","))
    assert(#searches == 1, "searches for what the titles did not settle: " .. #searches)
    assert(settings:readBookSetting(files[4], "guessed_book_id") == 900, "the guess was not marked")
    assert(settings:readBookSetting(files[3], "book_id") == nil, "a book with no match was linked")
    assert(#detail_requests == 2 and detail_requests[2] == 1, "the guess's details: " .. table.concat(detail_requests, ","))

    -- ...and checked: "Right" keeps the link and drops the mark
    tapButton("Check them")
    emu:screenNodes()
    emu:expectText("Guessed to be \"Guessable Book\"")
    emu:shot("link_all_review")
    tapButton("Right, keep the link")
    emu:pump()
    assert(settings:readBookSetting(files[4], "book_id") == 900 and settings:readBookSetting(files[4], "guessed_book_id") == nil,
      "keeping the guess did not drop the mark")
    emu:closeAll()

    -- ---------------------------------------------------------------- stop it by tapping the message
    for _, file in ipairs(files) do
      settings:updateBookSetting(file, { _delete = { "book_id", "edition_id", "edition_format", "pages", "title" } }, true)
    end
    lookups = {}
    BulkLink.RATE = 2
    tapRow("Link all books on this device")
    tapButton("Link")
    emu:screenNodes()
    emu:expectText("(tap to stop)")
    emu:shot("link_all_progress")
    -- the message only listens a moment after it first shows (the tap that started the scan lands on it)
    os.execute("sleep 0.8")
    emu:pump()
    emu:tap(600, 800)
    os.execute("sleep 2.2")
    for _ = 1, 20 do emu:pump() end
    emu:screenNodes()
    emu:shot("link_all_stopped")
    emu:expectText("Linking stopped.")
    emu:closeAll()
    BulkLink.RATE = 0

    -- ---------------------------------------------------------------- books linked earlier
    book_store.db:clear()
    detail_requests = {}
    for _, file in ipairs(files) do
      settings:updateBookSetting(file, { _delete = { "book_id", "edition_id", "edition_format", "pages", "title" } }, true)
    end
    tapRow("Save details of linked books")
    emu:screenNodes()
    -- none of the three is linked now, so there is nothing to save
    emu:expectText("The details of every linked book are saved already.")
    emu:closeAll()

    settings:updateBookSetting(files[1], { book_id = 501, edition_id = 601 }, true)
    settings:updateBookSetting(files[2], { book_id = 502 }, true)
    tapRow("Save details of linked books")
    emu:expectText("Save the details of 2 linked books?")
    tapButton("Save")
    for _ = 1, 200 do
      emu:pump()
      if emu:screenText():find("Details saved", 1, true) then break end
    end
    emu:screenNodes()
    emu:shot("save_details_done")
    emu:expectText("Saved: 2")
    assert(#detail_requests == 1 and detail_requests[1] == 2, "details: " .. table.concat(detail_requests, ","))
    assert(book_store:hasDetail(501, 601) and book_store:hasDetail(502), "the details were not saved")
    emu:closeAll()
  end,
}
