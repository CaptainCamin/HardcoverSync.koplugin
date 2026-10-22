--[[--
The Library's Activity tab, driven with real taps: the rows (a status change, a quote, a review
that hides its spoilers, notes), a row opening the whole text, Load more adding the next page without
repeating the entry both pages share, and offline: the message before anything was saved, then the
copy kept in the real SQLite file, with a note written offline listed first as waiting to send.

Then, still offline, your entries changed from there: the quote edited (it shows its new text,
waiting to send), the note not sent yet discarded, and a note Hardcover has deleted, each after
tapping the full text's Edit or Delete and the dialog it opens.

Screens: activity, activity_full, activity_more, activity_offline, activity_entry, activity_edit,
activity_changed.
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
  name = "activity",

  run = function(emu)
    local Feed = require("hardcover/lib/feed")
    local calls = {}

    -- what Hardcover holds: 24 notes, a quote, a status change and a review with spoilers
    local raw = { activities = {}, journals = {}, reviews = {} }
    for day = 1, 24 do
      raw.journals[#raw.journals + 1] = { id = 100 + day, event = "note", entry = string.format("Note number %d", day),
        user_id = fixtures.USER_ID, created_at = string.format("2026-10-%02dT10:00:00+00:00", day),
        user = { name = "Dana" }, book = { id = 5, title = "Dune" } }
    end
    raw.journals[#raw.journals + 1] = { id = 200, event = "quote", entry = "Fear is the mind-killer.", user_id = fixtures.USER_ID,
      created_at = "2026-10-25T10:00:00+00:00", metadata = { position = { type = "pages", value = 12 } },
      user = { name = "Dana" }, book = { id = 5, title = "Dune" } }
    raw.activities[1] = { id = 300, event = "UserBookActivity", user_id = fixtures.USER_ID, created_at = "2026-10-24T12:00:00+00:00",
      user = { name = "Dana" }, book = { id = 6, title = "Kindred" }, data = { userBook = { statusId = 3, rating = 4 } } }
    raw.reviews[1] = { id = 400, user_id = fixtures.USER_ID, rating = 5, review_raw = "The ending is wonderful.",
      review_has_spoilers = true, reviewed_at = "2026-10-23", user = { name = "Dana" }, book = { id = 6, title = "Kindred" } }

    -- Hardcover's own paging by time: newest first, nothing newer than `before`, `limit` of each source
    local function answer(opts)
      local data = {}
      for key, rows in pairs(raw) do
        local kept = {}
        local stamp = key == "reviews" and "reviewed_at" or "created_at"
        for _, row in ipairs(rows) do
          local at = row[stamp]
          local bound = opts.before and (key == "reviews" and opts.before:sub(1, 10) or opts.before)
          if not bound or at <= bound then kept[#kept + 1] = row end
        end
        table.sort(kept, function(a, b) return a[stamp] > b[stamp] end)
        while #kept > opts.limit do table.remove(kept) end
        data[key] = kept
      end
      return Feed.parse(data, opts.limit)
    end

    local settings = fixtures.real_settings(emu)
    fixtures.install({
      settings = settings,
      overrides = {
        getFollowedIds = function() calls[#calls + 1] = { name = "getFollowedIds" } return { 11, 12 } end,
        getFeed = function(_, opts)
          calls[#calls + 1] = { name = "getFeed", before = opts.before, readers = #(opts.user_ids or {}), mine = opts.mine, me_id = opts.me_id }
          return answer(opts)
        end,
      },
    })

    local function feed_calls()
      local n = 0
      for _, c in ipairs(calls) do if c.name == "getFeed" then n = n + 1 end end
      return n
    end

    local NetworkManager = require("ui/network/manager")
    local function offline(fn)
      local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
      NetworkManager.isConnected = function() return false end
      NetworkManager.getConnectionState = function() return false end
      local ok, err = pcall(fn)
      NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
      if not ok then error(err, 0) end
    end

    -- the activity kept in a real SQLite file, and notes written offline in a real settings file
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local ActivityStore = require("hardcover/lib/activity_store")
    local JournalQueue = require("hardcover/lib/journal_queue")
    local LuaSettings = require("luasettings")
    local dir = emu.DataStorage:getSettingsDir()
    local path = dir .. "/hardcoversync_activity_emu.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(path .. suffix) end
    local queue_path = dir .. "/hardcoversync_activity_queue_emu.lua"
    os.remove(queue_path)
    local activity_store = ActivityStore:new { db = SqliteStore:new { path = path } }
    local journal_queue = JournalQueue:new { settings = LuaSettings:open(queue_path) }

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, activity_store = activity_store,
      journal_queue = journal_queue }

    -- offline before anything was saved: a clear message and no request
    offline(function()
      manager:showActivity()
      emu:pump()
    end)
    emu:expectText("internet connection the first time")
    assert(feed_calls() == 0, "asked for the feed while offline")
    emu:closeAll()

    -- the first page: the newest 20 of the 27 entries
    manager:showActivity()
    emu:pump()
    local dialog = UIManager:getTopmostVisibleWidget()
    assert(dialog and dialog.name == "hardcover_activity", "the tab did not open: " .. tostring(dialog and dialog.name))
    assert(#dialog.entries == 20, "the first page holds " .. #dialog.entries .. " entries, not 20")
    assert(dialog.has_more, "the first page should say there is more")
    assert(#calls == 1 and calls[1].name == "getFeed" and calls[1].mine == true
      and calls[1].me_id == fixtures.USER_ID and calls[1].readers == 0,
      "the first page should request only your journal without fetching followed readers")
    emu:expectText("Fear is the mind-killer")
    emu:expectText("Dana \194\183 Quote \194\183 Dune")
    emu:expectText("Kindred")
    emu:shot("activity")

    -- the quote opens in full
    tap_text(emu, "Fear is the mind-killer")
    local full = UIManager:getTopmostVisibleWidget()
    assert(full and full.name == "hardcover_text_screen", "the quote did not open: " .. tostring(full and full.name))
    emu:expectText("Dana \194\183 Quote \194\183 Dune \194\183 p. 12")
    emu:shot("activity_full")
    full:onClose()
    emu:pump()

    -- the review does not give away the story in the list
    emu:expectText(Feed.SPOILER_LABEL)

    -- the next page: asks for rows no newer than the oldest shown, and the entry both pages share
    -- appears once
    local oldest = dialog.entries[#dialog.entries].at
    dialog:loadMore()
    emu:pump()
    assert(feed_calls() == 2, "Load more should have made the second feed request")
    assert(calls[#calls].before == oldest and calls[#calls].mine == true
      and calls[#calls].me_id == fixtures.USER_ID and calls[#calls].readers == 0,
      "the next page must keep your journal filter and cursor")
    assert(#dialog.entries == 27, "after Load more there are " .. #dialog.entries .. " entries, not 27")
    assert(not dialog.has_more, "the last page should end the list")
    local seen = {}
    for _, e in ipairs(dialog.entries) do
      assert(not seen[e.key], "an entry is listed twice: " .. e.key)
      seen[e.key] = true
    end
    emu:shot("activity_more")
    emu:closeAll()

    -- offline again, with a note written meanwhile: the kept copy opens from the file, under the
    -- note, which says it is waiting to send
    local kept = activity_store:get(fixtures.USER_ID)
    assert(kept and #kept.entries == 27 and kept.more == false, "the 27 entries were not kept")
    journal_queue:queue({ user_id = fixtures.USER_ID, book_id = 5, event = "note",
      text = "Written on the train", title = "Dune" })
    local before = feed_calls()
    offline(function()
      manager:showActivity()
      emu:pump()
    end)
    emu:expectText("Offline: showing your activity as of")
    UIManager:close(UIManager:getTopmostVisibleWidget())
    emu:pump()
    assert(feed_calls() == before, "asked for the feed while offline")
    local tab = UIManager:getTopmostVisibleWidget()
    assert(tab and tab.name == "hardcover_activity", "the tab did not open offline: " .. tostring(tab and tab.name))
    assert(#tab.entries == 28 and tab.entries[1].waiting and tab.entries[2].key == kept.entries[1].key,
      "the waiting note should come first, then the kept copy")
    emu:expectText("Written on the train")
    emu:expectText(Feed.WAITING .. " \194\183 You")
    emu:expectText("Fear is the mind-killer")
    emu:shot("activity_offline")

    offline(function()
      -- the quote, edited: Edit and Delete are along the bottom of its full text
      tap_text(emu, "Fear is the mind-killer")
      assert(top().name == "hardcover_text_screen", "the quote did not open")
      emu:expectText("Edit")
      emu:expectText("Delete")
      emu:shot("activity_entry")
      tap_button(emu, "Edit")
      local input = top()
      assert(input and input.getInputText and input:getInputText() == "Fear is the mind-killer.",
        "the field should hold the quote: " .. tostring(input and input.getInputText and input:getInputText()))
      input:setInputText("Fear is the little-death.")
      emu:shot("activity_edit")
      tap_button(emu, "Save")
      emu:expectText("Your change is kept")
      local change = journal_queue:changeFor(200)
      assert(change and change.action == "update" and change.text == "Fear is the little-death.", "the edit was not kept")
      dismiss_notes(emu)
      assert(top() == tab, "the tab should be back on top: " .. tostring(top() and top().name))
      emu:expectText("Fear is the little-death")

      -- the note not sent yet, discarded
      tap_text(emu, "Written on the train")
      tap_button(emu, "Delete")
      emu:expectText("Discard this note?")
      tap_button(emu, "Discard")
      assert(#journal_queue:list() == 1, "the note not sent should be gone, the edit kept")

      -- a note Hardcover has, deleted
      dismiss_notes(emu)
      tap_text(emu, "Note number 24")
      tap_button(emu, "Delete")
      emu:expectText("Delete this note?")
      tap_button(emu, "Delete")
      local delete = journal_queue:changeFor(124)
      assert(delete and delete.action == "delete", "the delete was not kept")
      dismiss_notes(emu)
    end)
    assert(#tab.entries == 26, "the tab shows " .. #tab.entries .. " entries, not 26")
    for _, node in ipairs(emu:screenNodes()) do
      assert(not node.text:find("Note number 24", 1, true), "the deleted note is still on screen")
      assert(not node.text:find("Written on the train", 1, true), "the discarded note is still on screen")
    end
    assert(feed_calls() == before, "asked for the feed while offline")
    assert(activity_store:get(fixtures.USER_ID).entries[1].text == "Fear is the mind-killer.",
      "the saved copy keeps Hardcover's text until the change is sent")
    emu:shot("activity_changed")
    emu:closeAll()
    os.remove(queue_path)
  end,
}
