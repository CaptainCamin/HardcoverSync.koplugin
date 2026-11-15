--[[--
Reading history and the read form, as real KOReader widgets: the list with one row per read,
a state in words, the dotted "works offline" note; then one read's form, its date picker, the
change it will write, and Save.

Screens: read_history, read_history_edit, read_history_edit_changed, read_history_no_copy.
]]--

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local ReadHistoryDialog = require("hardcover/lib/ui/read_history_dialog")
local ReadEditDialog = require("hardcover/lib/ui/read_edit_dialog")

local function top()
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    if w and not (w.toast or w.snackbar or w.name == "VirtualKeyboard") then return w end
  end
end

local function find_button(root, label, seen)
  seen = seen or {}
  if type(root) ~= "table" or seen[root] then return end
  seen[root] = true
  if root.text == label and root.callback and root.dimen and root.dimen.w and root.dimen.w > 0 then
    return root
  end
  for _, child in pairs(root) do
    local found = find_button(child, label, seen)
    if found then return found end
  end
end

local function tap_button(emu, label)
  emu:screenNodes()
  local b = find_button(top(), label)
  assert(b, "no button '" .. label .. "' on top (" .. tostring(top() and top().name) .. "):\n"
    .. emu:screenText())
  emu:tapExpecting(b.dimen.x + math.floor(b.dimen.w / 2), b.dimen.y + math.floor(b.dimen.h / 2))
  emu:pump()
end

local function tap_widget(emu, widget, label)
  emu:screenNodes()
  assert(widget and widget.dimen and widget.dimen.w > 0, "no painted widget for " .. label)
  emu:tapExpecting(widget.dimen.x + math.floor(widget.dimen.w / 2),
    widget.dimen.y + math.floor(widget.dimen.h / 2))
  emu:pump()
end

return {
  name = "read_history",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local book = { title = "The Dispossessed", pages = 341, edition_format = "Paperback" }
    local reads = {
      { id = 1, started_at = "2020-01-01", finished_at = "2020-01-10", finished_at_precision = 1,
        progress_pages = 341, edition_id = 11,
        edition = { id = 11, pages = 341, edition_format = "Paperback", reading_format_id = 1 } },
      { id = 2, started_at = "2024-03-14", finished_at = "2024-03-20", finished_at_precision = 1,
        progress_pages = 341, edition_id = 11,
        edition = { id = 11, pages = 341, edition_format = "Paperback", reading_format_id = 1 } },
      { id = 3, started_at = "2026-11-03", finished_at = nil, progress_pages = 120, edition_id = 11,
        edition = { id = 11, pages = 341, edition_format = "Paperback", reading_format_id = 1 } },
    }

    local saved
    local history
    history = ReadHistoryDialog:new {
      book = book,
      reads = reads,
      today = "2026-11-15",
      checked_at = os.time(),
      states = { [2] = { text = "Finish date waiting to send", kind = "waiting" } },
      on_add = function() end,
      on_open_read = function(read)
        local form = ReadEditDialog:new {
          book = book,
          read = read,
          today = "2026-11-15",
          on_save = function(change, clear) saved = { change = change, clear = clear } end,
        }
        UIManager:show(form, "full")
        emu:pump()
      end,
    }
    UIManager:show(history, "full")
    emu:pump()

    for _, text in ipairs({ "Reading history", "The Dispossessed", "3 reads",
      "Started 3 Nov 2026", "14 – 20 Mar 2024", "1 – 10 Jan 2020",
      "Finish date waiting to send", "Add a past read", "Works offline.",
      "Changes you make here are saved on this device and sent in order when you are connected.",
      "Tap a read to change its dates or edition." }) do
      emu:expectText(text)
    end
    -- the count line says today (the check just ran), whichever hour it is
    emu:expectText("Hardcover checked today")
    emu:expectNoButtonOverlap()
    emu:shot("read_history")

    -- one read's form: the read in progress has no finish row
    tap_widget(emu, history.items[1].row, "the read in progress")
    local form = top()
    assert(form and form.name == "hardcover_read_edit", "no edit form: " .. tostring(form and form.name))
    for _, text in ipairs({ "Edit read", "Started", "3 Nov 2026", "Status", "Still reading",
      "Edition", "Paperback · 341 pages", "No changes yet", "Save", "Cancel" }) do
      emu:expectText(text)
    end
    for _, row in ipairs(form:rows()) do
      assert(row.key ~= "finished_at" and row.key ~= "finished_at_precision",
        "a read in progress offered a finish row")
    end
    emu:expectNoButtonOverlap()
    emu:shot("read_history_edit")

    -- change the start date through the real date picker
    tap_widget(emu, form.row_taps.started_at, "Started")
    emu:expectText("Start date")
    tap_button(emu, "4")
    tap_button(emu, "Set date")
    emu:expectText("Started 3 Nov → 4 Nov 2026")
    emu:shot("read_history_edit_changed")

    tap_button(emu, "Save")
    assert(saved and saved.change and saved.change.started_at == "2026-11-04",
      "Save did not hand over the new start date")
    assert(saved.change.finished_at == nil and saved.change.progress_pages == nil,
      "Save sent fields the reader did not change")
    UIManager:close(form)
    emu:pump()

    -- offline with nothing saved: one connection, no list and no note
    UIManager:close(history)
    emu:pump()
    local empty = ReadHistoryDialog:new { book = book, reads = nil, today = "2026-11-15" }
    UIManager:show(empty, "full")
    emu:pump()
    emu:expectText("Connect once to load this book's reading history.")
    for _, node in ipairs(emu:screenNodes()) do
      assert(node.text ~= "Add a past read", "an unsaved history offered an addition")
    end
    emu:shot("read_history_no_copy")
  end,
}
