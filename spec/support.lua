-- Shared scaffolding for the harnesses in spec/.
--
-- These run under plain Lua against the plugin's real source. They stub the
-- KOReader modules the plugin requires so a harness can drive a real file
-- without a device or a running reader, and they extract functions from source
-- rather than copying them, so a test cannot quietly drift away from the code
-- it is meant to be checking.
--
-- The pattern is borrowed from the zlibrary.koplugin test suite, which is worth
-- following precisely: stub the KOReader boundary, capture what the plugin
-- hands to the real widget constructors, and assert on that. Trying to make a
-- whole vendored widget tree genuinely execute is a losing game -- each missing
-- KOReader method surfaces as a nil call that looks exactly like a plugin bug,
-- and you cannot tell the two apart. Capturing constructor args tests the code
-- you actually wrote.

local support = {}

-- ---------------------------------------------------------------- reporting
function support.reporter()
  local r = { pass = 0, fail = 0 }

  function r.check(label, ok, detail)
    if ok then
      r.pass = r.pass + 1
    else
      r.fail = r.fail + 1
    end
    print(string.format("  [%s] %s%s", ok and "ok  " or "FAIL", label,
      (not ok and detail and detail ~= "") and ("  <- " .. tostring(detail)) or ""))
    return ok
  end

  function r.finish()
    print(string.format("\n  %d passed, %d failed", r.pass, r.fail))
    os.exit(r.fail == 0 and 0 or 1)
  end

  return r
end

-- ---------------------------------------------------------------- KOReader stubs
-- Only what the plugin actually reaches for. A harness that needs a module to
-- behave in a particular way overrides it afterwards; these are inert defaults.
function support.preload_koreader_stubs()
  package.preload["logger"] = function()
    return { dbg = function() end, info = function() end,
             warn = function() end, err = function() end }
  end

  package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
  end

  package.preload["util"] = function()
    return {
      tableDeepCopy = function(t)
        local function copy(v, seen)
          if type(v) ~= "table" then return v end
          if seen[v] then return seen[v] end
          local out = {}
          seen[v] = out
          for k, val in pairs(v) do out[copy(k, seen)] = copy(val, seen) end
          return setmetatable(out, getmetatable(v))
        end
        return copy(t, {})
      end,
      trim = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end,
      splitFilePathName = function(p) return p:match("^(.*/)([^/]*)$") end,
      urlEncode = function(url)
        if url == nil then return end
        return (tostring(url):gsub("[^%w%-%._~]", function(c)
          return string.format("%%%02X", string.byte(c))
        end))
      end,
      basename = function(p) return tostring(p):match("([^/]*)$") end,
      dirname = function(p) return tostring(p):match("^(.*/)") or "" end,
      realpath = function(p) return p end,
      fileExists = function() return false end,
      mkdir = function() return true end,
      readdir = function() return {} end,
      removeFile = function() return true end,
      touch = function() return true end,
      formatSize = function(n) return tostring(n) end,
      secondsToDate = function() return "" end,
      isWhiteListed = function() return true end,
      shellQuote = function(s) return "'" .. tostring(s) .. "'" end,
      readFile = function() return nil end,
      writeFile = function() return true end,
    }
  end

  package.preload["ui/time"] = function()
    local t = 0
    return { now = function() t = t + 1 return t end,
             since = function() return 1 end,
             to_ms = function() return 1 end }
  end

  -- A LuaSettings stand-in backed by a plain table. The plugin reads and writes
  -- progress through this, so a harness that stubs it as a no-op cannot see
  -- whether a value was actually persisted.
  package.preload["luasettings"] = function()
    local store = {}
    return {
      open = function() return true end,
      close = function() return true end,
      flush = function() return true end,
      readSetting = function(_, key)
        local v = store[key]
        if v == nil then return nil end
        -- KOReader hands back a table for table-valued settings
        if type(v) == "table" then
          local out = {}
          for i, item in ipairs(v) do out[i] = type(item) == "table" and item or item end
          return out
        end
        return v
      end,
      writeSetting = function(_, key, value) store[key] = value return true end,
      deleteSetting = function(_, key) store[key] = nil return true end,
      hasKey = function(_, key) return store[key] ~= nil end,
      -- harness affordance: inspect what the plugin persisted
      _store = store,
    }
  end
end

-- ---------------------------------------------------------------- Menu capture
-- The important piece. A capturing Menu records the spec the plugin passed to
-- it, so a harness can assert on the list the plugin actually built -- title,
-- item text, cover fields, callbacks -- without a widget tree.
--
-- Menu:extend() is supported because the plugin's own menus derive from Menu.
function support.capturing_menu(record)
  record = record or {}
  record.specs = record.specs or {}
  record.shown = record.shown or {}
  record.closed = record.closed or {}

  local Menu = {}

  Menu.new = function(_, spec)
    spec = spec or {}
    spec.item_table = spec.item_table or {}
    spec._is_menu = true
    -- menus are paged and painted by KOReader; record enough that a harness can
    -- drive the same entry points the real widget would
    spec.updateItems = spec.updateItems or function(self, n) self.itemnum = n return n end
    spec.switchItemTable = spec.switchItemTable or function(self, _, items)
      self.item_table = items or {}
    end
    spec.onShow = spec.onShow or function() end
    spec.onClose = spec.onClose or function() end
    spec.free = spec.free or function() end
    spec.getSize = spec.getSize or function() return { w = 600, h = 800 } end
    spec.paintTo = spec.paintTo or function() end
    table.insert(record.specs, spec)
    return spec
  end

  Menu.extend = function()
    local child = {}
    setmetatable(child, { __index = Menu })
    child.__index = child
    child.new = function(_, spec)
      spec = spec or {}
      return Menu.new(child, spec)
    end
    return child
  end

  Menu.getMenuText = function(text, ...)
    if text == nil then return nil end
    return tostring(text)
  end

  return Menu, record
end

-- ---------------------------------------------------------------- source extraction
-- Pull a named function out of a source file and compile it against a supplied
-- environment. Testing the real definition rather than a transcription of it is
-- deliberate: a copy can drift, and then the test passes while the plugin
-- breaks.
function support.extract_block(path, pattern)
  local f = assert(io.open(path, "r"), "cannot open " .. tostring(path))
  local src = f:read("*a")
  f:close()
  local block = src:match(pattern)
  assert(block, "could not extract block from " .. tostring(path) .. " with " .. tostring(pattern))
  return block
end

-- Load a real plugin module with a controlled require, so a harness can supply
-- its own KOReader stubs and capture what the module reaches for.
function support.load_module(name, env_overrides)
  local env = env_overrides or {}
  local real_require = _G.require

  local module = {}
  setmetatable(module, { __index = _G })

  local chunk = assert(loadfile(name))
  if setfenv then
    setfenv(chunk, env)
  end
  chunk()
  return module, env
end

return support
