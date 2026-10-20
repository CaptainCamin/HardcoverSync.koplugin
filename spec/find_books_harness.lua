-- Looking up many books by their identifiers at once (Api:findBooksByIdentifiers): how many requests
-- it makes, what it asks for, and which book each file gets.
--
-- Run with:  lua spec/find_books_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

local ticks = {}
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) fn() end }
end
package.preload["ui/uimanager"] = function()
  return {
    show = function() end, setDirty = function() end, scheduleIn = function() end,
    unschedule = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
end
package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["ffi"] = function() return {} end
package.preload["ffi/pointer"] = function() return {} end
package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
package.preload["blitbuffer"] = function() return {} end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end

local Api = require("hardcover/lib/hardcover_api")
Api.auth = nil

local r = support.reporter()
local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- A fake Hardcover: `rows` is { [table name] = { rows } }; every request is recorded.
local function fake(rows, fail_on)
  local calls = {}
  Api.query = function(_, query, variables)
    local name = query:match("(%a+)%(where")
    local column = query:match("where: { ([%w_]+):")
    calls[#calls + 1] = { table = name, column = column, values = variables.values, query = query }
    if fail_on == column then return nil, { completed = false } end
    local out = {}
    for _, row in ipairs(rows[name] or {}) do
      for _, wanted in ipairs(variables.values) do
        if tostring(row[column]) == tostring(wanted) then out[#out + 1] = row end
      end
    end
    return { [name] = out }
  end
  return calls
end

local function edition(id, isbn13, title)
  return { id = id, isbn_13 = isbn13, title = title,
           book = { book_id = id * 10, title = title }, edition_format = "Paperback" }
end

print("\n== requests ==")

check("any number of books is at most four requests, one per kind of identifier", function()
  local calls = fake({})
  local list = {}
  for i = 1, 25 do list[i] = { isbn_13 = tostring(9780000000000 + i), isbn_10 = "x" .. i, book_slug = "s" .. i, edition_id = i } end
  local answers = Api:findBooksByIdentifiers(list, 1)
  assert(#calls == 4, #calls)
  assert(#calls[1].values == 25 and #answers == 25)
end)

check("a kind nobody has is not asked for", function()
  local calls = fake({})
  Api:findBooksByIdentifiers({ { isbn_13 = "9780441172719" }, { isbn_13 = "9780441172720" } }, 1)
  assert(#calls == 1 and calls[1].column == "isbn_13", #calls)
end)

check("a value shared by two files is asked for once", function()
  local calls = fake({})
  Api:findBooksByIdentifiers({ { isbn_13 = "9780441172719" }, { isbn_13 = "9780441172719" } }, 1)
  assert(#calls[1].values == 1)
end)

check("an empty list asks nothing", function()
  local calls = fake({})
  local answers = Api:findBooksByIdentifiers({}, 1)
  assert(#calls == 0 and #answers == 0)
end)

print("\n== answers ==")

check("each file gets its own book, and false when Hardcover has none", function()
  fake({ editions = { edition(3, "9780441172719", "Dune"), edition(4, "9780000000004", "Other") } })
  local answers = Api:findBooksByIdentifiers({ { isbn_13 = "9780000000004" }, { isbn_13 = "9780000000009" },
    { isbn_13 = "9780441172719" } }, 1)
  assert(answers[1].title == "Other" and answers[1].edition_id == 4, "first")
  assert(answers[2] == false, "second")
  assert(answers[3].title == "Dune", "third")
end)

check("an edition id wins over a slug and an ISBN, a slug over an ISBN", function()
  fake({
    editions = { edition(3, "9780441172719", "By edition"), edition(5, "9780441172720", "By isbn") },
    books = { { slug = "dune", book_id = 99, title = "By slug" } },
  })
  local answers = Api:findBooksByIdentifiers({
    { edition_id = 3, book_slug = "dune", isbn_13 = "9780441172720" },
    { book_slug = "dune", isbn_13 = "9780441172720" },
    { book_slug = "unknown", isbn_13 = "9780441172720" },
  }, 1)
  assert(answers[1].title == "By edition", answers[1].title)
  assert(answers[2].title == "By slug", answers[2].title)
  assert(answers[3].title == "By isbn", answers[3].title)
end)

check("an ISBN-10 is used when there is no ISBN-13 match", function()
  fake({ editions = { { id = 8, isbn_10 = "0441172717", title = "Ten", book = { book_id = 80, title = "Ten" } } } })
  local answers = Api:findBooksByIdentifiers({ { isbn_13 = "9780000000000", isbn_10 = "0441172717" } }, 1)
  assert(answers[1] and answers[1].title == "Ten")
end)

print("\n== failure ==")

check("a failed request gives nil and an error, never a list of no-matches", function()
  fake({}, "isbn_13")
  local answers, err = Api:findBooksByIdentifiers({ { isbn_13 = "9780441172719" } }, 1)
  assert(answers == nil and err, "answers: " .. tostring(answers))
end)

check("findBookByIdentifiers says when the call failed", function()
  fake({}, "isbn_13")
  local book, err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719" }, 1)
  assert(book == nil and err, "no error given")
  fake({})
  local none, none_err = Api:findBookByIdentifiers({ isbn_13 = "9780441172719" }, 1)
  assert(none == nil and none_err == nil, "an unknown book is not a failure")
end)

r.finish()
