-- Read edits in the per-book queue: a sparse write when the read is unchanged, a question when
-- Hardcover changed the same field, a hold when the record is gone, a lost response that is
-- checked rather than replayed, and one book's page question not stopping another book.
--
-- Run with:  luajit spec/read_edit_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local check = r.test

local NULL = {}
package.preload["json"] = function()
  return { util = { null = NULL }, encode = function() return "{}" end,
    decode = function() return {} end, decode_simple = function() return {} end }
end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end

local SyncQueue = require("hardcover/lib/sync_queue")
local Actions = require("hardcover/lib/reading_actions")

local function fakeSettings()
  local store = {}
  return {
    store = store,
    readSetting = function(_, key) return store[key] end,
    saveSetting = function(_, key, value) store[key] = value end,
    flush = function() end,
  }
end

local function queue()
  return SyncQueue:new { settings = fakeSettings() }
end

local function read(extra)
  local row = { id = 10, started_at = "2024-03-12", finished_at = "2024-03-20",
    finished_at_precision = 1, progress_pages = 100, edition_id = 7 }
  for key, value in pairs(extra or {}) do row[key] = value end
  return row
end

-- One library record per book id; the fake API records every mutation.
local function fakeApi()
  local api = { calls = {}, records = {} }
  function api:findUserBook(book_id)
    return self.records[tonumber(book_id)]
  end
  function api:updateRead(read_id, fields)
    self.calls[#self.calls + 1] = { op = "updateRead", read_id = read_id, fields = fields }
    local target, user_book
    for _, record in pairs(self.records) do
      for _, row in ipairs(record.user_book_reads or {}) do
        if tostring(row.id) == tostring(read_id) then target, user_book = row, record end
      end
    end
    if self.lose_updates then
      -- apply it, but lose the answer: the queue must check rather than repeat
      for key, value in pairs(fields) do
        if value == NULL then target[key] = nil else target[key] = value end
      end
      return nil, { completed = false }
    end
    for key, value in pairs(fields) do
      if value == NULL then target[key] = nil else target[key] = value end
    end
    return { id = user_book.id, status_id = user_book.status_id, user_book_reads = { target } }
  end
  function api:addRead(user_book_id, fields)
    self.calls[#self.calls + 1] = { op = "addRead", fields = fields }
    local user_book = self.records[tonumber(user_book_id)]
    local added = { id = 99 }
    for key, value in pairs(fields) do if value ~= NULL then added[key] = value end end
    added.edition = { id = added.edition_id, pages = 300, edition_format = "Paperback", reading_format_id = 1 }
    user_book.user_book_reads = user_book.user_book_reads or {}
    table.insert(user_book.user_book_reads, added)
    return { id = user_book.id, status_id = user_book.status_id, user_book_reads = { added } }
  end
  function api:deleteRead(read_id)
    self.calls[#self.calls + 1] = { op = "deleteRead", read_id = read_id }
    for _, record in pairs(self.records) do
      for index = #(record.user_book_reads or {}), 1, -1 do
        if tostring(record.user_book_reads[index].id) == tostring(read_id) then
          table.remove(record.user_book_reads, index)
        end
      end
    end
    return { id = read_id }
  end
  return api
end

local function record(book_id, reads, status)
  return { id = 500 + book_id, book_id = book_id, status_id = status or 2, user_book_reads = reads or {} }
end

local function enqueue(q, book_id, payload)
  payload = payload or {}
  payload.book_id = book_id
  payload.user_id = payload.user_id or 1
  payload.user_book_id = payload.user_book_id or (500 + book_id)
  payload.title = payload.title or ("Book " .. book_id)
  payload.kind = payload.kind or "read_dates"
  return q:enqueueReadEdit(book_id, payload)
end

print("\n== sparse writes and questions ==")

check("an unchanged read sends one sparse write", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() })
  local _, action = enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12", finished_at = "2024-03-20" },
    change = { started_at = "2024-03-14" } })
  assert(action.seq == 1)
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 1 and api.calls[1].op == "updateRead", "expected one update")
  assert(api.calls[1].fields.started_at == "2024-03-14")
  assert(api.calls[1].fields.finished_at == nil and api.calls[1].fields.progress_pages == nil,
    "a broad payload was sent")
  assert(api.records[7].user_book_reads[1].started_at == "2024-03-14")
  assert(#q:readActions(7) == 0, "the action was not acknowledged")
end)

check("a changed field parks, with no write and a decision", function()
  local q, api = queue(), fakeApi()
  local row = read { started_at = "2024-03-13" }
  api.records[7] = record(7, { row })
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" }, change = { started_at = "2024-03-14" } })
  assert(q:flush(api, { user_id = 1 }) == false)
  assert(#api.calls == 0, "a park must not write")
  local actions = q:readActions(7)
  assert(#actions == 1 and actions[1].conflict and actions[1].conflict.kind == "read_changed")
  assert(actions[1].conflict.fields[1].field == "started_at")
  local decisions = q:decisions(1)
  assert(#decisions == 1 and decisions[1].kind == "read_changed", "the question did not reach decisions()")
end)

check("a field already equal is acknowledged with no write", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read { started_at = "2024-03-14" } })
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" }, change = { started_at = "2024-03-14" } })
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 0)
  assert(#q:readActions(7) == 0)
end)

check("a read that is gone parks with add_again", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read { id = 11 } })
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" }, change = { started_at = "2024-03-14" } })
  assert(q:flush(api, { user_id = 1 }) == false)
  local action = q:readActions(7)[1]
  assert(action.conflict and action.conflict.kind == "read_gone", "not a gone-read question")
  assert(#api.calls == 0)
end)

check("a library record that is gone holds the book", function()
  local q, api = queue(), fakeApi()
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" }, change = { started_at = "2024-03-14" } })
  assert(q:flush(api, { user_id = 1 }) == false)
  local entry = q:get(7)
  assert(entry.held == true and entry.reason == "library_gone")
  assert(#q:readActions(7) == 1, "the edit was dropped")
end)

print("\n== lost responses and cancellation ==")

check("a lost response is checked, not repeated", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() })
  api.lose_updates = true
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" }, change = { started_at = "2024-03-14" } })
  assert(q:flush(api, { user_id = 1 }) == false)
  assert(#api.calls == 1 and api.calls[1].op == "updateRead")
  assert(q:readActions(7)[1].checking == true)
  -- the read did land: the next flush verifies it and writes nothing again
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 1, "the lost write was repeated")
  assert(#q:readActions(7) == 0)
end)

check("cancel works before sending, and is refused while checking", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() })
  local _, action = enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" },
    change = { started_at = "2024-03-14" } })
  assert(q:cancelReadEdit(7, action.seq, 1))
  assert(#q:readActions(7) == 0)
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 0)

  local _, second = enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" },
    change = { started_at = "2024-03-15" } })
  api.lose_updates = true
  q:flush(api, { user_id = 1 })
  local refused, reason = q:cancelReadEdit(7, second.seq, 1)
  assert(refused == false and reason == "started", tostring(reason))
end)

check("a page question for one book does not stop another book's read edit", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() })
  api.records[8] = record(8, { read { id = 20, started_at = "2020-01-01" } })
  q:enqueuePage("/books/7.epub", { book_id = 7, mapped_page = 50 })
  q:get(7).conflict = { kind = "page", local_page = 50, cloud_page = 200, seq = 1 }
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" }, change = { started_at = "2024-03-14" } })
  enqueue(q, 8, { read_id = 20, base = { started_at = "2020-01-01" }, change = { started_at = "2020-01-02" } })
  q:flush(api, { user_id = 1 })
  assert(#q:readActions(7) == 1, "the held book's edit was dropped")
  assert(#q:readActions(8) == 0, "the other book's edit did not send")
  assert(#api.calls == 1 and api.calls[1].read_id == 20)
end)

print("\n== answers ==")

check("use_device sends the proposed field after a clash", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read { started_at = "2024-03-13" } })
  local _, action = enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" },
    change = { started_at = "2024-03-14" } })
  q:flush(api, { user_id = 1 })
  assert(q:resolveRead(7, action.seq, "use_device"))
  assert(#q:readActions(7) == 1 and q:readActions(7)[1].conflict == nil)
  q:flush(api, { user_id = 1 })
  assert(#api.calls == 1 and api.calls[1].fields.started_at == "2024-03-14")
end)

check("keep_hardcover drops the disputed field and sends nothing", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read { started_at = "2024-03-13" } })
  local _, action = enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" },
    change = { started_at = "2024-03-14" } })
  q:flush(api, { user_id = 1 })
  assert(q:resolveRead(7, action.seq, "keep_hardcover"))
  assert(#q:readActions(7) == 0)
  q:flush(api, { user_id = 1 })
  assert(#api.calls == 0)
end)

check("add_again turns a gone read into an addition", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read { id = 11 } })
  local _, action = enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12",
    finished_at = "2024-03-20", edition_id = 7 }, change = { started_at = "2024-03-14" } })
  q:flush(api, { user_id = 1 })
  assert(action.conflict.kind == "read_gone")
  assert(q:resolveRead(7, action.seq, "add_again"))
  assert(q:readActions(7)[1].kind == "add_read")
  q:flush(api, { user_id = 1 })
  assert(#api.calls == 1 and api.calls[1].op == "addRead")
  assert(api.calls[1].fields.started_at == "2024-03-14" and api.calls[1].fields.finished_at == "2024-03-20")
end)

check("send_anyway sends an older read, wait leaves it waiting", function()
  local q, api = queue(), fakeApi()
  local older = read { id = 10 }
  local newer = read { id = 11, started_at = "2025-01-01" }
  newer.finished_at = nil
  api.records[7] = record(7, { older, newer }, 2)
  local _, action = enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" },
    change = { started_at = "2024-03-14" } })
  q:flush(api, { user_id = 1 })
  assert(action.conflict and action.conflict.kind == "read_reading")
  assert(q:resolveRead(7, action.seq, "wait"))
  assert(action.wait == true)
  q:flush(api, { user_id = 1 })
  assert(#api.calls == 0, "wait wrote")
  -- the newer read is finished: the wait no longer applies and the edit sends
  newer.finished_at = "2025-02-01"
  q:flush(api, { user_id = 1 })
  assert(#api.calls == 1 and api.calls[1].fields.started_at == "2024-03-14")
end)

r.finish()
