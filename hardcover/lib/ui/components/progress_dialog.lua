-- Progress dialog (MMD Dialog with a body): what a long job shows while it runs. A heading that says
-- what is being done, one line of where it has got to, a progress bar when the total is known, and a
-- visible Stop. It is locked (a tap outside does nothing); the job closes it. Stop is acknowledged
-- on screen: the dialog says it is stopping and loses its button until the job has finished.
--
--   local progress = ProgressDialog.show { title, text, fraction (0 to 1, or nil), stop = { label, callback } }
--   progress:update { text = "3 of 10", fraction = 0.3 }
--   progress:close()

local Dialog = require("hardcover/lib/ui/components/dialog")
local ProgressBar = require("hardcover/lib/ui/components/progress_bar")

local ProgressDialog = {}
ProgressDialog.__index = ProgressDialog

local _ = require("gettext")

function ProgressDialog:_show()
  if self.overlay then self.overlay:close() end
  local o = self.opts
  local buttons
  if o.stop and not self.stopping then
    buttons = { { label = o.stop.label or _("Stop"), callback = function()
      self.stopping = true
      if o.stop.callback then o.stop.callback() end
      self:_show()
    end } }
  end
  self.overlay = Dialog.show {
    title = o.title,
    text = self.stopping and _("Stopping\u{2026}") or o.text,
    body = o.fraction and ProgressBar.new { width = Dialog.innerWidth(), fraction = o.fraction } or nil,
    buttons = buttons,
    locked = true,
  }
end

function ProgressDialog.show(opts)
  local self = setmetatable({ opts = opts }, ProgressDialog)
  self:_show()
  return self
end

-- opts { title, text, fraction }: what changed; the rest stays. Nothing is drawn after close().
function ProgressDialog:update(opts)
  if self.closed then return end
  for k, v in pairs(opts) do self.opts[k] = v end
  self:_show()
end

function ProgressDialog:close()
  if self.closed then return end
  self.closed = true
  if self.overlay then self.overlay:close() end
end

return ProgressDialog
