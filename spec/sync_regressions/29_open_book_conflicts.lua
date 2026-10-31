-- Opening online must flush before asking about a conflict, and choosing the
-- cloud page must offer exactly one jump while this reader is open.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
package.preload["ui/event"] = function()
  return { new = function(_, name, page) return { name = name, page = page } end }
end
local App = KB.load_main()
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local prompts, question
StatusDialogs.confirm = function(opts) prompts[#prompts + 1] = opts end
package.loaded["hardcover/lib/ui/sync_conflict_dialog"] = {
  show = function(opts) question = opts end,
}

local file = "/book.epub"
local function newApp()
  prompts, question = {}, nil
  local queue = KB.newQueue()
  local app = KB.new_app {
    state = { book_status = { id = 7, status_id = HARDCOVER.STATUS.READING,
      user_book_reads = { { progress_pages = 250 } } } },
    ui = { document = { file = file, getPageCount = function() return 200 end },
      getCurrentPage = function() return 40 end,
      handleEvent = function(self, event) self.event = event end },
    settings = { pages = function() return 500 end, readBookSetting = function() end },
    page_mapper = { getMappedPage = function() return 100 end,
      getUnmappedPage = function(_, page) return page * 2 / 5 end },
    sync_queue = queue,
  }
  return app, queue
end

local function queuePage(queue)
  queue:enqueuePage(file, { mapped_page = 100, book_id = 1, user_id = 1 })
end

local function conflict(queue)
  queue:get(file).conflict = { kind = "page", local_page = 100, cloud_page = 250 }
end

KB.check("opening waits for the flush and offers the chosen cloud page immediately", function()
  local app, queue = newApp()
  queuePage(queue)
  local finish
  app.flushSyncQueue = function(_, _, done) if done then finish = done end end
  app:askAboutOpenBook()
  assert(finish and not question, "asked before the queued progress was checked")
  conflict(queue)
  finish(false)
  assert(question and question.only == file, "the new conflict was not asked")
  assert(queue:resolve(file, "cloud"))
  question.on_done(1)
  KB.eq(#prompts, 1, "jump questions")
  KB.eq(prompts[1].title, "Jump to page 250?", "jump title")
  prompts[1].ok_callback()
  KB.eq(app.ui.event.name, "GotoPage", "reader event")
  KB.eq(app.ui.event.page, 100, "mapped document page")
  app:offerJumpToCloudPage()
  KB.eq(#prompts, 1, "jump questions after cloud cache finishes")
end)

KB.check("choosing the cloud from an existing conflict offers the jump now", function()
  local app, queue = newApp()
  queuePage(queue); conflict(queue)
  app.flushSyncQueue = function(_, _, done) if done then done(true) end end
  app:askAboutOpenBook()
  assert(question and queue:resolve(file, "cloud"))
  question.on_done(1)
  KB.eq(#prompts, 1, "jump questions")
  KB.eq(prompts[1].title, "Jump to page 250?", "jump title")
end)

KB.check("a saved resume and a cloud cache offer cannot stack jump questions", function()
  local app, queue = newApp()
  queuePage(queue); conflict(queue); assert(queue:resolve(file, "cloud"))
  app.flushSyncQueue = function(_, _, done) if done then done(true) end end
  app:askAboutOpenBook()
  app:offerJumpToCloudPage()
  KB.eq(#prompts, 1, "resume then cache")

  app, queue = newApp()
  queuePage(queue); conflict(queue); assert(queue:resolve(file, "cloud"))
  app.flushSyncQueue = function(_, _, done) if done then done(true) end end
  app:offerJumpToCloudPage()
  app:askAboutOpenBook()
  KB.eq(#prompts, 1, "cache then resume")
end)

KB.check("deciding later keeps the conflict without a jump", function()
  local app, queue = newApp()
  queuePage(queue); conflict(queue)
  app.flushSyncQueue = function(_, _, done) if done then done(false) end end
  app:askAboutOpenBook()
  assert(question, "conflict not shown")
  question.on_done(0)
  KB.eq(queue:conflictCount(), 1, "conflict remains")
  KB.eq(#prompts, 0, "jump questions")
end)

KB.check("choosing this device is not followed by a stale cloud jump", function()
  local app, queue = newApp()
  queue.settings:saveSetting("resume", { [file] = 200 })
  queuePage(queue); conflict(queue)
  app.flushSyncQueue = function(_, _, done) if done then done(true) else queue:clearAll() end end
  app:askAboutOpenBook()
  assert(queue:resolve(file, "local"))
  question.on_done(1)
  app:offerJumpToCloudPage()
  KB.eq(#prompts, 0, "jump questions after keeping this device")
end)

KB.check("a flush finishing after the reader closes does not open a dialog", function()
  local app, queue = newApp()
  queuePage(queue)
  local finish
  app.flushSyncQueue = function(_, _, done) finish = done end
  app:askAboutOpenBook()
  conflict(queue)
  app.ui.document = nil
  finish(false)
  assert(not question and #prompts == 0, "dialog outlived the book")
end)

KB.finish("opening a book must resolve queued conflicts and offer one jump")
