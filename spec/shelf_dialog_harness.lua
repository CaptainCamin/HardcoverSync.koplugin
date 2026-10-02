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
    setDirty = function() end,
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

-- ---------------------------------------------------------------- paging
print("\n== paging ==")
do
  local d = buildDialog({ entry() }, { has_more = true })
  local spec = lastSpec()
  -- has_more is consumed by the dialog to decide whether to offer a reload
  -- affordance; it is not itself handed to Menu.
  r.check("a next-page affordance is offered when more pages exist",
    type(spec.onLeftButtonTap) == "function",
    "onLeftButtonTap = " .. type(spec.onLeftButtonTap))
  r.check("the affordance is labelled as a reload",
    spec.title_bar_left_icon == "cre.render.reload",
    "title_bar_left_icon = " .. tostring(spec.title_bar_left_icon))
end
do
  local d = buildDialog({ entry() }, { has_more = false })
  local spec = lastSpec()
  r.check("no next-page affordance on the last page",
    spec.onLeftButtonTap == nil and spec.title_bar_left_icon == nil,
    "onLeftButtonTap = " .. type(spec.onLeftButtonTap)
      .. ", icon = " .. tostring(spec.title_bar_left_icon))
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
  r.check("a shelf's left icon is the sort button, even when nothing is left to load", spec.title_bar_left_icon == "appbar.menu"
    and type(spec.onLeftButtonTap) == "function", tostring(spec.title_bar_left_icon))
  r.check("it opens in the arrival order by default", titles(spec) == "The Zebra|Apple|Mango", titles(spec))

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
  r.check("a shelf whose load was interrupted offers to carry on in the sort menu",
    ButtonDialog.last.buttons[1][1].text:find("Load the rest", 1, true) ~= nil)
  d, spec = shelf()
  d:showSortMenu()
  r.check("a complete shelf does not", ButtonDialog.last.buttons[1][1].text:find("Load the rest", 1, true) == nil)

  -- search results are in relevance order: no sort button, reload icon as before
  record.specs = {}
  ShelfDialog:new { title = "x", entries = { entry() }, has_more = true, status_id = 1 }
  local plain = lastSpec()
  r.check("a list that is not a shelf has no sort button", plain.title_bar_left_icon == "cre.render.reload")
end

r.finish()