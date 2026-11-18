--[[--
The page-number editor under Set current page (issue #317): the nested input dialog is titled
"Edition page", opens on the numeric keyboard, and the first digit typed replaces the value
instead of appending to it.

Screens: set_page_stepper, set_page_dialog.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top()
  for i = #UIManager._window_stack, 1, -1 do
    local w = UIManager._window_stack[i].widget
    if w and not (w.toast or w.snackbar or w.name == "VirtualKeyboard") then return w end
  end
end

local function tap_exact(emu, label)
  emu:screenNodes()
  local node
  for _, n in ipairs(emu:screenNodes()) do
    if n.text == label and n.x then node = n end
  end
  assert(node, "no button labelled exactly '" .. label .. "':\n" .. emu:screenText())
  emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
  emu:pump()
end

return {
  name = "set_page_dialog",

  run = function(emu)
    local settings = {
      bookLinked = function() return true end,
      getLinkedTitle = function() return "The Dispossessed" end,
      getLinkedBookId = function() return 328491 end,
      getLinkedEditionId = function() return nil end,
      getLinkedEditionFormat = function() return nil end,
      pages = function() return 322 end,
      syncEnabled = function() return false end,
      setSync = function() end,
      readSetting = function() return nil end,
    }
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      ui = { document = { file = "/books/x.epub", getPageCount = function() return 322 end },
        getCurrentPage = function() return 50 end },
      state = { book_status = { id = 1, status_id = 2, user_book_reads = { { progress_pages = 50 } } } },
      cache = { cacheUserBook = function() end },
      sync_queue = { pendingCount = function() return 0 end, changeCount = function() return 0 end,
        hasPending = function() return false end, get = function() return nil end,
        statusOf = function() return nil end, shelfOp = function() return nil end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
        statusText = function() return "Signed in" end },
      dialog_manager = {}, hardcover = {},
    })
    menu.page_mapper = {
      getMappedPage = function(_, page) return page end,
      getUnmappedPage = function(_, page) return page end,
    }
    local saved
    menu.savePage = function(_, _read, edition_page) saved = edition_page end

    local item
    for _, it in ipairs(menu:getStatusSubMenuItems()) do
      if it.text_func then
        local ok, text = pcall(it.text_func)
        if ok and tostring(text):find("Update page", 1, true) then item = it end
      end
    end
    assert(item, "no Update page item in the status menu")
    item.callback({ updateItems = function() end })
    emu:pump()
    emu:expectText("Set current page")
    emu:expectText("Edition page: was 50")
    emu:expectText("Local page")
    emu:shot("set_page_stepper")

    -- tap the edition value (the first of the two value boxes): the nested editor opens
    emu:screenNodes()
    local boxes = {}
    local function collect(root, seen)
      if type(root) ~= "table" or seen[root] then return end
      seen[root] = true
      if root.text == "value" and root.callback and root.dimen and root.dimen.x then
        boxes[#boxes + 1] = root
      end
      for _, child in pairs(root) do collect(child, seen) end
    end
    collect(top(), {})
    table.sort(boxes, function(a, b) return a.dimen.y < b.dimen.y end)
    local box = boxes[1]
    assert(box, "the value box is not painted")
    emu:tapExpecting(box.dimen.x + math.floor(box.dimen.w / 2), box.dimen.y + math.floor(box.dimen.h / 2))
    emu:pump()
    local editor
    for _, w in ipairs(UIManager._window_stack) do
      if w.widget.name == "hardcover_input_dialog" then editor = w.widget end
    end
    assert(editor, "tapping the value opened no editor")
    assert(editor:getInputText() == "50", "the editor did not open on the current value")
    assert(editor._input_widget.keyboard.keyboard_layer == 4, "the editor is not on the numeric keyboard")
    -- the PNG draws the whole stack: the dialog above the numeric keyboard
    emu:shot("set_page_dialog")
    -- with the keyboard up it is the top window, so bring it down to read the dialog's words
    editor:onCloseKeyboard()
    emu:pump()
    emu:expectText("Edition page: was 50")

    -- typing replaces the value, as a selected value would; it does not append
    editor._input_widget:addChars("60")
    emu:pump()
    assert(editor:getInputText() == "60", "typing appended to the value: " .. editor:getInputText())
    tap_exact(emu, "Set")
    emu:expectText("60")
    tap_exact(emu, "Set page")
    assert(saved == 60, "Set page did not save the typed page: " .. tostring(saved))
    emu:closeAll()
  end,
}
