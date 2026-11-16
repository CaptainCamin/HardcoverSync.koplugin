--[[--
Rating a book from its details screen, with no connection: tapping "your rating"
opens the stepper, saving shows the new rating at once and sends nothing, and the
rating goes to Hardcover when the queue is flushed.

Screens: book_rating_spinner, book_rating_offline, book_rating_unrated_dialog,
book_rating_unrated_noop.
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
      function(id, ub) manager:ratingSent(id, ub) end, require("hardcover/lib/user"):getId())
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

    -- A book with no rating opens at "No rating", and Save without touching it
    -- writes nothing (not 2.5, not 0).
    emu:closeAll()
    emu:pump()
    local originalDetail = Api.getBookDetail
    Api.getBookDetail = function(_, book_id, ...)
      local detail = originalDetail(_, book_id, ...)
      if tonumber(book_id) == 104 then detail.user_rating = nil end
      return detail
    end
    local unrated = manager:showBookDetail(104, 10401)
    emu:pump()
    emu:screenNodes()
    go(true)
    local ur = unrated.rating_tap and unrated.rating_tap.dimen
    assert(ur and ur.w > 0, "the unrated book's rating figure is not tappable")
    emu:tapExpecting(ur.x + math.floor(ur.w / 2), ur.y + math.floor(ur.h / 2))
    emu:pump()
    emu:expectText("Set rating")
    emu:expectText("No rating")
    emu:shot("book_rating_unrated_dialog")
    tapText("Save")
    assert(#writes("updateRating") == 0, "an untouched unrated dialog wrote a rating")
    assert(queue:get(9104) == nil, "an untouched unrated dialog queued a rating")
    assert(unrated.detail.user_rating == nil, "the screen invented a rating")
    emu:shot("book_rating_unrated_noop")

    -- Back is another non-save path: it must not commit the selected star.
    local star2 = unrated.rating_stars[2].dimen
    emu:tapExpecting(star2.x + math.floor(star2.w / 2), star2.y + math.floor(star2.h / 2))
    emu:pump()
    emu:expectText("2.0")
    emu:press("Back")
    emu:pump()
    assert(queue:get(9104) == nil, "Back committed star 2")
    assert(unrated.detail.user_rating == nil, "Back changed the screen for star 2")

    -- The generic entry point opens at 0, and a half star chosen there is 0.5.
    local label = unrated.rating_tap.dimen
    emu:tapExpecting(label.x + math.floor(label.w / 2), label.y + math.floor(label.h / 2))
    emu:pump()
    emu:expectText("No rating")
    tapText("plus")
    emu:expectText("0.5")
    tapText("Cancel")
    assert(queue:get(9104) == nil, "Cancel committed the generic half star")

    -- Each star opens the stepper at that star, and each supported half-star
    -- position above it is reachable. Cancel writes nothing at any of them.
    for i = 1, 5 do
      local star = unrated.rating_stars[i].dimen
      emu:tapExpecting(star.x + math.floor(star.w / 2), star.y + math.floor(star.h / 2))
      emu:pump()
      emu:expectText(i .. ".0")
      if i < 5 then
        tapText("plus")
        emu:expectText(i .. ".5")
      end
      tapText("Cancel")
      assert(queue:get(9104) == nil, "Cancel committed star " .. i)
      assert(unrated.detail.user_rating == nil, "Cancel changed the screen for star " .. i)
    end

    -- An explicit star choice saves; a half-star chosen in the stepper saves too.
    local star4 = unrated.rating_stars[4].dimen
    emu:tapExpecting(star4.x + math.floor(star4.w / 2), star4.y + math.floor(star4.h / 2))
    emu:pump()
    emu:expectText("4.0")
    tapText("plus")
    emu:expectText("4.5")
    tapText("Save")
    assert(queue:get(9104) == 4.5, "the explicit half-star choice was not kept")
    assert(unrated.detail.user_rating == 4.5, "the screen did not take the explicit choice")

    -- A generic Rate entry point on a rated book opens at that rating, and
    -- Save without touching it writes nothing.
    queue:cancel(9103)
    emu:closeAll()
    emu:pump()
    local rated = manager:showBookDetail(103, 10301)
    emu:pump()
    emu:screenNodes()
    local rr = rated.rating_tap.dimen
    emu:tapExpecting(rr.x + math.floor(rr.w / 2), rr.y + math.floor(rr.h / 2))
    emu:pump()
    emu:expectText("4.0")
    tapText("Save")
    assert(queue:get(9103) == nil, "an untouched existing rating was written again")
    assert(rated.detail.user_rating == 4, "the existing rating changed without an edit")

    -- A tapped star wins over the rating on record: star 3 opens 3, not 4.
    local star3 = rated.rating_stars[3].dimen
    emu:tapExpecting(star3.x + math.floor(star3.w / 2), star3.y + math.floor(star3.h / 2))
    emu:pump()
    emu:expectText("3.0")
    tapText("Cancel")
    assert(queue:get(9103) == nil, "Cancel committed star 3")

    -- An explicit star tap is a choice, so saving it writes that star even when
    -- it matches the rating already on record.
    local rated_star = rated.rating_stars[4].dimen
    emu:tapExpecting(rated_star.x + math.floor(rated_star.w / 2),
      rated_star.y + math.floor(rated_star.h / 2))
    emu:pump()
    emu:expectText("4.0")
    tapText("Save")
    assert(queue:get(9103) == 4, "an explicit star choice was not saved")

    -- 0 still clears a rated book.
    emu:screenNodes()
    emu:tapExpecting(rr.x + math.floor(rr.w / 2), rr.y + math.floor(rr.h / 2))
    emu:pump()
    for _ = 1, 8 do tapText("minus") end
    emu:expectText("No rating")
    tapText("Save")
    assert(queue:get(9103) == 0, "0 did not clear the rating")
    assert(rated.detail.user_rating == nil, "the screen did not show the cleared rating")
  end,
}
