local UIManager = require("ui/uimanager")
local logger = require("logger")

local Scheduler = {
  retries = {}
}

-- Cancel every retry loop that is still going (on suspend, or when the connection drops):
-- the pending timer is unscheduled, and a request already in flight that then fails does
-- not schedule another attempt.
function Scheduler:clear()
  for job, cancel in pairs(self.retries) do
    cancel()
    self.retries[job] = nil
  end
end

function Scheduler:withRetries(limit, time_exponent, callback, success_callback, fail_callback)
  time_exponent = time_exponent or 2

  local scheduled_job
  local cancelled = false

  local tries = 0

  -- a loop that has ended, one way or another, is no longer something to clear
  local finish = function()
    self.retries[scheduled_job] = nil
  end

  local success = function()
    finish()
    if success_callback then
      success_callback()
    end
  end

  local fail = function()
    -- cleared while this attempt was in flight: do not start another
    if cancelled then return end

    tries = tries + 1

    if tries < limit then
      UIManager:scheduleIn(2 ^ (time_exponent + tries), scheduled_job)
    else
      finish()
      if fail_callback then
        fail_callback()
      end
    end
  end

  scheduled_job = function()
    callback(success, fail)
  end

  local cancel = function()
    cancelled = true
    UIManager:unschedule(scheduled_job)
    finish()
  end

  -- keyed by the job so clear() can find and cancel it
  self.retries[scheduled_job] = cancel

  UIManager:nextTick(scheduled_job)

  return cancel
end

return Scheduler
