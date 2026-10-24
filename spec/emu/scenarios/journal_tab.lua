--[[--
The Library's Journal tab, driven with real taps: the rows (progress, a finish, a quote, a review
that hides its spoilers, notes) with covers and authors, a page at a time; a row opening the whole
text; Load more asking from where Hardcover's rows ended, without repeating an entry; and offline:
the message before anything was saved, then the copy kept in the real SQLite file, with a note
written offline listed first as waiting to send.

Then, still offline, your entries changed from there: the quote edited (it shows its new text,
waiting to send), the note not sent yet discarded, and a note Hardcover has deleted, each after
tapping the full text's Edit or Delete and the dialog it opens.

Screens: journal_tab, journal_tab_full, journal_tab_page2, journal_tab_more, journal_tab_offline,
journal_tab_entry, journal_tab_edit, journal_tab_changed.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function tap_text(emu, needle)
  local node = emu:expectText(needle)
  emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
  emu:pump()
end

-- notes along the bottom ("Note saved") are windows of their own and spend the next tap: put them
-- away, as a reader's tap would
local function dismiss_notes(emu)
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    if w and (w.toast or w.snackbar) then UIManager:close(w) end
  end
  emu:pump()
end

-- the topmost window that is not a note or the on-screen keyboard
local function top()
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    if w and not (w.toast or w.snackbar or w.name == "VirtualKeyboard") then return w end
  end
end

-- a widget under `root` with this text that can be tapped (a button)
local function find_button(root, label, seen)
  seen = seen or {}
  if type(root) ~= "table" or seen[root] then return end
  seen[root] = true
  if root.text == label and root.callback and root.dimen and root.dimen.w and root.dimen.w > 0 then return root end
  for _, child in pairs(root) do
    local found = find_button(child, label, seen)
    if found then return found end
  end
end

local function tap_button(emu, label)
  dismiss_notes(emu)
  -- the on-screen keyboard can cover a dialog's buttons: put it away first, as a reader would
  local dialog = top()
  if dialog and dialog.onCloseKeyboard and dialog.keyboard_visible then
    dialog:onCloseKeyboard()
    emu:pump()
  end
  emu:screenNodes()
  local b = find_button(top(), label)
  assert(b, "no button '" .. label .. "' on top (" .. tostring(top() and top().name) .. "):\n" .. emu:screenText())
  emu:tapExpecting(b.dimen.x + math.floor(b.dimen.w / 2), b.dimen.y + math.floor(b.dimen.h / 2))
  emu:pump()
end

return {
  name = "journal_tab",

  run = function(emu)
    local Journal = require("hardcover/lib/journal")
    local calls = {}

    local DUNE = { id = 5, title = "Dune", cached_image = { url = fixtures.cover_url(101), width = 300, height = 450 },
      contributions = { { author = { name = "Frank Herbert" }, contribution = "Author" } }, reviews = {} }
    local KINDRED = { id = 6, title = "Kindred", cached_image = { url = fixtures.cover_url(102), width = 300, height = 450 },
      contributions = { { author = { name = "Octavia E. Butler" }, contribution = "Author" } },
      reviews = { { id = 900, review_raw = "The ending is wonderful.", review_has_spoilers = true } } }
    fixtures.seed_cover(fixtures.cover_url(101), 1)
    fixtures.seed_cover(fixtures.cover_url(102), 2)

    -- what Hardcover holds, newest first: progress, a quote, a finish, a review with spoilers, 24 notes,
    -- and a referral (a row the tab does not show, but counts towards where the next page starts)
    local rows = {}
    local function add(row) row.user_id = fixtures.USER_ID; rows[#rows + 1] = row end
    add { id = 300, event = "progress_updated", action_at = "2026-10-26T12:00:00+00:00", book = DUNE,
      metadata = { progress = 56, progress_was = 13 } }
    add { id = 200, event = "quote", entry = "Fear is the mind-killer.", action_at = "2026-10-25T12:00:00+00:00",
      metadata = { position = { type = "pages", value = 12 } }, book = DUNE }
    add { id = 301, event = "user_book_read_finished", action_at = "2026-10-24T18:00:00+00:00", book = KINDRED, metadata = {} }
    add { id = 400, event = "reviewed", action_at = "2026-10-24T17:00:00+00:00", book = KINDRED, metadata = { user_book_id = 900 } }
    for day = 24, 1, -1 do
      add { id = 100 + day, event = "note", entry = string.format("Note number %d", day),
        action_at = string.format("2026-10-%02dT10:00:00+00:00", day), metadata = {}, book = DUNE }
      if day == 20 then
        add { id = 500, event = "referral_to", action_at = "2026-10-20T09:00:00+00:00", book = DUNE,
          metadata = { referred_username = "someone" } }
      end
    end
    assert(#rows == 29)

    -- Hardcover's own paging: newest first, from `offset`, `limit` rows
    local function answer(opts)
      local page = {}
      for i = opts.offset + 1, math.min(#rows, opts.offset + opts.limit) do page[#page + 1] = rows[i] end
      return Journal.parse({ reading_journals = page }, opts.limit)
    end

    local settings = fixtures.real_settings(emu)
    fixtures.install({
      settings = settings,
      overrides = {
        getJournal = function(_, opts)
          calls[#calls + 1] = { name = "getJournal", offset = opts.offset, me_id = opts.me_id }
          return answer(opts)
        end,
      },
    })

    local NetworkManager = require("ui/network/manager")
    local function offline(fn)
      local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
      NetworkManager.isConnected = function() return false end
      NetworkManager.getConnectionState = function() return false end
      local ok, err = pcall(fn)
      NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
      if not ok then error(err, 0) end
    end

    -- the journal kept in a real SQLite file, and notes written offline in a real settings file
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local JournalStore = require("hardcover/lib/journal_store")
    local JournalQueue = require("hardcover/lib/journal_queue")
    local LuaSettings = require("luasettings")
    local dir = emu.DataStorage:getSettingsDir()
    local path = dir .. "/hardcoversync_journal_emu.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(path .. suffix) end
    local queue_path = dir .. "/hardcoversync_journal_queue_emu.lua"
    os.remove(queue_path)
    local journal_store = JournalStore:new { db = SqliteStore:new { path = path } }
    local journal_queue = JournalQueue:new { settings = LuaSettings:open(queue_path) }

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, journal_store = journal_store,
      journal_queue = journal_queue }

    -- the page an entry is on, shown, so its row can be tapped
    local function show_entry(tab, needle)
      for i, e in ipairs(tab.entries) do
        if Journal.row(e).what:find(needle, 1, true) then
          tab:setPage(math.floor((i - 1) / tab.per_page) + 1)
          emu:pump()
          return e
        end
      end
      error("no entry says " .. needle)
    end

    -- offline before anything was saved: a clear message and no request
    offline(function()
      manager:showJournal()
      emu:pump()
    end)
    emu:expectText("internet connection the first time")
    assert(#calls == 0, "asked for the journal while offline")
    emu:closeAll()

    -- the first page: Hardcover's newest 20 rows, 19 of them shown
    manager:showJournal()
    emu:pump()
    local tab = UIManager:getTopmostVisibleWidget()
    assert(tab and tab.name == "hardcover_journal", "the tab did not open: " .. tostring(tab and tab.name))
    assert(#tab.entries == 19, "the first page holds " .. #tab.entries .. " entries, not 19")
    assert(tab.has_more, "the first page should say there is more")
    assert(#calls == 1 and calls[1].offset == 0 and calls[1].me_id == fixtures.USER_ID, "the first page is yours, from the top")
    assert(tab.pages > 1 and tab.page == 1, "the journal should go by page")
    emu:expectText("Updated progress from 13% to 56%")
    emu:expectText("Fear is the mind-killer")
    emu:expectText("Finished reading")
    emu:expectText(Journal.SPOILER_LABEL)
    emu:expectText("Frank Herbert")
    emu:expectText("Octavia E. Butler")
    emu:expectText("Showing 1 to " .. tab.per_page .. " of 19+")
    emu:shot("journal_tab")

    -- the quote opens in full
    tap_text(emu, "Fear is the mind-killer")
    local full = UIManager:getTopmostVisibleWidget()
    assert(full and full.name == "hardcover_text_screen", "the quote did not open: " .. tostring(full and full.name))
    emu:expectText("Quote \194\183 Dune \194\183 p. 12")
    emu:shot("journal_tab_full")
    full:onClose()
    emu:pump()

    -- the next page, by a swipe up
    tab:onSwipeJournal(nil, { direction = "north" })
    emu:pump()
    assert(tab.page == 2, "the swipe did not turn the page")
    emu:expectText("Showing " .. (tab.per_page + 1) .. " to ")
    emu:shot("journal_tab_page2")

    -- Load more: asks from the 21st row, adds the rest, and opens on the first new row's page
    tab:setPage(tab.pages)
    emu:pump()
    emu:expectText("Load more")
    tab:loadMore()
    emu:pump()
    assert(#calls == 2 and calls[2].offset == 20 and calls[2].me_id == fixtures.USER_ID,
      "the next page should start after the 20 rows sent: " .. tostring(calls[2] and calls[2].offset))
    assert(#tab.entries == 28, "after Load more there are " .. #tab.entries .. " entries, not 28")
    assert(not tab.has_more, "the last page should end the list")
    assert(tab.page == math.floor(19 / tab.per_page) + 1, "Load more should show the first new row")
    local seen = {}
    for _, e in ipairs(tab.entries) do
      assert(not seen[e.key], "an entry is listed twice: " .. e.key)
      seen[e.key] = true
    end
    emu:shot("journal_tab_more")
    emu:closeAll()

    -- offline again, with a note written meanwhile: the kept copy opens from the file, under the
    -- note, which says it is waiting to send
    local kept = journal_store:get(fixtures.USER_ID)
    assert(kept and #kept.entries == 28 and kept.more == false, "the 28 entries were not kept")
    journal_queue:queue({ user_id = fixtures.USER_ID, book_id = 5, event = "note",
      text = "Written on the train", title = "Dune" })
    local before = #calls
    offline(function()
      manager:showJournal()
      emu:pump()
    end)
    emu:expectText("Offline: showing your journal as of")
    UIManager:close(UIManager:getTopmostVisibleWidget())
    emu:pump()
    assert(#calls == before, "asked for the journal while offline")
    tab = UIManager:getTopmostVisibleWidget()
    assert(tab and tab.name == "hardcover_journal", "the tab did not open offline: " .. tostring(tab and tab.name))
    assert(#tab.entries == 29 and tab.entries[1].waiting and tab.entries[2].key == kept.entries[1].key,
      "the waiting note should come first, then the kept copy")
    emu:expectText("Written on the train")
    emu:expectText("Frank Herbert \194\183 " .. Journal.WAITING)
    emu:shot("journal_tab_offline")

    offline(function()
      -- the quote, edited: Edit and Delete are along the bottom of its full text
      show_entry(tab, "Fear is the mind-killer")
      tap_text(emu, "Fear is the mind-killer")
      assert(top().name == "hardcover_text_screen", "the quote did not open")
      emu:expectText("Edit")
      emu:expectText("Delete")
      emu:shot("journal_tab_entry")
      tap_button(emu, "Edit")
      local input = top()
      assert(input and input.getInputText and input:getInputText() == "Fear is the mind-killer.",
        "the field should hold the quote: " .. tostring(input and input.getInputText and input:getInputText()))
      input:setInputText("Fear is the little-death.")
      emu:shot("journal_tab_edit")
      tap_button(emu, "Save")
      emu:expectText("Your change is kept")
      local change = journal_queue:changeFor(200)
      assert(change and change.action == "update" and change.text == "Fear is the little-death.", "the edit was not kept")
      dismiss_notes(emu)
      assert(top() == tab, "the tab should be back on top: " .. tostring(top() and top().name))
      emu:expectText("Fear is the little-death")

      -- the note not sent yet, discarded
      show_entry(tab, "Written on the train")
      tap_text(emu, "Written on the train")
      tap_button(emu, "Delete")
      emu:expectText("Discard this note?")
      tap_button(emu, "Discard")
      assert(#journal_queue:list() == 1, "the note not sent should be gone, the edit kept")

      -- a note Hardcover has, deleted
      dismiss_notes(emu)
      show_entry(tab, "Note number 24")
      tap_text(emu, "Note number 24")
      tap_button(emu, "Delete")
      emu:expectText("Delete this note?")
      tap_button(emu, "Delete")
      local delete = journal_queue:changeFor(124)
      assert(delete and delete.action == "delete", "the delete was not kept")
      dismiss_notes(emu)
    end)
    assert(#tab.entries == 27, "the tab shows " .. #tab.entries .. " entries, not 27")
    for _, e in ipairs(tab.entries) do
      assert(e.text ~= "Note number 24", "the deleted note is still listed")
      assert(e.text ~= "Written on the train", "the discarded note is still listed")
    end
    for _, node in ipairs(emu:screenNodes()) do
      assert(not node.text:find("Note number 24", 1, true), "the deleted note is still on screen")
    end
    assert(#calls == before, "asked for the journal while offline")
    assert(journal_store:get(fixtures.USER_ID).entries[2].text == "Fear is the mind-killer.",
      "the saved copy keeps Hardcover's text until the change is sent")
    emu:shot("journal_tab_changed")
    emu:closeAll()
    os.remove(queue_path)
  end,
}
