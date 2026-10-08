-- Sign-in dialog for the OAuth device authorization grant.
--
-- Shows the user the code and where to enter it, then polls the token endpoint
-- on the interval Hardcover asked for. Polling is driven by UIManager:scheduleIn
-- rather than a blocking loop so KOReader stays responsive and the user can
-- back out.
--
-- The dialog does not attempt to render a QR code: that needs a QR encoder plus
-- a way to get it on screen, and the short user code is simpler to read aloud or
-- retype on a phone. verification_uri_complete is shown so a user who prefers to
-- scan can open it themselves.

local _ = require("gettext")

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Refresh = require("hardcover/lib/ui/refresh")
local Theme = require("hardcover/lib/ui/theme")

local T = require("ffi/util").template

local Screen = Device.screen

local SignInDialog = WidgetContainer:extend {
  name = "hardcover_signin",
  auth = nil,
  device = nil,
  width = nil,
  cancelled = false,
}

-- A numbered step: the number (a plain serif numeral: it is information, so no fill and no
-- border), then what to do (and, under it, the detail).
local function step(number, title, detail, width)
  local size = Screen:scaleBySize(26)
  local title_face, title_bold = Theme.serif("title")
  local square = Theme.box(size + Theme.space.m, size + Theme.space.m, TextWidget:new {
    text = tostring(number),
    face = title_face,
    bold = title_bold,
    fgcolor = Theme.BLACK,
  }, { border = 0 })
  local text_w = width - size - Theme.space.m - Theme.space.l
  local column = VerticalGroup:new {
    align = "left",
    TextBoxWidget:new { text = title, face = title_face, bold = title_bold, width = text_w },
  }
  if detail then
    table.insert(column, Theme.span("xs"))
    table.insert(column, TextBoxWidget:new {
      text = detail,
      face = Theme.face("body"),
      width = text_w,
      fgcolor = Theme.DARK_GREY,
    })
  end
  return HorizontalGroup:new { align = "top", square, Theme.hspan("l"), column }
end

function SignInDialog:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local width = screen_w - 2 * M
  self.width = screen_w
  self.height = screen_h
  self.started_at = os.time()

  -- the family's title bar; its X is Cancel too
  self.title_bar = Theme.titleBar {
    title = _("Sign in to Hardcover"),
    close_callback = function() self:onCancel() end,
    show_parent = self,
  }
  self.title_text = self.title_bar

  -- the code itself, large between two firm rules: it is the one thing the
  -- user has to transcribe
  self.code_text = TextWidget:new {
    text = self.device.user_code,
    face = Theme.face(60),
    bold = true,
    max_width = width,
    fgcolor = Theme.BLACK,
  }
  local code_h = self.code_text:getSize().h + 2 * Theme.space.m
  local code_block = VerticalGroup:new {
    align = "left",
    Theme.rule(width, true),
    CenterContainer:new { dimen = Geom:new { w = width, h = code_h }, self.code_text },
    Theme.rule(width, true),
  }

  -- the wait: how far through the code's life we are (it only moves when the
  -- poll finds a visible step; nothing animates), what is happening, and how
  -- long the code lasts
  self.wait_bar = Theme.progress {
    width = width,
    height = Screen:scaleBySize(14),
    percentage = 0,
    ticks = nil,
    last = nil,
  }
  self.status_text = TextWidget:new {
    text = _("Waiting for approval..."),
    face = Theme.face("small"),
    max_width = math.floor(width * 0.6),
    fgcolor = Theme.DARK_GREY,
  }
  local lifetime = tonumber(self.device.expires_in)
  local lifetime_text = TextWidget:new {
    text = lifetime and T(_("Code valid for %1 min"), math.max(1, math.floor(lifetime / 60 + 0.5))) or " ",
    face = Theme.face("small"),
    bold = true,
    max_width = math.floor(width * 0.4),
  }
  local status_gap = math.max(0, width - self.status_text:getSize().w - lifetime_text:getSize().w)
  local status_line = HorizontalGroup:new {
    align = "center", self.status_text, Theme.hspan(status_gap), lifetime_text,
  }

  self.cancel_button = Theme.button(_("Cancel"), width, {
    h = Theme.BUTTON_H,
    callback = function()
      self:onCancel()
    end,
  })

  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("l"))
  table.insert(content, step(1, _("Open this page on any device"), self.device.verification_uri, width))
  table.insert(content, Theme.span("l"))
  table.insert(content, step(2, _("Enter this code"), nil, width))
  table.insert(content, Theme.span("m"))
  table.insert(content, code_block)
  table.insert(content, Theme.span("l"))
  table.insert(content, step(3, _("Approve the request"),
    _("This screen carries on by itself once you have approved."), width))
  table.insert(content, Theme.span("xl"))
  table.insert(content, self.wait_bar)
  table.insert(content, Theme.span("s"))
  table.insert(content, status_line)
  content:resetLayout()
  self.content = content

  -- Cancel sits at the bottom of the screen, whatever is above it
  local room = screen_h - self.title_bar:getSize().h - content:getSize().h
    - Theme.BUTTON_H - 2 * Theme.space.l
  local bottom = VerticalGroup:new {
    align = "left",
    content,
    Theme.span(math.max(Theme.space.m, room)),
    self.cancel_button,
  }

  -- fullscreen white frame so the reader UI does not show through
  self.frame = FrameContainer:new {
    width = screen_w,
    height = screen_h,
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new {
      align = "left",
      self.title_bar,
      HorizontalGroup:new { Theme.hspan(M), bottom },
    },
  }

  self[1] = self.frame
end

-- The bar and the line of words under it: the only parts of this screen that ever
-- change while it waits. Read after a paint, when their positions are known.
function SignInDialog:waitRegion()
  local bar = self.wait_bar and self.wait_bar.dimen
  if not Refresh.valid(bar) then return nil end
  -- the status line sits under the bar, a small gap below it
  local below = Theme.space.s + (self.status_text and self.status_text:getSize().h or 0)
  return { x = bar.x, y = bar.y, w = bar.w, h = bar.h + below }
end

-- Move the waiting bar to how much of the code's life has passed, but only in
-- steps of a twentieth: a redraw every few seconds for no visible change is the
-- thing to avoid on e-ink, and when it does move only the bar is redrawn, not
-- the whole screen (this screen sits open for minutes).
function SignInDialog:updateWait()
  local lifetime = tonumber(self.device and self.device.expires_in)
  if not (lifetime and lifetime > 0 and self.wait_bar) then return end
  local fraction = math.min(1, math.max(0, (os.time() - self.started_at) / lifetime))
  local step_size = math.floor(fraction * 20) / 20
  if step_size ~= self.wait_bar.percentage then
    self.wait_bar:setPercentage(step_size)
    Refresh.region(self, function() return self:waitRegion() end)
  end
end

-- show() queues no refresh of its own and relies on a fallback that a small
-- refresh queued in the same tick would suppress: ask for the first full draw.
function SignInDialog:onShow()
  UIManager:setDirty(self, "ui")
end

function SignInDialog:onShowSignIn()
  UIManager:show(self)
  self:poll()
end

function SignInDialog:setStatus(text)
  self.status_text:setText(text)
  Refresh.region(self, function() return self:waitRegion() end)
end

--
-- One poll, then schedule the next. Backoff comes from the server via
-- auth:pollDelay, which honours slow_down.
--
function SignInDialog:poll()
  if self.cancelled then
    return
  end

  self:updateWait()

  local outcome = self.auth:pollOnce()

  if outcome == "success" then
    self:onSuccess()
    return
  end

  if outcome == "denied" then
    self:onFinish(_("Sign in was declined."))
    return
  end

  if outcome == "expired" then
    self:onFinish(_("The code expired. Please try signing in again."))
    return
  end

  if outcome == "error" then
    self:onFinish(_("Could not sign in. Please try again."))
    return
  end

  local delay = self.auth:pollDelay(outcome)
  UIManager:scheduleIn(delay, self.poll, self)
end

-- See BookDetailDialog:onCloseWidget: close() queues no refresh by itself, and
-- WidgetContainer does not either, so every way out of this dialog (success,
-- declined, expired, cancelled) left the code on screen.
function SignInDialog:onCloseWidget()
  UIManager:setDirty(nil, "ui")
end

function SignInDialog:onSuccess()
  self.cancelled = true
  UIManager:close(self)

  UIManager:show(InfoMessage:new {
    text = _("Signed in to Hardcover"),
    timeout = 2,
  })

  if self.success_callback then
    self.success_callback()
  end
end

function SignInDialog:onFinish(message)
  self.cancelled = true
  UIManager:close(self)

  UIManager:show(InfoMessage:new {
    text = message,
    icon = "notice-warning",
    timeout = 3,
  })

  if self.close_callback then
    self.close_callback()
  end
end

function SignInDialog:onCancel()
  -- stop polling; the device code simply expires server side
  self.cancelled = true
  UIManager:close(self)

  if self.close_callback then
    self.close_callback()
  end
end

return SignInDialog