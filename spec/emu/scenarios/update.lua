--[[--
Updates, from the settings screen: "Check for updates" asks GitHub, says when a
newer release exists (with its notes), and the row remembers it afterwards.
GitHub is stubbed here; the install itself is covered by spec/updater_harness.lua.
]]

local fixtures = require("fixtures")

return {
  name = "update",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local Github = require("hardcover/lib/github")
    local answer
    Github.latestReleaseAsync = function(_, cb) cb(answer) end

    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
    })
    local function find(text_prefix)
      for _, item in ipairs(menu:getHomeSettingsItems()) do
        local text = item.text or (item.text_func and item.text_func())
        if text and text:find(text_prefix, 1, true) == 1 then return item, text end
      end
    end

    local item = assert(find("Check for updates"), "no update row")
    assert(find("Check for updates automatically"), "no automatic-check tick")

    answer = nil
    item.callback({ updateItems = function() end })
    emu:pump()
    emu:expectText("Couldn't reach GitHub")
    emu:closeAll()

    answer = { tag = "v99.0.0", version = "99.0.0", notes = "Everything is better.", zip_url = "https://example/x.zip" }
    item.callback({ updateItems = function() end })
    emu:pump()
    emu:expectText("Version 99.0.0 is available")
    local short = emu.UIManager:getTopmostVisibleWidget()
    assert(short.notes.html_body:find("Everything is better.", 1, true))
    local fixed_w, fixed_h = short.region.w, short.region.h
    emu:shot("update")
    emu:closeAll()

    local rich_notes = "## Improvements\n\n**Readable** notes with *emphasis*, `code`, and [a link](https://example.com).\n\n"
      .. string.rep("- A complete change with enough explanation to wrap onto another line.\n", 50)
      .. "\nThe final change is here."
    local installed
    menu.installUpdate = function(_, release) installed = release end
    local release = { version = "99.0.0", notes = rich_notes, zip_url = "https://example/x.zip" }
    menu:showRelease(release)
    emu:pump()
    local long = emu.UIManager:getTopmostVisibleWidget()
    assert(long.region.w == fixed_w and long.region.h == fixed_h, "notes changed the dialog size")
    local html = long.notes.html_body
    for _, markup in ipairs({ "<h2>", "<strong>", "<em>", "<code>", "<ul>", "<a href=", "The final change is here." }) do
      assert(html:find(markup, 1, true), "Markdown lost " .. markup)
    end
    assert(long.notes.htmlbox_widget.page_count > 1, "long notes do not scroll")
    emu:shot("update_markdown")
    long.notes:scrollText(1)
    emu:pump()
    assert(long.notes.htmlbox_widget.page_number == 2, "scroll did not advance")
    long.notes:scrollToRatio(1)
    emu:pump()
    assert(long.notes.htmlbox_widget.page_number == long.notes.htmlbox_widget.page_count, "the end is unreachable")
    emu:expectText("Install")
    emu:expectText("Later")
    emu:shot("update_markdown_end")
    local install = emu:expectText("Install")
    emu:tapExpecting(install.x + math.floor(install.w / 2), install.y + math.floor(install.h / 2))
    assert(installed == release, "Install lost its release")
    assert(not emu.UIManager:isWidgetShown(long), "Install left the notes open")
    menu:showRelease { version = "99.0.0" }
    emu:pump()
    local empty = emu.UIManager:getTopmostVisibleWidget()
    assert(empty.notes.html_body:find("No release notes provided.", 1, true))
    emu:expectText("OK")
    local later = emu:expectText("Later")
    emu:tapExpecting(later.x + math.floor(later.w / 2), later.y + math.floor(later.h / 2))
    assert(not emu.UIManager:isWidgetShown(empty), "Later did not close the notes")

    local _, text = find("Update available")
    assert(text == "Update available: v99.0.0", tostring(text))

    answer = { tag = "v0.0.1" }
    find("Update available").callback({ updateItems = function() end })
    emu:pump()
    emu:expectText("is up to date")
    emu:closeAll()
    assert(find("Check for updates"), "the row did not go back after an up-to-date answer")
  end,
}
