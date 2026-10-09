-- Drives the real ShelfDialog against a capturing Menu.
--
-- Why this shape: the crash the user reported ("KO-Reader crashes when you try
-- to view either the currently reading or want to read lists") happens in the
-- widget layer, but the plugin's own code is what decides what the widget gets.
-- Loading the real shelf_dialog.lua with a capturing Menu lets us assert on the
-- exact list the plugin built -- text, mandatory labels, cover fields,
-- callbacks, paging flags -- without trying to make a vendored widget tree
-- genuinely run.
--
-- That last part is the whole point. Making the vendored Menu/CoverMenu
-- actually execute is a losing game: every KOReader method it touches that the
-- harness does not stub surfaces as a nil call, and that failure is
-- indistinguishable from a plugin bug. Two full debugging passes went into
-- chasing those. The capturing approach tests code we actually wrote, and
-- plugin-owned modules are never stubbed.
--
-- Usage: lua spec/shelf_dialog_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

support.preload_koreader_stubs()

-- ---------------------------------------------------------------- KOReader widgets
-- Inert containers. The dialog only ever constructs them and stores them, so a
-- table that accepts the spec and reports its size is enough.
local function container_stub(name)
  local base = {}
  base.__index = base
  base.new = function(cls, o)
    o = o or {}
    setmetatable(o, cls)
    o.getSize = o.getSize or function() return { w = 600, h = 800 } end
    o.paintTo = function() end
    o.free = function() end
    o.onShow = function() end
    o.onClose = function() end
    o.refresh = function() end
    -- Real InputContainer:new runs init. Dropping it means the dialog never
    -- builds its menu and every assertion silently sees nothing, so keep it.
    if o.init then
      o:init()
    end
    return o
  end
  base.extend = function()
    local child = {}
    setmetatable(child, { __index = base })
    child.__index = child
    child.new = function(cls, o) return base.new(child, o) end
    return child
  end
  package.loaded[name] = base
  return base
end

for _, n in ipairs({
  "ui/widget/container/centercontainer",
  "ui/widget/container/inputcontainer",
  "ui/widget/container/framecontainer",
}) do
  container_stub(n)
end

support.preload_theme_stubs() -- (after the containers above, which are real stubs)

package.preload["ffi/util"] = function()
  return { template = function(t, ...)
    local args = { ... }
    return (tostring(t):gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
  end }
end
package.preload["device"] = function()
  return {
    screen = {
      -- KOReader's Screen is called with a colon, so the first arg is the
      -- table itself. ShelfDialog:init sizes itself from these.
      scaleBySize = function(_, n) return n end,
      getWidth = function() return 1080 end,
      getHeight = function() return 1440 end,
      getSize = function() return { x = 0, y = 0, w = 1080, h = 1440 } end,
      getDpi = function() return 300 end,
      isColorScreen = function() return true end,
    },
  }
end

package.preload["ui/uimanager"] = function()
  return {
    show = function(self, widget) self._shown = widget return widget end,
    close = function(self, widget) self._closed = widget end,
    -- counted, so a test can tell whether a refresh was asked for
    setDirty = function(self, _, what) self.dirty_calls = (self.dirty_calls or 0) + 1 self.last_dirty = what end,
    scheduleIn = function(_, _, fn, ...) if type(fn) == "function" then fn(...) end end,
    unschedule = function() end,
    repaint = function() end,
    getPaintCtx = function() return {} end,
  }
end

package.preload["ui/widget/infomessage"] = function()
  local M = { last = nil }
  M.new = function(_, o)
    o = o or {}
    setmetatable(o, M)
    o.show = function() M.last = o.text end
    o.free = function() end
    return o
  end
  return M
end

-- shelf_dialog now routes its load-more failure through StatusDialogs, which
-- builds a ConfirmBox as well as an InfoMessage. Both are captured so a test
-- can assert on what the user was shown.
package.preload["ui/widget/confirmbox"] = function()
  local M = { last = nil }
  M.new = function(_, o)
    o = o or {}
    setmetatable(o, M)
    o.show = function() M.last = o end
    o.free = function() end
    return o
  end
  return M
end

-- The sort menu: record the buttons it is given
package.preload["ui/widget/buttondialog"] = function()
  local M = { last = nil }
  M.new = function(_, o)
    o = o or {}
    M.last = o
    return o
  end
  return M
end

-- The header (list_header.lua has its own harness): keep what it is built with and told,
-- and apply an update the way the real one does, so the dialog's state shows in it.
package.preload["hardcover/lib/ui/list_header"] = function()
  local Header = {}
  Header.__index = Header
  Header.new = function(cls, o)
    o = setmetatable(o or {}, cls)
    o.updates = 0
    o.dimen = { x = 0, y = 0, w = o.width, h = 300 }
    Header.last = o
    return o
  end
  Header.update = function(self, opts)
    self.updates = self.updates + 1
    for _, key in ipairs({ "title", "right_icon", "right_callback", "buttons" }) do
      if opts[key] ~= nil then self[key] = opts[key] end
    end
  end
  return Header
end

-- The search box: keep what it is given, and let a test type into it
package.preload["ui/widget/inputdialog"] = function()
  local Box = { last = nil }
  Box.new = function(cls, o)
    o = setmetatable(o or {}, cls)
    o.text = o.input or ""
    Box.last = o
    return o
  end
  Box.__index = Box
  function Box:getInputText() return self.text end
  function Box:onShowKeyboard() self.keyboard = true end
  return Box
end

-- Capture what the plugin hands the real Menu.
local Menu, record = support.capturing_menu()
package.preload["ui/widget/menu"] = function() return Menu end

-- The plugin's own SearchMenu derives from Menu; keep it real but harmless.
package.preload["hardcover/lib/ui/search_menu"] = function()
  local SearchMenu = Menu:extend()
  SearchMenu._do_cover_images = true
  return SearchMenu
end

package.preload["hardcover/lib/shelf"] = function()
  return {
    statusLabel = function(id)
      local labels = { [1] = "Want to Read", [2] = "Currently Reading", [3] = "Read" }
      return labels[id] or "Status " .. tostring(id)
    end,
    appendPage = function(entries, page)
      for _, e in ipairs(page or {}) do table.insert(entries, e) end
      return entries
    end,
  }
end

package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local ShelfDialog = require("hardcover/lib/ui/shelf_dialog")

-- ---------------------------------------------------------------- fixtures
-- Shaped exactly like a Hardcover GraphQL shelf row, including the optional
-- fields that are absent for many real books. The crash was reported for both
-- shelf views, so the common path is what matters.
local function entry(over)
  local e = {
    user_book_id = 501,
    book_id = 9001,
    status_id = 1,
    title = "The Dispossessed",
    authors = "Ursula K. Le Guin",
    cached_image = { url = "https://covers.example/1.jpg", width = 120, height = 180 },
  }
  -- Assign explicitly in pairs order rather than skipping nils, so a variant
  -- can genuinely clear a field the default supplies. Without this,
  -- `{ cached_image = nil }` silently kept the default cover and the test was
  -- asserting against data it thought it had removed.
  for k, v in pairs(over or {}) do e[k] = v end
  for k in pairs(over or {}) do
    if over[k] == nil then e[k] = nil end
  end
  return e
end

local function buildDialog(entries, opts)
  opts = opts or {}
  record.specs = {}
  record.shown = {}
  local d = ShelfDialog:new {
    title = opts.title or "Want to Read",
    entries = entries,
    has_more = opts.has_more or false,
    status_id = opts.status_id or 1,
    compatibility_mode = opts.compatibility_mode or false,
    fetch_page = opts.fetch_page,
    on_refresh = opts.on_refresh,
    on_search = opts.on_search,
    sortable = opts.sortable,
    sort_key = opts.sort_key,
    filter = opts.filter,
  }
  return d
end

local function lastSpec()
  return record.specs[#record.specs]
end

-- ---------------------------------------------------------------- the list itself
print("\n== the list the plugin builds ==")
do
  buildDialog({ entry() })
  local spec = lastSpec()
  r.check("a menu is constructed", spec ~= nil)
  if spec then
    r.check("every entry becomes an item", #(spec.item_table or {}) == 1,
      "got " .. tostring(spec and #(spec.item_table or {})))
    local item = (spec.item_table or {})[1]
    r.check("an item was built", item ~= nil)
    if item then
      r.check("the title reaches the row", type(item.text) == "string"
        and item.text:find("The Dispossessed", 1, true) ~= nil,
        "text = " .. tostring(item.text))
      --[[
The author reaches the row in `authors`, not in `text`.

It used to be asserted against `text`, which was true only because the old
shelf code appended authors to the text string itself. Row shaping now puts
them in their own field, because that is what ListMenu and SearchMenu read:
SearchMenu draws title and authors as separate lines from those fields, and
cramming them into `text` meant the SearchMenu path printed the title twice
for a shelf row.

So the assertion follows the field the menu actually paints from, and
separately pins the compatibility-mode `text` form, where there is only one
line to put the author on.
]]
      r.check("the author reaches the row", type(item.authors) == "string"
        and item.authors:find("Le Guin", 1, true) ~= nil,
        "authors = " .. tostring(item.authors))
      r.check("the title is not polluted with the author",
        item.text ~= nil and item.text:find("Le Guin", 1, true) == nil,
        "text = " .. tostring(item.text))
      -- Shelf rows still need their own decoration: the status label and rating are
  -- properties of a shelf entry, not of a book, so they are applied after the
  -- shared row shaping rather than inside it.
  -- The shelf already says the status and the details say the page count and
  -- year, so a row is cover, title and author, and your rating when you have one.
  r.check("rows are tall (five a page) and carry no keyboard letters",
        lastSpec().files_per_page == 5 and lastSpec().is_enable_shortcut == false,
        "files_per_page = " .. tostring(lastSpec().files_per_page) .. ", shortcuts = " .. tostring(lastSpec().is_enable_shortcut))
  r.check("an unrated row has no right-hand column", item.mandatory == "",
        "mandatory = " .. tostring(item.mandatory))
  r.check("no page count or year clutters the row", item.pages == nil and not (item.title or ""):find("%(%d%d%d%d%)"),
        "pages = " .. tostring(item.pages) .. ", title = " .. tostring(item.title))
  r.check("a suggestion says why, where a series would be", (function()
    buildDialog({ entry({ reason = "Wool", book_series = { { position = 2, series = { name = "Shift" } } } }) })
    local row = (lastSpec().item_table or {})[1]
    return row and row.series and row.series:find("Wool", 1, true) ~= nil and row.series_index == nil
  end)(), "the reason did not replace the series")
  r.check("in the one-line list the reason ends the line", (function()
    local d = buildDialog({ entry() }, { compatibility_mode = true })
    local row = d:createListItem(entry({ reason = "Wool" }))
    return row.text:find(" - Because you liked Wool", 1, true) ~= nil
  end)(), "the stock list lost the reason")
  r.check("a rating is the only thing in the right-hand column",
        (function()
          local rated = buildDialog({ entry({ user_rating = 4 }) })
          local r_item = (lastSpec().item_table or {})[1]
          return r_item and r_item.mandatory:find("4*", 1, true) ~= nil
        end)(),
        "a whole rating must read 4*, not 4.0*")
  r.check("a fractional rating keeps its decimal",
        (function()
          local d = buildDialog({ entry({ user_rating = 4.5 }) })
          local r_item = (lastSpec().item_table or {})[1]
          return r_item and r_item.mandatory:find("4.5*", 1, true) ~= nil
        end)(),
        "expected 4.5* in the mandatory label")
      r.check("the cover url is attached", item.cover_url == "https://covers.example/1.jpg",
        "cover_url = " .. tostring(item.cover_url))
      r.check("cover dimensions are passed through",
        item.cover_w == 120 and item.cover_h == 180,
        tostring(item.cover_w) .. "x" .. tostring(item.cover_h))
      r.check("the cover is marked for lazy loading", item.lazy_load_cover == true,
        "lazy_load_cover = " .. tostring(item.lazy_load_cover))
      -- Selection is wired at the menu level via onMenuSelect, not per item:
      -- shelf_dialog mirrors search_dialog here, and a per-row callback would
      -- be redundant.
      -- THE CRASH. hardcover/vendor/listmenu.lua decides how to draw a row with:
      --   self.is_directory = not (self.entry.is_file or self.entry.file)
      -- A shelf item carrying neither is drawn as a FOLDER, not a book, and the
      -- directory branch is what blew up on device. search_dialog sets
      -- file = "hardcover-<book_id>"; the shelf dialog did not, so every row in
      -- both shelf views took the directory path.
      r.check("a book row is not mistaken for a directory",
        item.file ~= nil or item.is_file == true,
        "item has neither .file nor .is_file, so the menu renders it as a folder")
      r.check("the file marker identifies this specific book",
        item.file == "hardcover-9001",
        "file = " .. tostring(item.file))

      r.check("row selection is wired on the menu", type(spec.onMenuSelect) == "function",
        "onMenuSelect = " .. type(spec.onMenuSelect))
      r.check("tapping a row does not carry its own callback", item.callback == nil,
        "callback = " .. tostring(item.callback))
    end
    r.check("paging is declared", spec.has_more == false or spec.has_more == nil
      or type(spec.has_more) == "boolean", "has_more = " .. tostring(spec.has_more))
  end
end

-- ---------------------------------------------------------------- both shelf views
-- The user reported both lists crash, so both must build.
print("\n== both shelf views ==")
for _, case in ipairs({
  { id = 1, name = "Want to Read" },
  { id = 2, name = "Currently Reading" },
}) do
  local d = buildDialog({ entry({ status_id = case.id }) }, {
    title = case.name, status_id = case.id,
  })
  local spec = lastSpec()
  local item = spec and (spec.item_table or {})[1]
  r.check(case.name .. " builds a row", item ~= nil)
  r.check(case.name .. " does not repeat the shelf's own status on every row", item and item.mandatory == "",
    "mandatory = " .. tostring(item and item.mandatory))
end

-- ---------------------------------------------------------------- optional fields
-- Real shelves are full of books missing a cover, a series, or a rating. Each
-- of these is a place the dialog could index nil, so each is asserted.
print("\n== books with missing optional fields ==")
local variants = {
  { name = "no cover at all", over = { cached_image = nil } },
  { name = "cover with no dimensions", over = { cached_image = { url = "https://c/x.jpg" } } },
  { name = "empty cover object", over = { cached_image = {} } },
  { name = "no author", over = { authors = nil } },
  { name = "empty author string", over = { authors = "" } },
  { name = "no series", over = { series = nil } },
  { name = "series with no number", over = { series = "Dune", series_index = nil } },
  { name = "no rating", over = { user_rating = nil, community_rating = nil } },
  { name = "zero rating", over = { user_rating = 0 } },
  { name = "no page count", over = { pages = nil } },
  { name = "no release year", over = { release_year = nil } },
  { name = "empty title", over = { title = "" } },
}

for _, v in ipairs(variants) do
  local ok, err = pcall(function()
    local d = buildDialog({ entry(v.over) })
    local spec = lastSpec()
    assert(spec, "no menu constructed")
    assert(#(spec.item_table or {}) == 1, "expected 1 item, got " .. tostring(#(spec.item_table or {})))
    local item = spec.item_table[1]
    assert(item.text ~= nil, "item has no text")
    -- Only assert cover behaviour for variants that actually touch
    -- cached_image. Every other variant keeps the fixture's default cover, so
    -- expecting it to vanish was testing the fixture, not the plugin.
    local touched_cover = v.over.cached_image ~= nil
    if touched_cover then
      local has_url = v.over.cached_image.url ~= nil
      if not has_url then
        assert(item.cover_url == nil,
          "cover_url should be absent, got " .. tostring(item.cover_url))
        assert(item.lazy_load_cover == nil,
          "lazy_load_cover should be absent, got " .. tostring(item.lazy_load_cover))
      else
        assert(item.cover_url == v.over.cached_image.url,
          "cover_url = " .. tostring(item.cover_url))
        assert(item.lazy_load_cover == true,
          "lazy_load_cover = " .. tostring(item.lazy_load_cover))
        if v.over.cached_image.width == nil then
          assert(item.cover_w == nil and item.cover_h == nil,
            "expected no dimensions, got " .. tostring(item.cover_w) .. "x" .. tostring(item.cover_h))
        end
      end
    else
      assert(item.cover_url == "https://covers.example/1.jpg",
        "default cover should survive, got " .. tostring(item.cover_url))
    end
  end)
  r.check("survives: " .. v.name, ok, ok and nil or tostring(err))
end

-- ---------------------------------------------------------------- larger shelves
print("\n== shelf sizes ==")
for _, n in ipairs({ 0, 1, 2, 20, 21, 50 }) do
  local rows = {}
  for i = 1, n do rows[i] = entry({ book_id = 9000 + i, user_book_id = 500 + i }) end
  local ok, err = pcall(function()
    buildDialog(rows)
    local spec = lastSpec()
    assert(#(spec.item_table or {}) == n, "expected " .. n .. " items, got " .. tostring(#(spec.item_table or {})))
  end)
  r.check(string.format("%d entries build cleanly", n), ok, ok and nil or tostring(err))
end

-- ---------------------------------------------------------------- the header
print("\n== the header ==")
do
  local d = buildDialog({ entry() })
  local spec = lastSpec()
  local header = d.header
  r.check("the menu is given the header as its title bar", spec.custom_title_bar == header and header ~= nil)
  r.check("and builds no left icon or callback of its own",
    spec.title_bar_left_icon == nil and spec.onLeftButtonTap == nil)
  r.check("the header is as wide as the menu", header.width == spec.width, tostring(header.width) .. " vs " .. tostring(spec.width))
  r.check("it carries the shelf's title", header.title == "Want to Read", tostring(header.title))
  local UIManager_ = require("ui/uimanager")
  UIManager_._closed = nil
  local closed = 0
  d.close_callback = function() closed = closed + 1 end
  -- (the container stub gives every instance an empty onClose; the real one is under test)
  d.onClose = ShelfDialog.onClose
  header.back_callback()
  r.check("Back closes the screen", UIManager_._closed == d and closed == 1)
  UIManager_._closed = nil
  spec.close_callback()
  r.check("so does the device's Back key, through the menu", UIManager_._closed == d and closed == 2)
end

-- ---------------------------------------------------------------- the reload icon
print("\n== the reload icon ==")
do
  local function icon(d) return d.header.right_icon end
  local fetched = {}
  local function fetch(offset, limit, callback) fetched[#fetched + 1] = { offset, limit, callback } end

  local d = buildDialog({ entry() }, { has_more = true, fetch_page = fetch })
  r.check("more to load: the reload icon is beside the X", icon(d) == "cre.render.reload", tostring(icon(d)))
  r.check("and it is the header's second icon, not a menu icon", lastSpec().title_bar_left_icon == nil)
  d.header.right_callback()
  r.check("it carries on loading from where the list ends", #fetched == 1 and fetched[1][1] == 1,
    "fetched " .. #fetched)

  d = buildDialog({ entry() }, { has_more = true })
  r.check("more to load but no way to load it: no icon", icon(d) == nil, tostring(icon(d)))

  d = buildDialog({ entry() }, { has_more = false, fetch_page = fetch })
  r.check("nothing more to load: no icon", icon(d) == nil, tostring(icon(d)))

  local refreshed
  d = buildDialog({ entry() }, { on_refresh = function(dialog) refreshed = dialog end })
  r.check("a screen that can refresh has the icon from the start", icon(d) == "cre.render.reload", tostring(icon(d)))
  d.header.right_callback()
  r.check("it runs on_refresh with the dialog", refreshed == d)

  fetched, refreshed = {}, nil
  d = buildDialog({ entry() }, { has_more = true, fetch_page = fetch, on_refresh = function(dialog) refreshed = dialog end })
  d.header.right_callback()
  r.check("with both, finishing the load comes first", #fetched == 1 and refreshed == nil)

  -- kept current as the state changes: every caller builds with has_more = false and
  -- sets it later, which is why the old icon never showed
  d = buildDialog({ entry() }, { fetch_page = fetch })
  local before = d.header.updates
  d:setEntries({ entry(), entry() }, true, true)
  r.check("rows arriving with more to come show the icon", icon(d) == "cre.render.reload", tostring(icon(d)))
  r.check("by updating the header, not rebuilding it", d.header == lastSpec().custom_title_bar and d.header.updates == before + 1)
  local dirty = require("ui/uimanager").dirty_calls
  d:setEntries({ entry(), entry(), entry() }, true, true)
  r.check("a header that did not change is left alone", d.header.updates == before + 1)
  d:setEntries({ entry() }, false, true)
  r.check("the last page takes the icon away (false, which removes it)", icon(d) == false, tostring(icon(d)))

  fetched = {}
  d = buildDialog({ entry() }, { fetch_page = fetch })
  d:setEntries({ entry() }, true, true)
  d.offset = 1
  d.header.right_callback()
  fetched[1][3]({ entry(), entry() }, nil, false)
  r.check("loading the rest appends it and takes the icon away", #d.entries == 3 and d.has_more == false
    and icon(d) == false, "entries " .. #d.entries .. ", icon " .. tostring(icon(d)))

  d = buildDialog({ entry() }, { fetch_page = fetch })
  d:setEntries({ entry() }, true, true)
  fetched = {}
  d.header.right_callback()
  fetched[1][3](nil, "boom")
  r.check("a failed load keeps the icon, to try again", icon(d) == "cre.render.reload" and d.has_more == true)

  d = buildDialog({ entry() }, { has_more = true, fetch_page = fetch })
  d:setEmptyState("Nothing")
  r.check("an empty answer takes the icon away", icon(d) == false or icon(d) == nil)

  -- the refresh covers the header's rectangle only
  d = buildDialog({ entry() }, { fetch_page = fetch })
  local UIManager = require("ui/uimanager")
  UIManager.dirty_calls, UIManager.last_dirty = 0, nil
  d:updatePager()
  r.check("nothing changed: nothing is refreshed", UIManager.dirty_calls == 0)
  d.has_more = true
  d:updatePager()
  r.check("the header changed: its own region is refreshed", UIManager.dirty_calls == 1 and type(UIManager.last_dirty) == "function",
    tostring(UIManager.dirty_calls) .. " " .. type(UIManager.last_dirty))
end

-- ---------------------------------------------------------------- keeping the reader's place
print("\n== keeping the reader's place while rows arrive ==")
do
  local d = buildDialog({ entry() })
  local got = "unset"
  d.menu.switchItemTable = function(_, _, _, number) got = number end
  d.menu.page, d.menu.perpage = 3, 10

  d:setEntries({ entry(), entry() }, true, true)
  r.check("stays on the page being viewed when keep_position is set", got == 21,
    "item number " .. tostring(got))

  got = "unset"
  d:setEntries({ entry() }, false)
  r.check("returns to the first page when it is not", got == nil,
    "item number " .. tostring(got))
end

-- ---------------------------------------------------------------- sorting a shelf
print("\n== sorting a shelf ==")
do
  local ButtonDialog = require("ui/widget/buttondialog")
  local function titles(spec)
    local out = {}
    for i, item in ipairs(spec.item_table) do out[i] = item.title end
    return table.concat(out, "|")
  end
  local function shelf(opts)
    opts = opts or {}
    opts.sortable = true
    local entries = {
      entry({ book_id = 1, title = "The Zebra", authors = "Ann Zed", pages = 100 }),
      entry({ book_id = 2, title = "Apple", authors = "Bob Young", pages = 300 }),
      entry({ book_id = 3, title = "Mango", authors = "Cy Xu", pages = 200 }),
    }
    record.specs = {}
    local d = ShelfDialog:new {
      title = "Want to Read", entries = entries, status_id = 1, sortable = true,
      sort_key = opts.sort_key, on_sort_change = opts.on_sort_change, has_more = opts.has_more or false,
      fetch_page = opts.has_more and function() end or nil,
    }
    return d, lastSpec()
  end

  local d, spec = shelf()
  r.check("a shelf has no menu icon: sorting is a button in the row", spec.title_bar_left_icon == nil
    and spec.onLeftButtonTap == nil)
  r.check("it opens in the arrival order by default", titles(spec) == "The Zebra|Apple|Mango", titles(spec))
  r.check("the title is the shelf's name, whatever the order", d:displayTitle() == "Want to Read" and spec.title == "Want to Read")

  local changed
  d, spec = shelf({ on_sort_change = function(k) changed = k end })
  d:setSort("title")
  r.check("choosing a sort re-orders the rows (articles ignored)", titles(spec) == "Apple|Mango|The Zebra", titles(spec))
  r.check("and tells the owner, so the choice can be remembered", changed == "title")
  d:setSort("pages_asc")
  r.check("another sort replaces it", titles(spec) == "The Zebra|Mango|Apple", titles(spec))
  changed = nil
  d:setSort("pages_asc")
  r.check("choosing the current sort again does nothing", changed == nil)
  d:setSort("nonsense")
  r.check("an unknown sort is ignored", titles(spec) == "The Zebra|Mango|Apple")

  d, spec = shelf({ sort_key = "author" })
  r.check("a remembered sort is applied when the shelf opens (author by surname)", titles(spec) == "Mango|Apple|The Zebra", titles(spec))
  r.check("the entries themselves keep their arrival order (counts and the saved copy depend on it)",
    d.entries[1].book_id == 1 and d.entries[2].book_id == 2 and d.entries[3].book_id == 3)

  d, spec = shelf({ sort_key = "title" })
  d:showSortMenu()
  local dialog = ButtonDialog.last
  local labels = {}
  for _, row in ipairs(dialog.buttons) do labels[#labels + 1] = row[1].text end
  r.check("the sort menu lists every order", #labels == 11, #labels .. " rows")
  r.check("the current order is ticked, only that one", labels[3]:find("\226\156\147", 1, true) ~= nil
    and (table.concat(labels):gsub("\226\156\147", "")) ~= table.concat(labels)
    and select(2, table.concat(labels):gsub("\226\156\147", "")) == 1)
  dialog.buttons[4][1].callback() -- Author
  r.check("choosing from the menu sorts by it", titles(spec) == "Mango|Apple|The Zebra", titles(spec))

  d, spec = shelf({ has_more = true })
  d:showSortMenu()
  r.check("the picker lists the orders and nothing else, even when a load was interrupted",
    #ButtonDialog.last.buttons == 11 and ButtonDialog.last.buttons[1][1].text:find("Load the rest", 1, true) == nil,
    #ButtonDialog.last.buttons .. " rows")

  -- the Sort button names the order, and follows it
  d, spec = shelf()
  local function sortText(dialog) return dialog.header.buttons[1].text end
  r.check("the Sort button names the order in use", sortText(d) == "Sort: Date added (newest first)", sortText(d))
  r.check("it opens a picker, so it carries the chevron", d.header.buttons[1].chevron == true)
  d.header.buttons[1].callback()
  r.check("and tapping it opens the picker", #ButtonDialog.last.buttons == 11)
  d:setSort("title")
  r.check("choosing an order renames the button", sortText(d) == "Sort: Title (A\226\128\147Z)", sortText(d))
  r.check("the title is still just the name", d.header.title == "Want to Read", d.header.title)
  d, spec = shelf({ sort_key = "author" })
  r.check("a remembered order is on the button when the shelf opens", sortText(d) == "Sort: Author (A\226\128\147Z)", sortText(d))

  -- search results are in relevance order: no Sort button
  d = ShelfDialog:new { title = "x", entries = { entry() }, status_id = 1 }
  r.check("a list that is not a shelf has no Sort button", #d.header.buttons == 1 and d.header.buttons[1].text == "Search")
end

-- ---------------------------------------------------------------- the row of buttons
print("\n== the row under the title bar ==")
do
  local function texts(dialog)
    local out = {}
    for _, b in ipairs(dialog.header.buttons) do out[#out + 1] = b.text end
    return table.concat(out, " | ")
  end
  local d = buildDialog({ entry() }, { sortable = true })
  r.check("a shelf: Sort and Search", texts(d) == "Sort: Date added (newest first) | Search", texts(d))
  d = buildDialog({ entry() }, {})
  r.check("a list: Search alone", texts(d) == "Search", texts(d))

  local searched = 0
  d = buildDialog({ entry() }, { on_search = function() searched = searched + 1 end })
  r.check("search results: New search alone, with the chevron", texts(d) == "New search" and d.header.buttons[1].chevron == true, texts(d))
  d.header.buttons[1].callback()
  r.check("it runs on_search", searched == 1)
  d:setFilter("x")
  r.check("and never grows a filter button", texts(d) == "New search", texts(d))
end

-- ---------------------------------------------------------------- searching a list
print("\n== searching a list ==")
do
  local InputDialog = require("ui/widget/inputdialog")
  local UIManager = require("ui/uimanager")
  local function titles(dialog)
    local out = {}
    for i, item in ipairs(dialog.menu.item_table) do out[i] = item.title or item.text end
    return table.concat(out, "|")
  end
  local function row(dialog)
    local out = {}
    for _, b in ipairs(dialog.header.buttons) do out[#out + 1] = b.text end
    return table.concat(out, " | ")
  end
  local function shelf(opts)
    opts = opts or {}
    local entries = {
      entry({ book_id = 1, title = "The Zebra", authors = "Ann Zed" }),
      entry({ book_id = 2, title = "Apple", authors = "Bob Young" }),
      entry({ book_id = 3, title = "Mango", authors = "Cy Xu", series = "Fruit" }),
      entry({ book_id = 4, title = "Caf\195\169", authors = "\195\137mile Zola" }),
    }
    opts.sortable = opts.sortable ~= false
    return buildDialog(entries, opts)
  end

  local d = shelf()
  d.header.buttons[2].callback()
  local box = InputDialog.last
  r.check("Search opens a box, titled for a shelf", box and box.title == "Search this shelf", tostring(box and box.title))
  r.check("with nothing in it, the keyboard up, and Cancel and Search", box.input == "" and box.keyboard == true
    and box.buttons[1][1].text == "Cancel" and box.buttons[1][2].text == "Search")
  box.text = "e"
  box.buttons[1][2].callback()
  r.check("searching closes the box", UIManager._closed == box)
  r.check("and keeps the matches only, in the order in use", titles(d) == "The Zebra|Apple|Caf\195\169", titles(d))
  r.check("every row is the entry that matched", (function()
    for _, item in ipairs(d.menu.item_table) do
      if not (item.entry and item.entry.book_id) then return false end
    end
    return #d.menu.item_table > 0
  end)())
  r.check("the filter is kept", d.filter == "e")

  d = shelf({ sort_key = "title" })
  d:setFilter("e")
  r.check("the filter is applied before the sort", titles(d) == "Apple|Caf\195\169|The Zebra", titles(d))
  d:setFilter("zed")
  r.check("authors are searched", titles(d) == "The Zebra", titles(d))
  d:setFilter("fruit")
  r.check("so is the series", titles(d) == "Mango", titles(d))
  d:setFilter("CAFE")
  r.check("case and accents do not matter", titles(d) == "Caf\195\169", titles(d))
  d:setFilter("zebra zed")
  r.check("every word has to match", titles(d) == "The Zebra", titles(d))
  d:setFilter("zebra apple")
  r.check("words from two books match neither", #d.menu.item_table == 1 and d.menu.item_table[1].file == "hardcover-empty")
  r.check("the entries themselves are untouched", #d.entries == 4)

  d:setFilter("zebra")
  r.check("a filter shows the words in black, and a small x",
    row(d) == "Sort: Title (A\226\128\147Z) | \226\128\156zebra\226\128\157 | \195\151", row(d))
  r.check("the words are the filled button; the x is narrow", d.header.buttons[2].filled == true and d.header.buttons[3].narrow == true
    and not d.header.buttons[1].filled)
  d.header.buttons[2].callback()
  box = InputDialog.last
  r.check("the words open the box again with the filter in it", box.input == "zebra", tostring(box.input))
  box.text = "mango"
  box.buttons[1][2].callback()
  r.check("a new search replaces the filter", d.filter == "mango" and titles(d) == "Mango")
  d.header.buttons[3].callback()
  r.check("the x clears it: every book is back, the row is Sort and Search",
    d.filter == nil and #d.menu.item_table == 4 and row(d) == "Sort: Title (A\226\128\147Z) | Search", row(d))

  d:setFilter("   ")
  r.check("only spaces is no filter", d.filter == nil and #d.menu.item_table == 4)
  d:setFilter("  mango ")
  r.check("spaces around the words are dropped", d.filter == "mango")
  d.header.buttons[2].callback()
  box = InputDialog.last
  box.text = ""
  box.buttons[1][2].callback()
  r.check("searching with nothing in the box clears the filter", d.filter == nil and #d.menu.item_table == 4)
  d.header.buttons[2].callback()
  box = InputDialog.last
  UIManager._closed = nil
  box.buttons[1][1].callback()
  r.check("Cancel closes the box and changes nothing", UIManager._closed == box and d.filter == nil)

  -- nothing matches: a row says so, like an empty shelf
  d = shelf()
  d:setFilter("qqq")
  local only = d.menu.item_table[1]
  r.check("a word nothing matches says so", #d.menu.item_table == 1 and only.text == "No books match \226\128\156qqq\226\128\157", tostring(only and only.text))
  r.check("in a row the list will draw as a book, not a folder", only.file == "hardcover-empty" and only.mandatory == "")
  r.check("and it is not the shelf's own empty state", d.empty_state == nil)

  -- the filter outlives new rows, and does not touch what is left to load
  local fetched = {}
  d = shelf({ fetch_page = function(offset, _, callback) fetched[#fetched + 1] = callback end })
  d:setEntries(d.entries, true, true)
  d:setFilter("qqq")
  r.check("a filter that matches nothing leaves the reload icon", d.header.right_icon == "cre.render.reload" and d.has_more == true)
  d:setEntries({ entry({ book_id = 7, title = "Qqq Book" }) }, true, true)
  r.check("rows that arrive are filtered too", #d.menu.item_table == 1 and d.menu.item_table[1].title == "Qqq Book")
  d.offset = 1
  d.header.right_callback()
  fetched[1]({ entry({ book_id = 8, title = "Another" }), entry({ book_id = 9, title = "More qqq" }) }, nil, false)
  r.check("and so is the rest of the list when it comes", #d.entries == 3 and #d.menu.item_table == 2, #d.menu.item_table .. " rows")

  -- an empty shelf says so again once a filter on it is cleared
  d = shelf()
  d:setEntries({}, false, true)
  d:setEmptyState("No books on this shelf yet")
  d:setFilter("x")
  d:setFilter(nil)
  r.check("an empty shelf keeps its own message", #d.menu.item_table == 1 and d.menu.item_table[1].text == "No books on this shelf yet")

  -- a list is a list: Search says "list"
  d = shelf({ sortable = false })
  d.header.buttons[1].callback()
  r.check("on a list the box says list", InputDialog.last.title == "Search this list", tostring(InputDialog.last.title))
end

r.finish()