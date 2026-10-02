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
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local T = require("ffi/util").template

local Screen = Device.screen

local SignInDialog = WidgetContainer:extend {
  name = "hardcover_signin",
  auth = nil,
  device = nil,
  width = nil,
  cancelled = false,
}

function SignInDialog:init()
  self.width = Screen:getWidth() - Screen:scaleBySize(40)
  self.height = Screen:getHeight() - Screen:scaleBySize(80)

  self.title_text = TextWidget:new {
    text = _("Sign in to Hardcover"),
    face = Font:getFace("cfont", 20),
    width = self.width,
    is_title = true,
  }

  self.instructions = TextWidget:new {
    text = T(_("On a phone or computer, go to:\n%1\n\nand enter this code:\n\n%2"), self.device.verification_uri, self.device.user_code),
    face = Font:getFace("cfont", 16),
    width = self.width,
  }

  -- the code itself, large: it is the one thing the user has to transcribe
  self.code_text = TextWidget:new {
    text = self.device.user_code,
    face = Font:getFace("cfont", 32),
    width = self.width,
  }

  self.status_text = TextWidget:new {
    text = _("Waiting for approval..."),
    face = Font:getFace("smallinfofont"),
    width = self.width,
  }

  self.cancel_button = Button:new {
    text = _("Cancel"),
    width = math.floor(self.width * 0.4),
    text_font_size = 18,
    bordersize = Size.border.thin,
    callback = function()
      self:onCancel()
    end,
  }

  local content = VerticalGroup:new {
    self.title_text,
    VerticalSpan:new { width = 10 },
    self.instructions,
    VerticalSpan:new { width = 10 },
    self.code_text,
    VerticalSpan:new { width = 10 },
    self.status_text,
    VerticalSpan:new { width = 15 },
    HorizontalGroup:new { self.cancel_button },
  }

  self.content = content

  -- fullscreen white frame so the reader UI does not show through
  self.frame = FrameContainer:new {
    width = Screen:getWidth(),
    height = Screen:getHeight(),
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    CenterContainer:new {
      dimen = Screen:getSize(),
      content,
    },
  }

  self[1] = self.frame
end

function SignInDialog:onShowSignIn()
  UIManager:show(self)
  self:poll()
end

function SignInDialog:setStatus(text)
  self.status_text:setText(text)
  UIManager:setDirty(self, "ui")
end

--
-- One poll, then schedule the next. Backoff comes from the server via
-- auth:pollDelay, which honours slow_down.
--
function SignInDialog:poll()
  if self.cancelled then
    return
  end

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