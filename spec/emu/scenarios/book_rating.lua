--[[--
Rating a book from its details screen, with no connection: tapping "your rating"
opens the stepper, saving shows the new rating at once and sends nothing, and the
rating goes to Hardcover when the queue is flushed.

Screens: book_rating_spinner, book_rating_offline.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top()
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    -- not a toast or a snackbar, and a real screen: the emulator leaves unnamed windows above the details
    if w and not (w.toast or w.snackbar) and (w.name or w.value_widget) then return w end
  end
end

-- the names of the open windows, bottom to top: when a tap target is missing, what is on top of what
local function stack_names()
  local names = {}
  for _i, entry in ipairs(UIManager._window_stack) do
    local w = entry.widget
    names[#names + 1] = tostring(w and (w.name or w.id) or "?") .. (w and (w.toast or w.snackbar) and "*" or "")
  end
  return table.concat(names, ", ")
end

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

local function writes(name)
  local out = {}
  for _, c in ipairs(fixtures.calls) do if c.name == name then out[#out + 1] = c.args end end
  return out
end

return {
  name = "book_rating",

  run = function(emu)
    local Api = require("hardcover/lib/hardcover_api")
    local NetworkManager = require("ui/network/manager")
    local RatingQueue = require("hardcover/lib/rating_queue")
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings, overrides = { getShelf = function() return {}, nil, false end } })
    Api.auth = fixtures.fake_auth(true)

    local store = {}
    local queue = RatingQueue:new { settings = { readSetting = function(_, k) return store[k] end,
      saveSetting = function(_, k, v) store[k] = v end, flush = function() end } }
    local flushed = 0
    local manager = require("hardcover/lib/ui/dialog_manager"):new {
      settings = settings,
      rating_queue = queue,
      flush_goals = function() flushed = flushed + 1 end,
    }

    -- offline in both of the plugin's checks
    local function go(online)
      NetworkManager.isConnected = function() return online end
      NetworkManager.getConnectionState = function() return online end
    end
    go(true)

    -- the dialog comes back from the call: it is the one window to hold on to
    local dialog = manager:showBookDetail(103, 10301)
    emu:pump()
    emu:expectText("The Left Hand of Darkness")
    go(false) -- the connection drops with the book already open

    -- "Your rating" is a row of five stars: the whole row is the tap
    emu:screenNodes()
    local d = dialog.rating_tap and dialog.rating_tap.dimen
    assert(d and d.w > 0, "the rating figure is not tappable: top is " .. tostring(dialog and dialog.name)
      .. ", on_rating " .. tostring(dialog and dialog.on_rating) .. ", windows [" .. stack_names() .. "]")
    emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
    emu:pump()

    local function tapText(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + 5, node.y + 5)
      emu:pump()
    end
    emu:expectText("Set rating")
    emu:shot("book_rating_spinner")

    -- up one half star, then Save
    tapText("plus")
    tapText("Save")

    emu:expectText("kept and will be sent")
    UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
    emu:pump()
    assert(top() == dialog, "saving did not come back to the details: " .. tostring(top() and top().name))
    assert(#writes("updateRating") == 0, "an offline rating was sent")
    assert(queue:get(9103) == 4.5, "the rating was not kept: " .. tostring(queue:get(9103)))
    assert(dialog.detail.user_rating == 4.5, "the screen did not take the new rating")
    emu:shot("book_rating_offline")

    -- reopening the book shows the waiting rating, not the one on record
    UIManager:close(dialog)
    emu:pump()
    go(true)
    manager:showBookDetail(103, 10301)
    emu:pump()
    go(false)
    assert(top().detail.user_rating == 4.5, "a reopened book lost the waiting rating")

    -- back online, the queue sends it
    local sent = {}
    queue:flush({ updateRating = function(_, id, r) sent[#sent + 1] = { id, r } return { id = id, status_id = 2 } end },
      function(id, ub) manager:ratingSent(id, ub) end)
    assert(#sent == 1 and sent[1][1] == 9103 and sent[1][2] == 4.5, "the queued rating was not sent")
    assert(queue:isEmpty(), "a sent rating stayed queued")

    -- online: saving asks for a flush straight away
    go(true)
    manager:rateBook(top())
    emu:pump()
    emu:expectText("Set rating")
    tapText("minus")
    tapText("Save")
    assert(flushed == 1, "an online rating did not trigger a send")
    assert(queue:get(9103) == 4, "the online rating was not queued: " .. tostring(queue:get(9103)))

    -- a star opens the stepper at that star
    top():on_rating(5)
    emu:pump()
    emu:expectText("Set rating")
    emu:expectText("5.0")
    tapText("Cancel")
  end,
}
