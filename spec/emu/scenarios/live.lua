--[[--
The real Hardcover API, rendered by the real plugin in the real KOReader.

Every other scenario runs on canned responses. This one sends the plugin's own
queries to api.hardcover.app with an access token you supply, and draws what
comes back: Home, each shelf, a book's details and its series. It catches what
fixtures cannot -- a field shaped differently than assumed, a query the server
rejects, a layout that only breaks on real titles and covers.

Opt in with a token file (JSON with an "access_token" key, as the OAuth sign-in
stores it):

    KO_LIVE_TOKEN_FILE=/path/tokens.json spec/emu/run.sh live

Without it the scenario does nothing, so it never runs in CI. The token is read
here and handed to curl in a header file; it is never printed or logged, and
the request log records only the operation name, status and size.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function read_token(path)
  local f = assert(io.open(path, "r"), "cannot read " .. path)
  local body = f:read("*a")
  f:close()
  return assert(body:match('"access_token"%s*:%s*"([^"]+)"'), "no access_token in " .. path)
end

return {
  name = "live",

  run = function(emu)
    local token_file = os.getenv("KO_LIVE_TOKEN_FILE")
    if not token_file or token_file == "" then
      print("  live: KO_LIVE_TOKEN_FILE not set; skipping")
      return
    end
    local out = os.getenv("KO_LIVE_OUT") or "/tmp"
    local token = read_token(token_file)

    local Api = require("hardcover/lib/hardcover_api")
    local json = require("json")
    local log = assert(io.open(out .. "/live_requests.log", "w"))

    -- A synchronous request to the real API. curl reads its headers from a file
    -- (mode 0600) so the token is never on a command line.
    local headers_path = out .. "/live_headers.txt"
    local hf = assert(io.open(headers_path, "w"))
    os.execute("chmod 600 '" .. headers_path .. "'")
    hf:write("Authorization: Bearer " .. token .. "\ncontent-type: application/json\n")
    hf:close()
    local body_path = out .. "/live_body.json"

    function Api:query(query, parameters)
      local bf = assert(io.open(body_path, "w"))
      bf:write(json.encode({ query = query, variables = parameters }))
      bf:close()
      local p = io.popen("curl -s -m 30 -w '\\n%{http_code}' -X POST https://api.hardcover.app/v1/graphql "
        .. "-H @" .. headers_path .. " --data-binary @" .. body_path)
      local raw = p:read("*a")
      p:close()
      local content, code = raw:match("^(.*)\n(%d+)$")
      local op = query:match("(%a+)%s*%(") or query:match("{%s*(%a+)") or "?"
      log:write(string.format("%s %s %d bytes\n", code or "?", op, #(content or "")))
      if os.getenv("KO_LIVE_DEBUG") then log:write(content or "", "\n") end
      log:flush()
      if not content then return nil, { completed = false } end
      local ok, data = pcall(json.decode, content, json.decode.simple) -- nulls become nil, as in the plugin
      if not ok or type(data) ~= "table" then return nil, { status = tonumber(code) } end
      if data.data then return data.data end
      return nil, { errors = data.errors or { data.error }, status = tonumber(code) }
    end
    Api.enabled = true

    local settings = fixtures.real_settings(emu)
    require("hardcover/lib/user").settings = settings

    local me = Api:me()
    assert(me and me.id, "the API did not return who you are: check the token")
    print("  live: signed in as user id " .. tostring(me.id))
    -- the fixture settings carry a made-up user id; use the real one
    settings:updateSetting(require("hardcover/lib/constants/settings").USER_ID, me.id)

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_live.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
    }

    -- Home: counts and the reading list, from the server
    manager:showHome()
    emu:pump()
    emu:shot("live_home")
    emu:closeAll()

    -- The shelves
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
    local first_book_id, series_book_id
    for _, shelf in ipairs({
      { HARDCOVER.STATUS.READING, "Currently Reading" },
      { HARDCOVER.STATUS.TO_READ, "Want to Read" },
      { HARDCOVER.STATUS.FINISHED, "Read" },
    }) do
      manager:showShelf(shelf[1], shelf[2])
      -- a long shelf takes many requests, and a rate-limited one waits between
      -- them in real time: give it up to a minute to finish
      local deadline = os.time() + 60
      repeat
        emu:pump(200)
        local d = manager.shelf_dialog
        local done = d and d.entries and #d.entries > 0 and not d.has_more
        if not done then os.execute("sleep 1") end
      until done or os.time() > deadline
      local dialog = manager.shelf_dialog
      if dialog and dialog.entries and #dialog.entries > 0 then
        print(string.format("  live: %s has %d books loaded", shelf[2], #dialog.entries))
        first_book_id = first_book_id or dialog.entries[1].book_id
        for _, e in ipairs(dialog.entries) do
          if not series_book_id and e.book_series and e.book_series[1] then series_book_id = e.book_id end
        end
      else
        print("  live: " .. shelf[2] .. " is empty")
      end
      emu:shot("live_shelf_" .. shelf[2]:gsub("%s", "_"):lower())
      emu:closeAll()
    end

    -- Details, and the series carousel
    for label, id in pairs({ plain = first_book_id, series = series_book_id }) do
      if id then
        manager:showBookDetail(id)
        emu:pump(200)
        emu:shot("live_detail_" .. label)
        emu:closeAll()
      end
    end

    -- Search, the way the home screen's Search books does it
    local found = Api:findBooks("earthsea", nil, me.id)
    assert(found and #found > 0, "searching the real API for 'earthsea' found nothing")
    print(string.format("  live: search found %d books, first: %s", #found, tostring(found[1].title)))
    manager:showSearchResults("earthsea", found)
    emu:pump(200)
    emu:shot("live_search_results")
    emu:closeAll()

    log:close()
    os.remove(headers_path)
    os.remove(body_path)
  end,
}
