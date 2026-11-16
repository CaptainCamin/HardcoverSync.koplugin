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
    local user_book
    for _, record in pairs(self.records) do
      if tostring(record.id) == tostring(user_book_id) then user_book = record; break end
    end
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
  function api:updatePage(read_id, edition_id, page, started_at)
    self.calls[#self.calls + 1] = { op = "updatePage", read_id = read_id, edition_id = edition_id,
      page = page, started_at = started_at }
    for _, record in pairs(self.records) do
      for _, row in ipairs(record.user_book_reads or {}) do
        if tostring(row.id) == tostring(read_id) then
          row.progress_pages, row.edition_id = page, edition_id
          return record
        end
      end
    end
  end
  function api:updateUserBook(book_id, status_id, privacy_setting_id, edition_id)
    self.calls[#self.calls + 1] = { op = "updateUserBook", book_id = book_id,
      status_id = status_id, privacy_setting_id = privacy_setting_id, edition_id = edition_id }
    if self.fail_user_book then
      self.fail_user_book = false
      return nil, { completed = false }
    end
    local user_book = self.records[tonumber(book_id)]
    if not user_book then return nil, "not found" end
    user_book.status_id, user_book.edition_id = status_id, edition_id
    user_book.privacy_setting_id = privacy_setting_id
    return user_book
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

check("a failed verification lookup keeps the edit checking", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() })
  local real_find = api.findUserBook
  local failed = false
  function api:findUserBook(book_id)
    if not failed and #self.calls > 0 then
      failed = true
      return nil, { message = "timeout" }
    end
    return real_find(self, book_id)
  end
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" },
    change = { started_at = "2024-03-14" } })
  assert(q:flush(api, { user_id = 1 }) == false)
  local action = q:readActions(7)[1]
  assert(action and action.checking and not action.conflict, "the lookup error became a question")
  assert(#api.calls == 1 and api.calls[1].op == "updateRead")
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 1, "the verified write was repeated")
  assert(#q:readActions(7) == 0)
end)

check("a partly applied attempt sends only the field still waiting", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() })
  api.lose_updates = true
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12", finished_at = "2024-03-20" },
    change = { started_at = "2024-03-14", finished_at = "2024-03-21" } })
  assert(q:flush(api, { user_id = 1 }) == false)
  -- another device put the start back while the finish stayed as this attempt wrote it
  api.records[7].user_book_reads[1].started_at = "2024-03-12"
  api.lose_updates = false
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 2 and api.calls[2].op == "updateRead", "the remaining start was not sent")
  assert(api.calls[2].fields.started_at == "2024-03-14")
  assert(api.calls[2].fields.finished_at == nil, "the satisfied finish was sent again")
  assert(#q:readActions(7) == 0)
end)

check("reconciliation continues from the snapshot that was verified", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() })
  api.lose_updates = true
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12", finished_at = "2024-03-20" },
    change = { started_at = "2024-03-14", finished_at = "2024-03-21" } })
  assert(q:flush(api, { user_id = 1 }) == false)
  api.lose_updates = false
  -- Two partial snapshots: the first lookup has only the new start, the verification has only
  -- the new finish. The send must use the verified snapshot, not mix the two.
  api.records[7].user_book_reads[1].started_at = "2024-03-12"
  local real_find = api.findUserBook
  local lookups = 0
  function api:findUserBook(book_id)
    if #self.calls == 1 then
      lookups = lookups + 1
      if lookups == 1 then
        return record(7, { read { started_at = "2024-03-14", finished_at = "2024-03-20" } }, 2)
      elseif lookups == 2 then
        return record(7, { read { started_at = "2024-03-12", finished_at = "2024-03-21" } }, 2)
      end
    end
    return real_find(self, book_id)
  end
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 2 and api.calls[2].op == "updateRead", "the remaining start was not sent")
  assert(api.calls[2].fields.started_at == "2024-03-14")
  assert(api.calls[2].fields.finished_at == nil, "the satisfied finish was sent again")
  assert(#q:readActions(7) == 0)
end)

check("an added read whose fields differ is acknowledged without a second insert", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, {}, 3)
  local real_add = api.addRead
  function api:addRead(user_book_id, fields)
    local result = real_add(self, user_book_id, fields)
    self.records[7].user_book_reads[1].started_at = "2020-01-03"
    return result
  end
  enqueue(q, 7, { kind = "add_read", change = { started_at = "2020-01-01",
    finished_at = "2020-01-02", edition_id = 7 } })
  assert(q:flush(api, { user_id = 1 }) == true, "the landed insertion was left checking")
  assert(#api.calls == 1 and api.calls[1].op == "addRead")
  assert(#q:readActions(7) == 0, "the landed insertion stayed queued")
  assert(api.records[7].user_book_reads[1].started_at == "2020-01-03")
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

print("\n== additions and removals ==")

check("an addition inserts one read and is acknowledged", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, {}, 3)
  enqueue(q, 7, { kind = "add_read", change = { started_at = "2020-01-01",
    finished_at = "2020-01-02", finished_at_precision = 1, edition_id = 7 } })
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 1 and api.calls[1].op == "addRead")
  assert(api.calls[1].fields.finished_at == "2020-01-02" and api.calls[1].fields.edition_id == 7)
  assert(#api.records[7].user_book_reads == 1 and #q:readActions(7) == 0)
end)

check("editing an unsent addition changes it in place", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, {}, 3)
  local _, action = enqueue(q, 7, { kind = "add_read", local_id = "local:1",
    change = { started_at = "2020-01-01", finished_at = "2020-01-02", edition_id = 7 } })
  local _, same = enqueue(q, 7, { kind = "add_read", local_id = "local:1",
    change = { started_at = "2020-01-01", finished_at = "2020-01-03", edition_id = 7 } })
  assert(same == action and #q:readActions(7) == 1, "a second addition was queued")
  assert(q:readActions(7)[1].change.finished_at == "2020-01-03")
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 1 and api.calls[1].fields.finished_at == "2020-01-03")
end)

check("editing only one date of an unsent addition keeps its untouched dates", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, {}, 3)
  enqueue(q, 7, { kind = "add_read", local_id = "local:1",
    change = { started_at = "2020-01-01", finished_at = "2020-01-02", edition_id = 7 } })
  enqueue(q, 7, { kind = "add_read", local_id = "local:1",
    change = { started_at = "2020-01-03" } })
  local action = q:readActions(7)[1]
  assert(action.change.started_at == "2020-01-03", "the new start was lost")
  assert(action.change.finished_at == "2020-01-02", "the untouched finish date was dropped")
  assert(action.change.edition_id == 7, "the untouched edition was dropped")
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(api.calls[1].fields.finished_at == "2020-01-02", "the insert lost the finish date")
  assert(api.calls[1].fields.started_at == "2020-01-03")
end)

check("an added read whose verification lookup lags is never inserted twice", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, {}, 3)
  local real_find = api.findUserBook
  local lookups = 0
  function api:findUserBook(book_id)
    lookups = lookups + 1
    -- A fresh copy each time: the API's stale answer must not carry the add's own answer.
    if lookups <= 5 then return record(7, {}, 3) end
    return real_find(self, book_id)
  end
  enqueue(q, 7, { kind = "add_read", change = { started_at = "2020-01-01",
    finished_at = "2020-01-02", edition_id = 7 } })
  assert(q:flush(api, { user_id = 1 }) == false, "the first pass should be checking")
  assert(#api.calls == 1 and api.calls[1].op == "addRead")
  assert(q:readActions(7)[1].added_id == 99, "the returned read id was not kept")
  assert(q:flush(api, { user_id = 1 }) == false, "the lagging lookup should keep checking")
  assert(#api.calls == 1, "a second insert was sent while the first was still appearing")
  assert(q:flush(api, { user_id = 1 }) == true, "the read should be found once the lookup catches up")
  assert(#api.calls == 1 and #q:readActions(7) == 0)
end)

check("an unsent addition can be discarded without an API call", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, {}, 3)
  local _, action = enqueue(q, 7, { kind = "add_read",
    change = { started_at = "2020-01-01", finished_at = "2020-01-02", edition_id = 7 } })
  assert(q:cancelReadEdit(7, action.seq, 1))
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 0 and #q:readActions(7) == 0)
end)

check("a removal after an unsent date edit sends both in order and leaves no read", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() }, 3)
  enqueue(q, 7, { read_id = 10, base = { started_at = "2024-03-12" },
    change = { started_at = "2024-03-14" } })
  enqueue(q, 7, { kind = "remove_read", read_id = 10, base = { started_at = "2024-03-12" } })
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 2 and api.calls[1].op == "updateRead" and api.calls[2].op == "deleteRead")
  assert(#api.records[7].user_book_reads == 0 and #q:readActions(7) == 0)
end)

check("the only read can be removed, including a year-precision import", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read { started_at = nil, finished_at = "2019-01-01",
    finished_at_precision = 3 } }, 3)
  enqueue(q, 7, { kind = "remove_read", read_id = 10,
    base = { finished_at = "2019-01-01", finished_at_precision = 3 } })
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 1 and api.calls[1].op == "deleteRead" and api.calls[1].read_id == 10)
end)

print("\n== edition changes ==")

local function editionSettings()
  local books, snaps = {}, {}
  return {
    updateBookSetting = function(_, file, update) books[file] = update end,
    saveBookSnapshot = function(_, file, user_book) snaps[file] = user_book end,
  }, books, snaps
end

check("the current read moves first, then its library record, with the converted page", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() }, 2)
  local settings, books, snaps = editionSettings()
  local state = { book_status = { id = 507, book_id = 7, status_id = 2, privacy_setting_id = 1,
    edition_id = 7, user_book_reads = { read() } } }
  enqueue(q, 7, { kind = "read_edition", read_id = 10, current = true, target_edition_id = 8,
    target_page = 200, old_edition_id = 7, old_pages = 304, old_format = "Paperback",
    new_pages = 608, edition_format = "E-book", file = "/books/7.epub",
    base = { edition_id = 7, progress_pages = 100 },
    change = { edition_id = 8, progress_pages = 200 } })
  assert(q:flush(api, { user_id = 1, settings = settings, state = state, file = "/books/7.epub" }) == true)
  assert(#api.calls == 2 and api.calls[1].op == "updateRead" and api.calls[2].op == "updateUserBook",
    "the read and the library record were not written in order")
  assert(api.calls[1].fields.edition_id == 8 and api.calls[1].fields.progress_pages == 200)
  assert(api.records[7].edition_id == 8, "the library record still has the old edition")
  assert(api.records[7].user_book_reads[1].edition_id == 8
    and api.records[7].user_book_reads[1].progress_pages == 200)
  assert(books["/books/7.epub"].edition_id == 8 and books["/books/7.epub"].pages == 608,
    "the linked file was not moved")
  assert(snaps["/books/7.epub"] and state.book_status.edition_id == 8, "the snapshot and state were not moved")
  assert(#q:readActions(7) == 0)
end)

check("a library update that did not land is retried without losing the read", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() }, 2)
  api.records[7].edition_id = 7
  api.fail_user_book = true
  enqueue(q, 7, { kind = "read_edition", read_id = 10, current = true, target_edition_id = 8,
    target_page = 200, base = { edition_id = 7, progress_pages = 100 },
    change = { edition_id = 8, progress_pages = 200 } })
  assert(q:flush(api, { user_id = 1 }) == false)
  assert(api.records[7].user_book_reads[1].edition_id == 8, "the read did not move first")
  assert(api.records[7].edition_id == 7, "the failed library update changed the record")
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(api.records[7].edition_id == 8, "the library update was not retried")
  assert(#q:readActions(7) == 0)
end)

check("a page queued before an edition change is sent in the old units first", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() }, 2)
  q:enqueuePage("/books/7.epub", { book_id = 7, mapped_page = 150, edition_id = 7 })
  enqueue(q, 7, { kind = "read_edition", read_id = 10, current = true, target_edition_id = 8,
    target_page = 300, base = { edition_id = 7, progress_pages = 150 },
    change = { edition_id = 8, progress_pages = 300 } })
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(api.calls[1].op == "updatePage" and api.calls[1].edition_id == 7
    and api.calls[1].page == 150, "the old page was not sent in the old units")
  assert(api.calls[2].op == "updateRead" and api.calls[2].fields.edition_id == 8,
    "the edition change did not follow the page")
end)

check("keeping Hardcover's edition reports the link to restore", function()
  local q, api = queue(), fakeApi()
  local row = read { edition_id = 7 }
  api.records[7] = record(7, { row }, 2)
  api.records[7].edition_id = 7
  local _, action = enqueue(q, 7, { kind = "read_edition", read_id = 10, current = true,
    target_edition_id = 8, target_page = 200, old_edition_id = 7, old_pages = 304,
    base = { edition_id = 7, progress_pages = 100 },
    change = { edition_id = 8, progress_pages = 200 } })
  row.edition_id = 9 -- changed on another device
  assert(q:flush(api, { user_id = 1 }) == false)
  local saved, outcome = q:resolveRead(7, action.seq, "keep_hardcover")
  assert(saved and outcome and outcome.kind == "edition_link", "the link was not reported for restore")
  assert(outcome.action == action and outcome.book_id == 7)
  assert(action.change.progress_pages == nil and action.target_page == nil,
    "the page converted for the discarded edition was kept")
  assert(#q:readActions(7) == 0, "the discarded page was left queued")
end)

check("an edition change with later pages cannot be cancelled out from under them", function()
  local q, api = queue(), fakeApi()
  api.records[7] = record(7, { read() }, 2)
  local _, edition = enqueue(q, 7, { kind = "read_edition", read_id = 10, current = true,
    target_edition_id = 8, target_page = 200, base = { edition_id = 7, progress_pages = 100 },
    change = { edition_id = 8, progress_pages = 200 } })
  q:enqueuePage("/books/7.epub", { book_id = 7, mapped_page = 220, edition_id = 8 })
  assert(q:cancelReadEdit(7, edition.seq, 1) == false, "the edition change was cancelled with pages behind it")
  assert(q:readActions(7)[1].kind == "read_edition", "the edition change was removed")
end)

check("a past read's edition changes only that read", function()
  local q, api = queue(), fakeApi()
  local older, newer = read { id = 10 }, read { id = 11, started_at = "2025-01-01" }
  api.records[7] = record(7, { older, newer }, 2)
  api.records[7].edition_id = 7
  enqueue(q, 7, { kind = "read_edition", read_id = 10, current = false, force = true,
    target_edition_id = 8, target_page = 200, base = { edition_id = 7, progress_pages = 100 },
    change = { edition_id = 8, progress_pages = 200 } })
  assert(q:flush(api, { user_id = 1 }) == true)
  assert(#api.calls == 1 and api.calls[1].op == "updateRead", "a past read touched the library record")
  assert(api.calls[1].read_id == 10 and api.calls[1].fields.edition_id == 8)
  assert(api.records[7].edition_id == 7, "the library record's edition changed")
end)

r.finish()
