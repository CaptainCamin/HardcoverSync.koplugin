-- The unsent reading actions for one book, in recording order. Status transitions are never
-- coalesced; page turns coalesce only on the same day with no intervening status or sync.
-- The old page/status fields remain a projection for the reader, shelves and conflict screens.
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local Actions = {}

local function append(entry, action)
  entry.action_seq = (entry.action_seq or 0) + 1
  action.seq = entry.action_seq
  entry.actions[#entry.actions + 1] = action
  return action
end

-- Old queues only know the last status and (sometimes) that a start preceded it. Recover only
-- those known actions. Their timestamp tie rules are the ones the old sync used.
function Actions.list(entry)
  if entry.actions then return entry.actions end
  entry.actions = {}
  local old = {}
  if entry.passed_reading and entry.status_id ~= nil then
    append(entry, { kind = "status", value = HARDCOVER.STATUS.READING,
      at = entry.passed_reading_at or entry.status_updated_at })
  end
  if entry.status_id ~= nil then
    old[#old + 1] = { kind = "status", value = entry.status_id,
      at = entry.status_updated_at, finished_date = entry.finished_date }
  end
  if entry.mapped_page ~= nil then
    local days = type(entry.page_days) == "table" and #entry.page_days > 0 and entry.page_days
      or { { page = entry.mapped_page, at = entry.page_updated_at } }
    for _, day in ipairs(days) do
      old[#old + 1] = { kind = "page", value = day.page, at = day.at, day = day.day,
        reread = entry.reread, force = entry.force_page, started_at = entry.started_at or entry.first_page_date }
    end
  end
  table.sort(old, function(a, b)
    if entry.reread and entry.status_id == HARDCOVER.STATUS.FINISHED and a.kind ~= b.kind then
      return a.kind == "status"
    end
    if (a.at or 0) ~= (b.at or 0) then return (a.at or 0) < (b.at or 0) end
    if a.kind == b.kind then return false end
    local status_first = entry.status_id == HARDCOVER.STATUS.READING or entry.status_id == HARDCOVER.STATUS.TO_READ
    return (a.kind == "status") == status_first
  end)
  local reread_started = false
  for _, action in ipairs(old) do
    -- A legacy reread page already means "open another read". Make that known boundary
    -- explicit so replay and cancellation see the same dependency as a newly queued reread.
    if action.kind == "page" and action.reread and not reread_started then
      append(entry, { kind = "status", value = HARDCOVER.STATUS.READING,
        at = action.at, reread = true, from_page = true })
      reread_started = true
    elseif action.kind == "status" and action.value == HARDCOVER.STATUS.READING then
      reread_started = true
    end
    append(entry, action)
  end
  entry.passed_reading, entry.passed_reading_at = nil, nil
  return entry.actions
end

function Actions.refresh(entry)
  local actions = Actions.list(entry)
  entry.status_id, entry.status_updated_at, entry.finished_date = nil, nil, nil
  entry.mapped_page, entry.page_updated_at, entry.page_days = nil, nil, nil
  entry.reread, entry.force_page = nil, nil
  local days = {}
  for _, action in ipairs(actions) do
    if action.kind == "status" then
      entry.status_id, entry.status_updated_at, entry.finished_date = action.value, action.at, action.finished_date
      if action.reread then
        entry.reread = true
      elseif action.value == HARDCOVER.STATUS.FINISHED or action.value == HARDCOVER.STATUS.DNF
        or action.value == HARDCOVER.STATUS.TO_READ then
        entry.reread = nil
      end
    else
      entry.mapped_page, entry.page_updated_at = action.value, action.at
      entry.force_page = action.force
      if action.reread then entry.reread = true end
      days[#days + 1] = { day = action.day, page = action.value, at = action.at, seq = action.seq }
    end
  end
  if #days > 0 then entry.page_days = days end
end

function Actions.status(entry, status, at, finished_date, reread)
  Actions.list(entry)
  local action = append(entry, { kind = "status", value = status, at = at,
    finished_date = finished_date, reread = reread })
  Actions.refresh(entry)
  return action
end

function Actions.page(entry, page, at, reread, force)
  local actions = Actions.list(entry)
  local day = os.date("%Y-%m-%d", at)
  local last = actions[#actions]
  -- A request in flight owns its snapshot; a page recorded meanwhile is another action even
  -- if its value and timestamp are identical. Acknowledging the snapshot must not erase it.
  if last and last.kind == "page" and last.day == day and last.seq ~= entry.sending_seq
    and not Actions.started(last) then
    force = force or last.force
    table.remove(actions)
  end
  local action = append(entry, { kind = "page", value = page, at = at, day = day,
    reread = reread, force = force, started_at = entry.started_at or entry.first_page_date or day })
  Actions.refresh(entry)
  return action
end

-- Acknowledgements and cancellation use identities, not values or timestamps: repeated actions
-- within the same second remain distinct. Only remove from the very entry the request used.
function Actions.ack(entry, seq)
  for i, action in ipairs(Actions.list(entry)) do
    if action.seq == seq then
      table.remove(entry.actions, i)
      if action.kind == "status" then entry.from_status_id = action.value end
      Actions.refresh(entry)
      return true
    end
  end
  return false
end

function Actions.started(action)
  return action.status_attempt ~= nil or action.status_sent or action.page_attempt or action.applied
end

-- Journal rows and grouped pending controls must validate the same reading dependencies.
function Actions.cancel(entry, kind, seq)
  local actions = Actions.list(entry)
  local selected = {}
  for i, action in ipairs(actions) do
    if (seq ~= nil and action.seq == seq) or (seq == nil and
      (action.kind == kind or (kind == "page" and action.from_page))) then
      if Actions.started(action) then return false, "started" end
      selected[i] = true
    end
  end
  if next(selected) == nil then return false, "missing" end
  for i, action in ipairs(actions) do
    if selected[i] and action.kind == "status" then
      for j = i + 1, #actions do
        local later = actions[j]
        if not selected[j] then
          if later.reread or (action.value == HARDCOVER.STATUS.READING and later.kind == "page") then
            return false, "dependent"
          end
          if later.kind == "status" and
            (action.value ~= HARDCOVER.STATUS.READING or later.value ~= HARDCOVER.STATUS.PAUSED) then break end
        end
      end
    end
  end
  for i = #actions, 1, -1 do
    if selected[i] then table.remove(actions, i) end
  end
  Actions.refresh(entry)
  return true
end

-- A conflict belongs to one reading, not every page queued for the book. Keep later reads,
-- including their synthetic starts; old conflicts without a sequence refer to the first page.
function Actions.rejectPages(entry, seq)
  local actions = Actions.list(entry)
  local active = false
  local kept = {}
  for _, action in ipairs(actions) do
    if action.kind == "page" and (action.seq == seq or seq == nil) then active = true end
    if active and action.kind == "status" and (action.reread
      or action.value == HARDCOVER.STATUS.FINISHED or action.value == HARDCOVER.STATUS.DNF
      or action.value == HARDCOVER.STATUS.TO_READ) then
      active = false
      -- Do not restart rejection at later pages for a legacy conflict without a sequence.
      seq = false
    end
    if not active or action.kind ~= "page" then kept[#kept + 1] = action end
  end
  entry.actions = kept
  Actions.refresh(entry)
end

function Actions.statusCount(entry)
  local count = 0
  for _, action in ipairs(Actions.list(entry)) do
    if action.kind == "status" and not action.from_page then count = count + 1 end
  end
  return count
end

return Actions
