-- Release notes keep one window size whether a release has one line or many pages.
-- MuPDF renders the Markdown as HTML; the title and install actions stay outside
-- its scrolling viewport, so the entire changelog remains readable.
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local T = require("ffi/util").template

local Dialog = require("hardcover/lib/ui/components/dialog")
local Overlay = require("hardcover/lib/ui/components/overlay")
local Theme = require("hardcover/lib/ui/theme")
local markdown = require("hardcover/vendor/markdown")

local ReleaseDialog = {}

function ReleaseDialog.show(opts)
  local release = opts.release
  local width = Dialog.width()
  local height = math.floor(Device.screen:getHeight() * 0.8)
  local pad, border, gap = Theme.space.m, Theme.line.firm, Theme.space.s
  local inner = width - 2 * (pad + border)
  local face, bold = Theme.mmdFace("strong", Theme.type.display)
  local title = TextBoxWidget:new {
    text = T(_("Version %1 is available"), release.version),
    face = face, bold = bold, width = inner, fgcolor = Theme.BLACK,
  }
  local current = TextBoxWidget:new {
    text = T(_("You have v%1."), opts.current_version),
    face = Theme.mmdFace("text", Theme.type.body), width = inner, fgcolor = Theme.BLACK,
  }
  local overlay
  local function close() overlay:close() end
  local buttons = Dialog.buttonRow({
    { label = release.zip_url and _("Install") or _("OK"), primary = true,
      callback = function() if release.zip_url and opts.on_install then opts.on_install() end end },
    { label = _("Later") },
  }, inner, gap, function(spec)
    close()
    if spec.callback then spec.callback() end
  end)
  local body_height = height - 2 * (pad + border) - title:getSize().h
    - current:getSize().h - buttons:getSize().h - 3 * gap
  local notes = release.notes and release.notes ~= "" and release.notes or _("No release notes provided.")
  local viewer = ScrollHtmlWidget:new {
    width = inner, height = body_height,
    html_body = markdown(notes),
    default_font_size = Theme.px(Theme.type.title),
    css = [[
      @page { margin: 0; }
      html, body { margin: 0; padding: 0; }
      body { font-family: sans-serif; color: black; background: white; line-height: 1.35; }
      p, ul, ol, pre, blockquote { margin: 0 0 0.7em; }
      h1, h2, h3, h4, h5, h6 { font-family: sans-serif; margin: 0.6em 0 0.3em; }
      h1 { font-size: 1.4em; } h2 { font-size: 1.25em; } h3 { font-size: 1.1em; }
      ul, ol { padding-left: 1.5em; } li { margin-bottom: 0.25em; }
      pre, code { font-family: monospace; } pre { white-space: pre-wrap; }
      a { color: black; text-decoration: underline; }
      blockquote { border-left: 0.15em solid black; padding-left: 0.6em; }
    ]],
  }
  local content = VerticalGroup:new { align = "left", title, Theme.span(gap) }
  content[#content + 1] = current
  content[#content + 1] = Theme.span(gap)
  content[#content + 1] = viewer
  content[#content + 1] = Theme.span(gap)
  content[#content + 1] = buttons
  local box = FrameContainer:new {
    width = width, height = height, padding = pad, margin = 0,
    bordersize = border, radius = Dialog.RADIUS,
    color = Theme.BLACK, background = Theme.WHITE, content,
  }
  overlay = Overlay:new { anchor = "center", box }
  viewer.dialog = overlay
  overlay.notes = viewer
  return overlay:show()
end

return ReleaseDialog
