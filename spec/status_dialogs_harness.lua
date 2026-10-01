-- status_dialogs: the loading / error / info / retry surfaces every screen uses.
--
-- These exist because the plugin had none of them: each screen improvised, and
-- four paths blocked on the network before showing anything at all. The module
-- under test is pure-ish -- it builds KOReader widgets and shows them -- so the
-- harness stubs the UIManager boundary and captures what was handed to the real
-- InfoMessage / ConfirmBox constructors. Asserting on the constructor args tests
-- the code this plugin actually wrote, rather than trying to make KOReader's
-- widget tree execute under plain Lua.

local ROOT = arg[1] or "."
package.path = ROOT .. "/spec/?.lua;" .. package.path

local support = require("support")
local r = support.reporter()

-- ---------------------------------------------------------------- stubs
-- Record every widget the module shows, and every close, in order. A harness
-- that only counted them could not tell "closed the loading message" from
-- "closed the wrong widget".
local shown, closed = {}, {}

package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w) closed[#closed + 1] = w end,
    setDirty = function() end,
    -- isWidgetShown is what the show-then-fetch paths guard on before touching a
    -- widget that may have been closed while the request was in flight.
    isWidgetShown = function(_, w)
      for _, s in ipairs(shown) do if s == w then return true end end
      return false
    end,
  }
end

package.preload["ui/widget/infomessage"] = function()
  local M = {}
  M.new = function(_, o)
    o = o or {}
    o.__widget = "InfoMessage"
    -- KOReader's InfoMessage has a close(); SD.close prefers it over
    -- UIManager:close when present, and a harness that omits it would silently
    -- exercise the other branch.
    o.close = function(self) closed[#closed + 1] = self end
    return o
  end
  return M
end

package.preload["ui/widget/confirmbox"] = function()
  local M = {}
  M.new = function(_, o)
    o = o or {}
    o.__widget = "ConfirmBox"
    return o
  end
  return M
end

package.preload["logger"] = function()
  return { dbg = function() end, info = function() end,
           warn = function() end, err = function() end }
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end

local SD = dofile(ROOT .. "/hardcover/lib/ui/status_dialogs.lua")

local function last_shown()
  return shown[#shown]
end

-- ---------------------------------------------------------------- loading
r.check("loading builds an InfoMessage", (function()
  local msg = SD.loading("Loading your shelf…")
  return msg and msg.__widget == "InfoMessage"
end)(), "loading did not return an InfoMessage")

local msg = last_shown()
r.check("loading keeps the text", msg.text:find("Loading your shelf", 1, true) ~= nil,
        "text was " .. tostring(msg.text))
r.check("loading is not dismissable", msg.dismissable == false,
        "dismissable was " .. tostring(msg.dismissable))
r.check("loading hides the icon", msg.show_icon == false,
        "show_icon was " .. tostring(msg.show_icon))

-- force_one_line makes InfoMessage:init shrink the font and re-run init(). A
-- plugin that patches InfoMessage.init (appearance.koplugin does) reassigns the
-- font every call, so the loop never converges and KOReader dies with a stack
-- overflow. It is asserted absent because it is invisible until it kills a
-- device, and the natural thing to write when making a message fit is to add it.
r.check("loading avoids force_one_line", msg.force_one_line == nil,
        "force_one_line is set; this crashes KOReader when another plugin patches InfoMessage")

-- ---------------------------------------------------------------- close
local before = #closed
SD.close(msg)
r.check("close closes the widget it was given", #closed == before + 1,
        "closed " .. tostring(#closed - before) .. " widgets")
r.check("close tolerates nil", (function()
  local ok = pcall(SD.close, nil)
  return ok
end)(), "SD.close(nil) raised")

-- A widget with no close() must still be closable, or a screen that forgets to
-- return the widget leaves its loading message stuck on the panel forever.
local orphan = { __widget = "InfoMessage" }
local before2 = #closed
SD.close(orphan)
r.check("close falls back to UIManager:close", #closed == before2 + 1
        and closed[#closed] == orphan,
        "a widget without close() was not passed to UIManager:close")

-- ---------------------------------------------------------------- error
shown = {}
SD.error("Could not load your list")
local err = last_shown()
r.check("error shows an InfoMessage", err and err.__widget == "InfoMessage")
-- Without the icon every error renders as an ordinary notice, which is the
-- whole difference between "your list failed" and a passing notice.
r.check("error carries the warning icon", err.icon == "notice-warning",
        "icon was " .. tostring(err.icon))
r.check("error has a timeout", type(err.timeout) == "number" and err.timeout > 0,
        "timeout was " .. tostring(err.timeout))

-- ---------------------------------------------------------------- info
shown = {}
SD.info("Saved")
local info = last_shown()
r.check("info shows without an icon", info and info.icon == nil,
        "a plain notice should not claim to be a warning")
r.check("info has a timeout", type(info.timeout) == "number" and info.timeout > 0)

-- ---------------------------------------------------------------- confirm
shown = {}
local retried, cancelled = false, false
SD.confirm{
  text = "Are you sure",
  ok_callback = function() retried = true end,
  cancel_callback = function() cancelled = true end,
}
local box = last_shown()
r.check("confirm shows a ConfirmBox", box and box.__widget == "ConfirmBox")
r.check("confirm defaults ok_text", box.ok_text == "OK", "ok_text was " .. tostring(box.ok_text))
r.check("confirm defaults cancel_text", box.cancel_text == "Cancel",
        "cancel_text was " .. tostring(box.cancel_text))
box.ok_callback()
box.cancel_callback()
r.check("confirm ok_callback runs", retried)
r.check("confirm cancel_callback runs", cancelled)

-- ---------------------------------------------------------------- retry
shown = {}
local again = false
SD.retry("network unreachable", "Loading your shelf", function() again = true end,
         function() end)
local rb = last_shown()
r.check("retry shows a ConfirmBox", rb and rb.__widget == "ConfirmBox")
r.check("retry offers a Retry button", rb.ok_text == "Retry",
        "ok_text was " .. tostring(rb.ok_text))
-- The operation name is interpolated as an object, never as a subject: a
-- translated sentence that makes it the subject disagrees in most languages
-- ("Kommentare ist fehlgeschlagen"), which is how ten of z-library's fourteen
-- locales ended up wrong before the frame was rewritten.
r.check("retry names the operation as an object",
        rb.text:find('"Loading your shelf"', 1, true) ~= nil,
        "text was " .. tostring(rb.text))
r.check("retry carries the underlying error",
        rb.text:find("network unreachable", 1, true) ~= nil,
        "the error text was dropped, so every failure reads the same")
r.check("retry runs the retry callback", (function()
  rb.ok_callback()
  return again
end)())

-- The message must not claim a cause it cannot support. An earlier version of
-- this helper always said "temporary issue", which is wrong for a DNS failure
-- or a walled mirror -- the two cases retrying cannot fix.
r.check("retry does not assert the failure is temporary",
        rb.text:find("temporary issue", 1, true) == nil,
        "hard-codes a cause that is often wrong")

r.finish()