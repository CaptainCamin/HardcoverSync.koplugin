-- BUG: the reader's Rate dialog opened an unrated book at 2.5, so Save without
-- touching the stars wrote a rating the reader never chose.
--
-- Expected: unrated opens at 0, an untouched save writes nothing, and a
-- deliberate 0 still clears a rating.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
local RatingQueue = require("hardcover/lib/rating_queue")
local StepperDialog = require("hardcover/lib/ui/components/stepper_dialog")
local User = require("hardcover/lib/user")
User.settings = { readSetting = function() return 1 end }

local function setup(rating)
  KB.network.connected = false
  local rating_queue = RatingQueue:new { settings = KB.fakeSettings() }
  local state = { book_status = { id = 500, book_id = 7, status_id = 2, rating = rating } }
  local menu = setmetatable({
    enabled = true,
    state = state,
    settings = {
      bookLinked = function() return true end,
      getLinkedBookId = function() return 7 end,
      getLinkedTitle = function() return "Book" end,
      pages = function() return 100 end,
    },
    ui = { document = { file = "/books/a.epub" } },
    rating_queue = rating_queue,
    dialog_manager = {},
    sync_queue = {},
  }, { __index = HardcoverMenu })
  return menu, state, rating_queue
end

local function rating_item(menu)
  for _, item in ipairs(menu:getStatusSubMenuItems()) do
    local text = item.text or (item.text_func and item.text_func())
    if text == "Set rating" or text:sub(1, 13) == "Update rating" then return item end
  end
end

local function show_rating(item)
  local form
  local show = StepperDialog.show
  StepperDialog.show = function(opts) form = opts end
  item.callback({ updateItems = function() end })
  StepperDialog.show = show
  return form
end

print("\n== the reader's rating dialog ==")

KB.check("an unrated book opens at 0 and an untouched save writes nothing", function()
  local menu, state, rating_queue = setup(nil)
  local form = show_rating(rating_item(menu))
  KB.eq(form and form.value, 0, "unrated opening value")
  form.on_save(0)
  KB.eq(rating_queue:count(), 0, "queued rating")
  KB.eq(state.book_status.rating, nil, "rating shown")
end)

KB.check("a deliberate 0 clears a rating", function()
  local menu, state, rating_queue = setup(4)
  local form = show_rating(rating_item(menu))
  KB.eq(form and form.value, 4, "rated opening value")
  form.on_save(0)
  KB.eq(rating_queue:get(500), 0, "queued clear")
  KB.eq(state.book_status.rating, nil, "rating shown")
end)

KB.finish("an untouched unrated rating dialog must not write 2.5")
