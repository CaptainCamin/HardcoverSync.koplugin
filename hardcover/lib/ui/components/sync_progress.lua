-- Sync progress: a thin bar along the bottom edge while queued changes are being sent, so a sync
-- never interrupts reading. It is a toast (the page keeps working: a tap outside goes through, Back
-- is not taken), it has no timeout and no buttons, and it is updated in place as each entry is
-- verified and sent. The flush closes it; the "Progress synced" / "Sync failed" snackbar then shows
-- as usual. Static, no animation.
--
--   local progress = SyncProgress.show { total = 12 }
--   progress:update { phase = "verify", title = "Dune", kind = "page" }  -- "Verifying page for Dune…"
--   progress:update { phase = "send" }                                    -- "Syncing 3 of 12…"
--   progress:close()
--
-- The queue flushes report { phase = "verify" | "send", title, kind }; `kind` is a plain word
-- ("page", "status", "rating", "review", "list") this module translates. A "send" event counts one
-- entry: the bar fills and the line reads "Syncing N of M". A "verify" event shows what is being
-- checked against Hardcover (the slow part) without moving the count.

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local T = require("ffi/util").template

local Overlay = require("hardcover/lib/ui/components/overlay")
local ProgressBar = require("hardcover/lib/ui/components/progress_bar")
local Theme = require("hardcover/lib/ui/theme")

local SyncProgress = {}
SyncProgress.__index = SyncProgress

-- What a "verify" event's kind is called in the line.
local KINDS = {
  page = _("page"),
  status = _("status"),
  rating = _("rating"),
  review = _("review"),
  list = _("list"),
}

-- A title is a hint, not the point: keep the line to one row whatever the book is called.
local function short(title)
  title = tostring(title)
  if #title > 48 then return title:sub(1, 45) .. "\u{2026}" end
  return title
end

function SyncProgress:_text()
  if self.phase == "verify" then
    if self.title then
      local kind = self.kind and KINDS[self.kind] or _("entry")
      return T(_("Verifying %1 for %2"), kind, short(self.title))
    end
    return T(_("Verifying entry %1 of %2"), math.min(self.current + 1, math.max(self.total, 1)),
      math.max(self.total, 1))
  end
  if self.total > 0 then
    return T(_("Syncing %1 of %2"), math.min(self.current, self.total), self.total)
  end
  return _("Syncing\u{2026}")
end

function SyncProgress:_fraction()
  if self.total <= 0 then return 0 end
  return math.max(0, math.min(1, self.current / self.total))
end

-- Build the bar and put it up, replacing the previous one without a second refresh of the box.
function SyncProgress:_show()
  local old = self.overlay
  local sw = Device.screen:getWidth()
  local side = Theme.space.m
  local w = sw - 2 * side
  local face, bold = Theme.mmdFace("strong", Theme.type.title)
  -- one fixed-height row of text, clipped with an ellipsis, so an update never reflows the bar
  local line_h = math.ceil(face.size * 1.3)
  local text = TextBoxWidget:new {
    text = self:_text(), face = face, bold = bold, width = w,
    height = line_h, height_adjust = false, height_overflow_show_ellipsis = true,
    fgcolor = Theme.BLACK,
  }
  local bar = ProgressBar.new { width = w, fraction = self:_fraction() }
  -- the text and the bar share the same side inset, so they line up
  local body = FrameContainer:new { width = sw, bordersize = 0, padding = 0, margin = 0,
    background = Theme.WHITE,
    VerticalGroup:new { align = "left", Overlay.top_rule(sw), Theme.span("s"),
      HorizontalGroup:new { Theme.hspan("m"), text, Theme.hspan("m") },
      Theme.span("xs"),
      HorizontalGroup:new { Theme.hspan("m"), bar, Theme.hspan("m") },
      Theme.span("s") } }

  local overlay = Overlay:new { anchor = "bottom", toast = true, body }
  overlay:show()
  self.overlay = overlay
  if old then old:close(overlay) end
end

function SyncProgress.show(opts)
  local self = setmetatable({
    total = (opts and opts.total) or 0,
    current = 0,
    phase = nil,
    title = nil,
    kind = nil,
  }, SyncProgress)
  self:_show()
  return self
end

-- opts { phase, title, kind }: what changed; the rest stays. Nothing is drawn after close().
function SyncProgress:update(event)
  if self.closed or not event then return end
  if event.phase then self.phase = event.phase end
  if event.title ~= nil then self.title = event.title end
  if event.kind ~= nil then self.kind = event.kind end
  if event.phase == "send" then self.current = self.current + 1 end
  self:_show()
end

function SyncProgress:close()
  if self.closed then return end
  self.closed = true
  if self.overlay then self.overlay:close() end
end

return SyncProgress
