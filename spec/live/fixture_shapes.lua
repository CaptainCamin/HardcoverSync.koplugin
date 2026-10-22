-- What the emulator's fake API (spec/emu/fixtures.lua) returns for each method, as shapes, so the
-- live check can hold it against what the real API returned. Loaded by hardcover_live.lua after its
-- live steps: installing the fixtures replaces the methods on the Api module.
--
-- One entry per method the fixtures fake, with arguments that land on fixture data. A method with
-- no entry here is not compared; one whose fake raises is reported by name.
local Shape = dofile((arg and arg[1] or ".") .. "/spec/live/shape.lua")

return function(Api, plugin_root, is_null)
  package.preload["hardcover/lib/ui/home_body"] = package.preload["hardcover/lib/ui/home_body"]
    or function() return {} end
  local fixtures = dofile(plugin_root .. "/spec/emu/fixtures.lua")
  fixtures.install({})

  local uid, book = fixtures.USER_ID, 101
  local calls = {
    me = {},
    search = { "The Dispossessed", "Ursula K. Le Guin", uid },
    findBooks = { "The Dispossessed", "Ursula K. Le Guin", uid },
    findEditions = { book, uid },
    getBookDetail = { book, uid },
    getBooksByIds = { { book } },
    getReviews = { book, 5, 0 },
    getSimilarBooks = { book },
    getBookLists = { book },
    getLists = {},
    getListCount = {},
    getListBooks = { 1, "mine", false, 0, 5 },
    getListMembers = { 1, "mine", 0, 5 },
    getShelf = { uid, 2, 0, 10 },
    getShelfCounts = { uid, { 1, 2, 3, 5 } },
    getCurrentlyReading = { uid, 5 },
    getStats = { uid },
    getForYou = {},
    getVibes = { uid },
    getGoals = {},
    updateUserBook = { book, 2 },
    updateRating = { 9001, 4 },
    updatePage = { 1, 1, 25, "2026-01-01" },
    createRead = { 9001, 1, 10, "2026-01-01" },
    createJournalEntry = { { book_id = book, entry = "x" } },
    addToList = { book, 1 },
  }

  local shapes, failed = {}, {}
  for name, args in pairs(calls) do
    if type(Api[name]) == "function" then
      local ok, result = pcall(Api[name], Api, unpack(args))
      if ok then shapes[name] = Shape.of(result, is_null) else failed[name] = tostring(result) end
    end
  end
  return shapes, failed
end
