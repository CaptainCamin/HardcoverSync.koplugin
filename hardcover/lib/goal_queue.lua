-- Goal changes made while offline: a new goal, an edit, an archive. Kept in order,
-- shown at once on every screen (see apply), and sent when the connection is back.
--
-- Plain data and arithmetic, no KOReader requires, so it runs under stock Lua in the
-- spec suite. It lives in the same settings file as the progress queue (SyncQueue)
-- but is its own thing: a goal is a whole record, not a single page number, and a
-- goal made here has no id on Hardcover until it is sent, so it is known by a local
-- key ("local:1") that is swapped for the real id when it goes through.
--
-- One op per goal at a time. Editing a goal twice offline leaves one edit (the
-- newest); making a goal and then archiving it before it was ever sent leaves
-- nothing; archiving a goal drops the edits waiting for it.

local Goals = require("hardcover/lib/goals")
local Lists = require("hardcover/lib/lists")

local GoalQueue = {}
GoalQueue.__index = GoalQueue

-- An op the server refused (or that needs a permission the sign-in lacks) this many
-- flushes in a row is held: it stays, shown as waiting, until the user acts.
GoalQueue.MAX_REJECTIONS = 3

function GoalQueue:new(o)
  o = o or {}
  setmetatable(o, self)
  return o
end

function GoalQueue.isLocal(key)
  return type(key) == "string" and key:find("^local:") ~= nil
end

function GoalQueue:ops()
  local ops = self.settings:readSetting("goal_ops")
  if type(ops) ~= "table" then
    ops = {}
    self.settings:saveSetting("goal_ops", ops)
  end
  return ops
end

function GoalQueue:persist()
  if self.settings.flush then self.settings:flush() end
end

-- the ops that are well formed (a hand-edited or newer file must not break a screen)
local function valid(op)
  return type(op) == "table" and op.key ~= nil and (op.kind == "save" or op.kind == "archive")
end

function GoalQueue:count()
  local n = 0
  for _, op in ipairs(self:ops()) do
    if valid(op) then n = n + 1 end
  end
  return n
end

function GoalQueue:heldCount()
  local n = 0
  for _, op in ipairs(self:ops()) do
    if valid(op) and op.held then n = n + 1 end
  end
  return n
end

function GoalQueue:isEmpty()
  return self:count() == 0
end

function GoalQueue:find(key)
  for i, op in ipairs(self:ops()) do
    if valid(op) and op.key == key then return op, i end
  end
end

-- is a change to this goal waiting to be sent?
function GoalQueue:pendingFor(key)
  return self:find(key) ~= nil
end

local function drop(self, key)
  local ops = self:ops()
  for i = #ops, 1, -1 do
    if type(ops[i]) == "table" and ops[i].key == key then table.remove(ops, i) end
  end
end

local function copyForm(form)
  return {
    name = form.name, metric = form.metric, target = tonumber(form.target),
    start_date = form.start_date, end_date = form.end_date,
    privacy_setting_id = form.privacy_setting_id,
    conditions = form.conditions,
  }
end

-- A goal in the shape the screens use, from a form (progress as it was, 0 if new).
local function goalFrom(key, form, progress)
  local from, to = Goals.parseDate(form.start_date), Goals.parseDate(form.end_date)
  return {
    id = key,
    name = form.name,
    metric = form.metric == "page" and "page" or "book",
    target = tonumber(form.target),
    progress = progress or 0,
    start_date = form.start_date,
    end_date = form.end_date,
    start_days = from,
    end_days = to,
    privacy_setting_id = form.privacy_setting_id,
    conditions = form.conditions,
    pending = true,
  }
end

--
-- A goal made or changed here. `form` is what the form held (Goals.validate'd);
-- `form.id` is the goal's id, or nil for a new one. `base` is the goal as it was
-- (its progress is kept). Returns the goal as it now reads, to show at once.
--
function GoalQueue:queueSave(form, base)
  local key = form.id
  if key == nil then
    local n = (tonumber(self.settings:readSetting("goal_next_local")) or 0) + 1
    self.settings:saveSetting("goal_next_local", n)
    key = "local:" .. n
  end

  -- an op already waiting for this goal is replaced by the newer one; a goal that
  -- was made here and not sent yet stays a "make" however often it is edited
  drop(self, key)
  table.insert(self:ops(), { key = key, kind = "save", form = copyForm(form), at = os.time() })
  self:persist()

  return goalFrom(key, form, base and base.progress or 0)
end

-- Archive a goal. One that was made here and never sent just disappears. `goal` is
-- the goal as it stands: Hardcover wants all of it sent along with the archive flag.
function GoalQueue:queueArchive(key, goal)
  local was_local = GoalQueue.isLocal(key)
  drop(self, key)
  if not was_local then
    local form = goal and Goals.formFrom(goal) or nil
    table.insert(self:ops(), { key = key, kind = "archive", form = form and copyForm(form), at = os.time() })
  end
  self:persist()
end

--
-- `goals` (a list, as the screens hold it) with the waiting changes laid over it:
-- edits replace the goal (keeping its progress), goals made here are added, archived
-- goals are left out. Changed goals carry `pending = true`. A copy.
--
function GoalQueue:apply(goals)
  local ops = self:ops()
  local out = {}
  local by_key = {}
  for _, g in ipairs(goals or {}) do
    by_key[g.id] = true
  end

  local archived, edits = {}, {}
  for _, op in ipairs(ops) do
    if valid(op) then
      if op.kind == "archive" then archived[op.key] = true else edits[op.key] = op end
    end
  end

  for _, g in ipairs(goals or {}) do
    if not archived[g.id] then
      local op = edits[g.id]
      if op and op.form then
        out[#out + 1] = goalFrom(g.id, op.form, g.progress)
        out[#out].held = op.held or nil
      else
        out[#out + 1] = g
      end
    end
  end

  -- the goals made here, in the order they were made
  for _, op in ipairs(ops) do
    if valid(op) and op.kind == "save" and GoalQueue.isLocal(op.key) and op.form then
      out[#out + 1] = goalFrom(op.key, op.form, 0)
      out[#out].held = op.held or nil
    end
  end
  return out
end

-- Is this the kind of failure that says nothing about the change itself? (no answer,
-- a timeout, a busy or broken server.) Those are tried again later without counting.
local function transient(err)
  if err == nil then return true end
  if type(err) == "string" then return false end -- Hardcover's own words: a refusal
  if type(err) ~= "table" then return true end
  if err.completed == false or err.error == "no_response" then return true end
  local status = tonumber(err.status)
  if status == nil then return err.errors == nil end
  return status == 429 or status >= 500
end

--
-- Send what is waiting, in order. `api` needs saveGoal(id, input) and archiveGoal(goal)
-- (each returning a result, or nil and an error). opts.on_saved(key, goal) is told of
-- every goal that went through (for a new one `key` is its local key, and the real
-- id is `goal.id`); opts.on_archived(key) of every archive that did. Stops at the first failure that says the server could not be
-- asked; one it refused is counted and the rest go on. Returns
--   { sent = n, held = n, waiting = n, stopped = bool }
--
function GoalQueue:flush(api, opts)
  opts = opts or {}
  if self.flushing then return { sent = 0, held = self:heldCount(), waiting = self:count(), stopped = true } end
  self.flushing = true

  local sent, stopped = 0, false
  local snapshot = {}
  for _, op in ipairs(self:ops()) do snapshot[#snapshot + 1] = op end

  for _, op in ipairs(snapshot) do
    if valid(op) and not op.held then
      local ok, result, err = pcall(function()
        if op.kind == "archive" then
          local goal = {}
          for k, v in pairs(op.form or {}) do goal[k] = v end
          goal.id = op.key
          return api:archiveGoal(goal)
        end
        local id = (not GoalQueue.isLocal(op.key)) and op.key or nil
        return api:saveGoal(id, Goals.input(op.form))
      end)
      if not ok then result, err = nil, nil end

      if result then
        sent = sent + 1
        -- remove this op, unless a newer one for the same goal came in while the
        -- request was out (then the newer is what is left to send)
        local current = self:find(op.key)
        if current == op then drop(self, op.key) end
        if op.kind == "save" and GoalQueue.isLocal(op.key) and type(result) == "table" then
          -- the goal has its real id now: anything still waiting for the local key
          -- follows it
          for _, later in ipairs(self:ops()) do
            if type(later) == "table" and later.key == op.key then later.key = result.id end
          end
        end
        if opts.on_saved and op.kind == "save" then opts.on_saved(op.key, result) end
        if opts.on_archived and op.kind == "archive" then opts.on_archived(op.key) end
        self:persist()
      elseif transient(err) then
        stopped = true
        break
      else
        op.failures = (op.failures or 0) + 1
        if Lists.isScopeError(err) then
          op.held, op.reason = true, "scope"
        elseif op.failures >= GoalQueue.MAX_REJECTIONS then
          op.held, op.reason = true, "refused"
        end
        self:persist()
      end
    end
  end

  self.flushing = false
  return { sent = sent, held = self:heldCount(), waiting = self:count(), stopped = stopped }
end

-- Cancel the change waiting for one goal (a goal made here and not sent just goes). The
-- screens show the goal as Hardcover last said it again once this is called (see apply).
function GoalQueue:cancel(key)
  local had = self:find(key) ~= nil
  drop(self, key)
  self:persist()
  return had
end

-- Let held changes try again (after signing in again, say).
function GoalQueue:retryHeld()
  for _, op in ipairs(self:ops()) do
    if type(op) == "table" then op.held, op.failures, op.reason = nil, nil, nil end
  end
  self:persist()
end

-- Throw everything waiting away.
function GoalQueue:clear()
  local ops = self:ops()
  for i = #ops, 1, -1 do ops[i] = nil end
  self:persist()
end

return GoalQueue
