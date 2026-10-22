-- Visual proposal only: real KOReader widgets, without changing the reader panel.
local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Geom = require("ui/geometry")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local IconWidget = require("ui/widget/iconwidget")
local Theme = require("hardcover/lib/ui/theme")
local Button = require("hardcover/lib/ui/components/button")
local Overlay = require("hardcover/lib/ui/components/overlay")
local TapRow = require("hardcover/lib/ui/tap_row")

local function preview(emu, state)
    local sw = Device.screen:getWidth()
    local margin, gap = Theme.px(20), Theme.space.m
    local width = sw - 2 * margin
    local cw, ch = Theme.px(56), Theme.px(84)
    local tw = width - cw - gap
    local target = Theme.TOUCH_MIN
    local control_gap = Theme.space.xs
    local title_w = tw - 2 * target - control_gap
    local panel
    local function close() UIManager:close(panel) end
    local function icon_control(icon, callback)
        return TapRow:new {
            callback = callback, dimen = Geom:new { w = target, h = target },
            CenterContainer:new { dimen = Geom:new { w = target, h = target },
                Theme.icon(icon, Theme.px(24)) },
        }
    end
    local title = Theme.mmdText("The Dispossessed", "strong", 25, { width = title_w })
    local title_row = HorizontalGroup:new { align = "center", title,
        Theme.hspan(math.max(0, title_w - title:getSize().w)),
        icon_control("settings", function() end), Theme.hspan(control_gap),
        icon_control("close", close) }
    local status = Theme.mmdText(state.status, "strong", 19, { width = tw - Theme.px(84) })
    local rating = state.rating and HorizontalGroup:new { align = "center",
        Theme.icon("star-filled", Theme.px(22)), Theme.hspan("xs"),
        Theme.mmdText(state.rating, "strong", 20) }
        or Theme.mmdText("Not rated", "text", 18, { secondary = true })
    local status_row = HorizontalGroup:new { align = "center", status,
        Theme.hspan(math.max(0, tw - status:getSize().w - rating:getSize().w)), rating }
    local book_text = VerticalGroup:new { align = "left",
        title_row, Theme.span("xs"), status_row, Theme.span("xs"),
        Theme.mmdText(state.line, "text", 18, { secondary = true, width = tw }) }
    if state.progress then
        table.insert(book_text, Theme.span("xs"))
        table.insert(book_text, Theme.progress { width = tw, height = Theme.px(12),
            percentage = state.progress })
    end
    local root = package.searchpath("hardcover/lib/shelf", package.path):match("^(.*)/hardcover/lib/shelf%.lua$")
    local cover = IconWidget:new { file = root .. "/spec/emu/fixtures/cover.png",
        width = cw, height = ch, alpha = false }
    local content = VerticalGroup:new { align = "left", Theme.span("m"),
        HorizontalGroup:new { align = "top", cover, Theme.hspan(gap), book_text } }
    if state.message then
        table.insert(content, Theme.span("m"))
        local pad, button_w = Theme.space.m, Theme.px(142)
        local label_w = width - 2 * pad - button_w - gap
        local label = Theme.mmdText(state.message, "text", 20, { width = label_w })
        local row = HorizontalGroup:new { align = "center", label,
            Theme.hspan(width - 2 * pad - label:getSize().w - button_w),
            Button.new { label = state.action, w = button_w, h = target,
                callback = function() end } }
        table.insert(content, Theme.box(width, Theme.px(82), row, { radius = 12, dotted = true }))
    end
    table.insert(content, Theme.span("l"))
    local actions = {
        { "Progress", "sync", state.key == "reading" },
        { "Status", "shelf", true },
        { "Rate", "star", state.key ~= "no_shelf" },
        { "Journal", "edit", state.key ~= "no_shelf" },
        { "Details", "book-open", true },
    }
    local row = HorizontalGroup:new { align = "top" }
    local cell = math.floor(width / #actions)
    for _, action in ipairs(actions) do
        table.insert(row, CenterContainer:new {
            dimen = Geom:new { w = cell, h = Theme.mmd.round_button.size.large + Theme.px(36) },
            Button.round { icon = action[2], label = action[1], scale = "large",
                enabled = action[3], callback = function() end },
        })
    end
    table.insert(content, row)
    table.insert(content, Theme.span("m"))
    local sheet = FrameContainer:new { background = Theme.WHITE, bordersize = 0,
        padding = 0, margin = 0,
        VerticalGroup:new { align = "left", Overlay.top_rule(sw),
            HorizontalGroup:new { Theme.hspan(margin), content, Theme.hspan(margin) } } }
    panel = Overlay:new { anchor = "bottom", sheet }
    UIManager:show(panel)
    emu:pump()
    emu:expectText("The Dispossessed")
    for _, label in ipairs({ "Progress", "Status", "Rate", "Journal", "Details" }) do
        emu:expectText(label)
    end
    emu:shot("reader_panel_top_controls_" .. state.key)
    emu:closeAll()
end

return {
    name = "reader_panel_top_controls_preview",
    run = function(emu)
        fixtures.install({ settings = fixtures.real_settings(emu) })
        for _, state in ipairs({
            { key = "read", status = "Read", rating = "4", line = "Page 387 of 387 · 100%",
                progress = 1, message = "You finished this book.", action = "Read again" },
            { key = "reading", status = "Currently Reading", rating = "4.5",
                line = "Page 120 of 387 · 31%", progress = 120 / 387 },
            { key = "want_to_read", status = "Want to Read", line = "387 pages",
                message = "Ready to start this book?", action = "Start reading" },
            { key = "no_shelf", status = "Not on a shelf", line = "387 pages",
                message = "This book isn't on a shelf yet.", action = "Add to shelf" },
        }) do preview(emu, state) end
    end,
}
