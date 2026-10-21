-- Changing the edition of a linked book (Hardcover:linkBook with the same book and another edition).
--
-- A page is a share of an edition's pages, so the queued page and the read's progress move to the
-- new edition's pages, and the read moves to the new edition on Hardcover. A shelved book is moved
-- on Hardcover first: when Hardcover does not answer, nothing on this device changes, and trying
-- again gives the same result.
--
-- Run with:  lua spec/edition_change_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

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

local shown = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function() end, setDirty = function() end, scheduleIn = function() end,
    unschedule = function() end, forceRePaint = function() end, nextTick = function(_, fn) fn() end,
  }
end
package.preload["hardcover/lib/ui/status_dialogs"] = function()
  return { error = function(text) shown[#shown + 1] = text end }
end
package.preload["ui/widget/notification"] = function()
  return { new = function(_, o) return o end }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) fn() end }
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local Api = real_require("hardcover/lib/hardcover_api")
local Hardcover = real_require("hardcover/lib/hardcover")

local FILE = "/books/a.epub"

-- A recording stand-in for the Hardcover API. Each test sets the answers it wants.
local calls, answers
local function resetApi(answer)
  calls = {}
  answers = answer or {}
  Api.updatePage = function(_, read_id, edition_id, page, started_at)
    calls[#calls + 1] = { "updatePage", read_id, edition_id, page, started_at }
    return answers.updatePage
  end
  Api.updateUserBook = function(_, book_id, status_id, privacy_setting_id, edition_id)
    calls[#calls + 1] = { "updateUserBook", book_id, status_id, privacy_setting_id, edition_id }
    return answers.updateUserBook
  end
end

-- A book on the shelf, with its current read at page 120 of an edition of 300 pages.
local function shelvedStatus()
  return {
    id = 5, book_id = 7, status_id = 3, privacy_setting_id = 1, edition_id = 10,
    user_book_reads = { { id = 77, progress_pages = 120, started_at = "2026-01-01", edition_id = 10 } },
  }
end

local function newLink(opts)
  local store = {
    book_id = opts.book_id or 7, edition_id = opts.edition_id or 10, title = "Old title",
    pages = not opts.no_pages and 300 or nil,
  }
  local saved = { snapshots = 0 }
  local queue = {
    entries = opts.queue or {},
  }
  function queue:get(f) return self.entries[f] end
  function queue:save(f, entry) self.entries[f] = entry; saved.queue_saves = (saved.queue_saves or 0) + 1 end
  function queue:clear(f) self.entries[f] = nil end

  local settings = {}
  function settings:readBookSetting(_, key) return store[key] end
  function settings:pages() return store.pages end
  function settings:updateBookSetting(_, s)
    for key, value in pairs(s) do
      if key ~= "_delete" then store[key] = value end
    end
  end
  function settings:clearBookSnapshot() end

  local cache = {
    sync_queue = queue,
    saveSnapshot = function(_, f, status) saved.snapshots = saved.snapshots + 1; saved.snapshot = status end,
    cacheUserBook = function() end,
  }

  local h = setmetatable({
    ui = { document = { file = FILE } },
    settings = settings,
    cache = cache,
    state = { book_status = opts.status or {} },
  }, { __index = Hardcover })
  return h, store, queue, saved
end

local function newBook(overrides)
  local book = { book_id = 7, edition_id = 20, edition_format = "Kindle", pages = 400, title = "New title" }
  for k, v in pairs(overrides or {}) do book[k] = v end
  return book
end

local check = r.test

check("a shelved book moves on Hardcover, its read and its queued page to the new edition", function()
  resetApi({ updatePage = { id = 77, progress_pages = 160, edition_id = 20 },
    updateUserBook = { id = 5, status_id = 3, edition_id = 20, privacy_setting_id = 1 } })
  local h, store, queue, saved = newLink({ status = shelvedStatus(),
    queue = { [FILE] = { book_id = 7, edition_id = 10, mapped_page = 120, updated_at = 1 } } })

  assert(h:linkBook(newBook()) == true, "linkBook did not succeed")
  assert(#calls == 2 and calls[1][1] == "updatePage" and calls[2][1] == "updateUserBook",
    "server calls out of order or missing: " .. #calls)
  assert(calls[1][2] == 77 and calls[1][3] == 20 and calls[1][4] == 160 and calls[1][5] == "2026-01-01",
    "the read was not moved to the new edition with its progress")
  assert(calls[2][2] == 7 and calls[2][3] == 3 and calls[2][4] == 1 and calls[2][5] == 20,
    "the shelf entry was not moved to the new edition")
  assert(store.edition_id == 20 and store.pages == 400, "the file's link did not take the new edition")
  local entry = queue:get(FILE)
  assert(entry.mapped_page == 160 and entry.edition_id == 20, "the queued page was not moved")
  assert(saved.snapshots == 1 and saved.snapshot.edition_id == 20, "the snapshot was not saved with the new edition")
  assert(h.state.book_status.edition_id == 20 and h.state.book_status.user_book_reads[1].progress_pages == 160,
    "the saved status does not show the new edition and progress")
  assert(#shown == 0, "a successful change showed an error")
end)

check("a failed read move changes nothing here, and a retry gives the same result", function()
  resetApi({ updatePage = nil })
  local h, store, queue = newLink({ status = shelvedStatus(),
    queue = { [FILE] = { book_id = 7, edition_id = 10, mapped_page = 120 } } })
  shown = {}

  assert(h:linkBook(newBook()) == false, "linkBook reported success")
  assert(#calls == 1, "the shelf entry was changed after the read failed")
  assert(store.edition_id == 10, "the file's link changed")
  assert(queue:get(FILE).mapped_page == 120 and queue:get(FILE).edition_id == 10, "the queue changed")
  assert(h.state.book_status.edition_id == 10 and h.state.book_status.user_book_reads[1].progress_pages == 120,
    "the saved status changed")
  assert(#shown == 1, "the failure was not shown")

  resetApi({ updatePage = { id = 77, progress_pages = 160, edition_id = 20 },
    updateUserBook = { id = 5, status_id = 3, edition_id = 20, privacy_setting_id = 1 } })
  assert(h:linkBook(newBook()) == true, "the retry did not succeed")
  assert(calls[1][4] == 160, "the retry moved the progress from a different starting point")
end)

check("a failed shelf update changes nothing here", function()
  resetApi({ updatePage = { id = 77, progress_pages = 160, edition_id = 20 }, updateUserBook = nil })
  local h, store, queue = newLink({ status = shelvedStatus(),
    queue = { [FILE] = { book_id = 7, edition_id = 10, mapped_page = 120 } } })
  shown = {}

  assert(h:linkBook(newBook()) == false, "linkBook reported success")
  assert(store.edition_id == 10, "the file's link changed")
  assert(queue:get(FILE).mapped_page == 120 and queue:get(FILE).edition_id == 10, "the queue changed")
  assert(h.state.book_status.edition_id == 10, "the saved status was wiped")
  assert(#shown == 1, "the failure was not shown")
end)

check("an unshelved book changes no server data, but its queued page still moves", function()
  resetApi({})
  local h, store, queue = newLink({ status = {},
    queue = { [FILE] = { book_id = 7, edition_id = 10, mapped_page = 120 } } })

  assert(h:linkBook(newBook()) == true, "linkBook did not succeed")
  assert(#calls == 0, "the server was called for an unshelved book")
  assert(store.edition_id == 20, "the file's link did not take the new edition")
  assert(queue:get(FILE).mapped_page == 160 and queue:get(FILE).edition_id == 20, "the queued page was not moved")
end)

check("a different book clears the queue and calls nothing", function()
  resetApi({})
  local h, store, queue = newLink({ status = shelvedStatus(),
    queue = { [FILE] = { book_id = 7, edition_id = 10, mapped_page = 120 } } })

  assert(h:linkBook(newBook({ book_id = 99, edition_id = 30, pages = 250 })) == true, "linkBook did not succeed")
  assert(#calls == 0, "the server was called for a different book")
  assert(queue:get(FILE) == nil, "the old book's queued page survived")
  assert(store.book_id == 99, "the file is not linked to the new book")
end)

check("choosing the same edition again changes nothing", function()
  resetApi({})
  local h, _, queue = newLink({ status = shelvedStatus(),
    queue = { [FILE] = { book_id = 7, edition_id = 10, mapped_page = 120 } } })

  assert(h:linkBook(newBook({ edition_id = 10, pages = 300 })) == true, "linkBook did not succeed")
  assert(#calls == 0, "the server was called for the same edition")
  assert(queue:get(FILE).mapped_page == 120, "the queued page moved for the same edition")
end)

check("with no page count known, the page is kept as it is", function()
  resetApi({})
  local h, _, queue = newLink({ no_pages = true, status = {},
    queue = { [FILE] = { book_id = 7, edition_id = 10, mapped_page = 120 } } })

  assert(h:linkBook(newBook()) == true, "linkBook did not succeed")
  assert(queue:get(FILE).mapped_page == 120, "the page was moved without a page count to move it by")
end)

r.finish()
