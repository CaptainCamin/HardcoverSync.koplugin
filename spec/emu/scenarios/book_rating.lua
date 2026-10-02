--[[--
Rating a book from its details screen, with no connection: tapping "your rating"
opens the spinner, saving shows the new rating at once and sends nothing, and the
rating goes to Hardcover when the queue is flushed.

Screens: book_rating_spinner, book_rating_offline.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top()
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    if w and not w.toast then return w end
  end
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

    manager:showBookDetail(103, 10301)
    emu:pump()
    local dialog = top()
    emu:expectText("The Left Hand of Darkness")
    go(false) -- the connection drops with the book already open

    -- the third figure on the stats strip is the reader's own rating: "4"
    emu:screenNodes()
    local d = dialog.rating_tap and dialog.rating_tap.dimen
    assert(d and d.w > 0, "the rating figure is not tappable")
    emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
    emu:pump()

    local spinner = top()
    assert(spinner and spinner.value_widget, "tapping the rating did not open the spinner (top: " .. tostring(spinner and spinner.name) .. ")")
    emu:expectText("Set Rating")
    emu:shot("book_rating_spinner")

    -- up one half star, then Save
    spinner:onSpinButtonPressed({ 1, false })
    emu:screenNodes()
    local save = find_button(spinner, "Save")
    assert(save, "no Save button:\n" .. emu:screenText())
    emu:tapExpecting(save.dimen.x + math.floor(save.dimen.w / 2), save.dimen.y + math.floor(save.dimen.h / 2))
    emu:pump()

    emu:expectText("kept and will be sent")
    UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
    emu:pump()
    assert(top() == dialog, "saving did not come back to the details: " .. tostring(top() and top().name))
    assert(#writes("updateRating") == 0, "an offline rating was sent")
    assert(queue:get(9103) == 4.5, "the rating was not kept: " .. tostring(queue:get(9103)))
    assert(dialog.detail.user_rating == 4.5, "the screen did not take the new rating")
    emu:expectText("4.5")
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
    local sp = top()
    sp:onSpinButtonPressed({ -1, false })
    emu:screenNodes()
    local b = find_button(sp, "Save")
    emu:tapExpecting(b.dimen.x + math.floor(b.dimen.w / 2), b.dimen.y + math.floor(b.dimen.h / 2))
    emu:pump()
    assert(flushed == 1, "an online rating did not trigger a send")
    assert(queue:get(9103) == 4, "the online rating was not queued: " .. tostring(queue:get(9103)))
  end,
}
