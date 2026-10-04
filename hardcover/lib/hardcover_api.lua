local config = require("hardcover/lib/config")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local _t = require("hardcover/lib/table_util")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local Network = require("hardcover/lib/network")
local UIManager = require("ui/uimanager")
local socketutil = require("socketutil")

local Book = require("hardcover/lib/book")
local Goals = require("hardcover/lib/goals")
local Lists = require("hardcover/lib/lists")
local Recommendations = require("hardcover/lib/recommendations")
local Vibes = require("hardcover/lib/vibes")
local Shelf = require("hardcover/lib/shelf")
local VERSION = require("hardcover_version")

local api_url = "https://api.hardcover.app/v1/graphql"

local user_agent = T("hardcoversync.koplugin/%1 (https://github.com/CaptainCamin/HardcoverSync.koplugin)",
  VERSION.text or table.concat(VERSION, "."))

local HardcoverApi = {
  enabled = true
}

--
-- Resolve the Bearer token for one request.
--
-- Auth (OAuth) is set on the module by main.lua. When it is absent -- which is
-- the case for the spec harness -- fall back to the static token from
-- hardcover_config.lua, which is how the plugin worked before OAuth.
--
local function bearer_token()
  if HardcoverApi.auth then
    return HardcoverApi.auth:accessToken(config.token)
  end

  return config.token
end

local function request_headers()
  local token = bearer_token()

  if not token then
    -- no credential at all: the caller decides whether that is fatal
    return { ["Content-Type"] = "application/json", ["User-Agent"] = user_agent }
  end

  return {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = user_agent,
    Authorization = "Bearer " .. token,
  }
end

local book_fragment = [[
fragment BookParts on books {
  book_id: id
  title
  release_year
  users_read_count
  pages
  book_series {
    position
    series {
      name
    }
  }
  contributions: cached_contributors
  cached_image
  user_books(where: { user_id: { _eq: $userId }}) {
    id
  }
}]]

local edition_fragment = book_fragment .. [[
fragment EditionParts on editions {
  id
  book {
    ...BookParts
  }
  cached_image
  edition_format
  language {
    code2
    language
  }
  pages
  publisher {
    name
  }
  release_date
  reading_format_id
  title
  users_count
}]]

local user_book_fragment = [[
fragment UserBookParts on user_books {
  id
  book_id
  status_id
  edition_id
  privacy_setting_id
  rating
  user_book_reads(order_by: {id: asc}) {
    id
    started_at
    finished_at
    progress_pages
    edition_id
  }
}]]

function HardcoverApi:me()
  local result = self:query([[{
    me {
      id
      account_privacy_setting_id
    }
  }]])

  if result and result.me then
    return result.me[1]
  end
  return {}
end

-- `background` is for what the reader did not ask for and is not waiting on (the series
-- and similar books strips): KOReader cancels a request in flight when the screen is
-- touched, and scrolling the page counts, so such a request must not be cancellable.
function HardcoverApi:query(query, parameters, background)
  if not Network.connected() or not self.enabled then
    return
  end

  local completed, success, content

  -- Resolve the token HERE, in the parent. The request runs in a forked
  -- subprocess, and resolving the token may refresh it: a refresh done in the
  -- child persists the new rotated tokens to disk but never reaches this
  -- process's memory, so the parent would refresh again with the now-spent
  -- refresh token. Hardcover treats that replay as theft and revokes the whole
  -- chain, forcing a fresh sign in.
  local headers = request_headers()

  completed, content = Trapper:dismissableRunInSubprocess(function()
    return self:_query(query, parameters, headers)
  end, background and {} or true, true)

  if completed and content then
    local code, response = string.match(content, "^([^:]*):(.*)")
    if string.find(code, "^%d%d%d") then
      -- 401 means the token we sent was rejected. With OAuth that is usually
      -- just an expiry we can recover from, so invalidate it and let the next
      -- call refresh rather than failing outright.
      if code == "401" and self.auth then
        self.auth:invalidateAccessToken()
      end

      -- A CDN error page (502/503/429) is HTML or empty, not JSON. Decoding
      -- that must not throw: the caller would lose the update instead of
      -- queueing it.
      local decoded, data = pcall(json.decode, response, json.decode.simple)
      if not decoded or type(data) ~= "table" then
        return nil, { status = tonumber(code) }
      end

      if data.data then
        return data.data
      elseif data.errors or data.error then
        local err = data.errors or { data.error }
        if self.on_error then
          for _, e in ipairs(err) do
            self.on_error(e)
          end
        end

        return nil, { errors = err, status = tonumber(code) }
      end
    else
      return nil, { completed = false }
    end
  else
    return nil, { completed = completed }
  end
end

function HardcoverApi:_query(query, parameters, headers)
  local requestBody = {
    query = query,
    variables = parameters
  }

  local maxtime = 12
  local timeout = 6

  local sink = {}
  socketutil:set_timeout(timeout, maxtime or 30)
  local request = {
    url = api_url,
    method = "POST",
    headers = headers or request_headers(),
    source = ltn12.source.string(json.encode(requestBody)),
    sink = socketutil.table_sink(sink),
  }

  local _, code, _headers, _status = http.request(request)
  socketutil:reset_timeout()

  local content = table.concat(sink) -- empty or content accumulated till now
  --logger.warn(requestBody)
  if code == socketutil.TIMEOUT_CODE or
    code == socketutil.SSL_HANDSHAKE_CODE or
    code == socketutil.SINK_TIMEOUT_CODE
  then
    logger.warn("request interrupted:", code)
    return code .. ':'
  end

  if type(code) == "string" then
    logger.dbg("Request error", code)
  end

  if type(code) == "number" and (code < 200 or code > 299) then
    logger.dbg("Request error", code, content)
  end

  return code .. ':' .. content
end

function HardcoverApi:hydrateBooks(ids, user_id)
  if #ids == 0 then
    return {}
  end

  -- hydrate ids
  local bookQuery = [[
    query ($ids: [Int!], $userId: Int!) {
      books(where: { id: { _in: $ids }}) {
        ...BookParts
      }
    }
  ]] .. book_fragment

  local books = self:query(bookQuery, { ids = ids, userId = user_id })
  if books then
    local list = books.books

    if #list > 1 then
      local id_order = {}

      for i, v in ipairs(ids) do
        id_order[v] = i
      end

      -- sort books by original ID order
      table.sort(list, function(a, b)
        return id_order[a.book_id] < id_order[b.book_id]
      end)
    end

    return list
  end
end

function HardcoverApi:hydrateBookFromEdition(edition_id, user_id)
  local editionSearch = [[
    query ($id Int!, $userId: Int!) {
      editions(where: { id: { _eq: $id }}) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local editions = self:query(editionSearch, { id = edition_id, userId = user_id })
  if editions and editions.editions and #editions.editions > 0 then
    return self:normalizedEdition(editions.editions[1])
  end
end

function HardcoverApi:findBookBySlug(slug, user_id)
  local slugSearch = [[
    query ($slug: String!, $userId: Int!) {
      books(where: { slug: { _eq: $slug }}) {
        ...BookParts
      }
    }]] .. book_fragment

  local books = self:query(slugSearch, { slug = slug, userId = user_id })
  if books and books.books and #books.books > 0 then
    return books.books[1]
  end
end

function HardcoverApi:findEditions(book_id, user_id)
  local edition_search = [[
    query ($id: Int!, $userId: Int!) {
      editions(where: { book_id: { _eq: $id }, _or: [{reading_format_id: { _is_null: true }}, {reading_format_id: { _neq: 2 }} ]},
      order_by: { users_count: desc_nulls_last }) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local editions = self:query(edition_search, { id = book_id, userId = user_id })
  if not editions or not editions.editions then
    return {}
  end
  local edition_list = editions.editions

  if #edition_list > 1 then
    -- prefer editions with user reads
    local edition_ids = _t.map(edition_list, function(edition)
      return edition.id
    end)

    local read_search = [[
      query ($ids: [Int!], $userId: Int!) {
        user_books(where: { edition_id: { _in: $ids }, user_id: { _eq: $userId }}) {
          edition_id
        }
      }
    ]]

    local read_editions = self:query(read_search, { ids = edition_ids, userId = user_id })
    if not read_editions then
      return nil
    end
    local read_index = {}
    for _, read in ipairs(read_editions) do
      read_index[read.edition_id] = true
    end

    table.sort(edition_list, function(a, b)
      -- sort by user reads
      local read_a = read_index[a.id]
      local read_b = read_index[b.id]

      if read_a ~= read_b then
        return read_a == true
      end

      if a.reading_format_id ~= b.reading_format_id then
        return a.reading_format_id == 4
      end

      if a.users_count ~= b.users_count then
        return a.users_count > b.users_count
      end
    end)
  end

  return _t.map(edition_list, function(edition)
    return self:normalizedEdition(edition)
  end)
end

function HardcoverApi:search(title, author, userId, page)
  page = page or 1
  local query = [[
    query ($query: String!, $page: Int!) {
      search(query: $query, per_page: 25, page: $page, query_type: "Book") {
        ids
      }
    }]]
  local search = title .. " " .. (author or "")
  local results, error = self:query(query, { query = search, page = page })
  if error then
    return nil, error
  end

  if not results or not _t.dig(results, "search", "ids") then
    return {}
  end

  local ids = _t.map(results.search.ids, function(id) return tonumber(id) end)
  return self:hydrateBooks(ids, userId)
end

function HardcoverApi:findBookByIdentifiers(identifiers, user_id)
  local isbnKey

  if identifiers.edition_id then
    local book = self:hydrateBookFromEdition(identifiers.edition_id, user_id)
    if book then
      return book
    end
  end

  if identifiers.book_slug then
    local book = self:findBookBySlug(identifiers.book_slug, user_id)
    if book then
      return book
    end
  end

  if identifiers.isbn_13 then
    isbnKey = 'isbn_13'
  elseif identifiers.isbn_10 then
    isbnKey = 'isbn_10'
  end

  if isbnKey then
    local editionSearch = [[
      query ($isbn: String!, $userId: Int!) {
        editions(where: { ]] .. isbnKey .. [[: { _eq: $isbn }}) {
          ...EditionParts
        }
      }]] .. edition_fragment

    local editions = self:query(editionSearch, { isbn = tostring(identifiers[isbnKey]), userId = user_id })
    if editions and editions.editions and #editions.editions > 0 then
      return self:normalizedEdition(editions.editions[1])
    end
  end
end

function HardcoverApi:normalizedEdition(edition)
  local result = edition.book

  result.edition_id = edition.id
  result.edition_format = Book:editionFormatName(edition.edition_format, edition.reading_format_id)

  result.cached_image = edition.cached_image
  result.publisher = edition.publisher
  if edition.release_date then
    local year = edition.release_date:match("^(%d%d%d%d)-")
    result.release_year = year
  else
    result.release_year = nil
  end
  result.language = edition.language
  result.title = edition.title
  result.reads = edition.reads
  result.pages = edition.pages
  result.filetype = result.edition_format or "Physical Book"
  result.users_count = edition.users_count

  return result
end

function HardcoverApi:normalizeUserBookRead(user_book_read)
  local user_book = user_book_read.user_book
  user_book_read.user_book = nil
  user_book.user_book_reads = { user_book_read }
  return user_book
end

function HardcoverApi:findBooks(title, author, userId)
  if not title or string.match(title, "^%s*$") then
    return {}
  end

  title = title:gsub(":.+", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return self:search(title, author, userId)
end

function HardcoverApi:findUserBook(book_id, user_id)
  -- this may not be adequate, as (it's possible) there could be more than one read in progress? Maybe?
  local read_query = [[
    query ($id: Int!, $userId: Int!) {
      user_books(where: { book_id: { _eq: $id }, user_id: { _eq: $userId }}) {
        ...UserBookParts
      }
    }
  ]] .. user_book_fragment

  local results, err = self:query(read_query, { id = book_id, userId = user_id })
  if not results or not results.user_books then
    -- Always an error here, even offline where query gives none: callers (the
    -- sync queue) must be able to tell "could not ask" from "not on the shelf"
    return {}, err or { error = "no_response" }
  end

  return results.user_books[1]
end

function HardcoverApi:findDefaultEdition(book_id, user_id)
  -- prefer:
  -- 1. most recent matching user read
  -- 2. a user book
  -- 3. default ebook edition
  -- 4. default physical edition
  -- 5. most read book edition
  local user_edition_fragment = [[
    fragment UserEditionParts on editions {
      id
      edition_format
      reading_format_id
      pages
    }
  ]]
  local user_book_query = [[
    query ($bookId: Int!, $userId: Int!) {
      user_books(limit: 1, where: { book_id: { _eq: $bookId}, user_id: { _eq: $userId }}) {
        edition {
          ...UserEditionParts
        }
        user_book_reads(limit: 1, order_by: {id: asc}) {
          edition {
            ...UserEditionParts
          }
        }
      }
    }
  ]] .. user_edition_fragment

  local user_book_results = self:query(user_book_query, { bookId = book_id, userId = user_id })
  if user_book_results then
    local user_book = _t.dig(user_book_results, "user_books", 1)
    if user_book then
      local read_edition = _t.dig(user_book, "user_book_reads", 1, "edition")
      if read_edition then
        return read_edition
      end
      return user_book.edition
    end
  end

  local default_edition_query = [[
    query ($bookId: Int!) {
     books_by_pk(id: $bookId) {
        default_physical_edition {
          ...UserEditionParts
        }
        default_ebook_edition {
          ...UserEditionParts
        }
      }
    }
  ]] .. user_edition_fragment
  local default_edition_results = self:query(default_edition_query, { bookId = book_id })
  if default_edition_results then
    if default_edition_results.books_by_pk.default_ebook_edition then
      return default_edition_results.books_by_pk.default_ebook_edition
    end

    if default_edition_results.books_by_pk.default_physical_edition then
      return default_edition_results.books_by_pk.default_physical_edition
    end
  end

  local edition_query = [[
    query ($bookId: Int!) {
      editions(
        limit: 1
        where: {book_id: {_eq: $bookId}}
        order_by: {users_count: desc_nulls_last}
      ) {
        ...UserEditionParts
      }
    }
  ]] .. user_edition_fragment
  local edition_results = self:query(edition_query, { bookId = book_id })
  if edition_results then
    return _t.dig(edition_results, "editions", 1)
  end
end

--
-- One page of a user's shelf. `status_id` may be nil for the whole library.
-- Returns a list of normalized entries plus has_more, which the dialog uses
-- to decide whether to offer a "load more" action.
--
function HardcoverApi:getShelf(user_id, status_id, offset, limit)
  offset = offset or 0
  limit = limit or 20

  -- A nil status means "the whole library". Hasura reads `_eq: null` as
  -- "IS NULL" rather than "no filter", so the status clause is only included
  -- when a status was actually requested.
  local status_filter = ""
  local status_var = ""
  if status_id then
    status_filter = ", status_id: { _eq: $statusId }"
    status_var = "$statusId: Int, "
  end

  local query = [[
    query ($userId: Int!, ]] .. status_var .. [[$offset: Int!, $limit: Int!) {
      user_books(
        where: { user_id: { _eq: $userId } ]] .. status_filter .. [[ }
        # date_added is a date, so many books share a value, and the server may
        # order ties differently on each request: paging by offset then skips
        # some books and repeats others (607 of 613 loaded against the real
        # API). id breaks the ties.
        order_by: [{ date_added: desc }, { id: desc }]
        offset: $offset
        limit: $limit
      ) {
        id
        status_id
        rating
        date_added
        book {
          book_id: id
          title
          release_year
          pages
          users_count
          users_read_count
          rating
          ratings_count
          description
          contributions {
            author {
              name
            }
          }
          cached_image
          book_series {
            position
            series {
              name
            }
          }
        }
      }
    }
  ]]

  local results, err = self:query(query, {
    userId = user_id,
    statusId = status_id,
    offset = offset,
    limit = limit,
  })
  if not results or not results.user_books then
    return nil, err or { completed = false }
  end

  local entries = _t.map(results.user_books, function(user_book)
    return Shelf.normalizeEntry(user_book)
  end)

  -- a short page means we reached the end of the shelf
  local has_more = #results.user_books >= limit

  return entries, nil, has_more
end

--
-- Your lists and the lists you follow, each with the covers of its first books.
--
-- Everything goes through `me`, which the plugin's existing scopes allow;
-- reading a list by id, or anyone else's lists, needs read:lists and is not asked
-- for. Returns { mine = {...}, following = {...} } (see Lists.normalize), or nil
-- and the error.
--
function HardcoverApi:getLists()
  local query = [[
    query {
      me {
        lists(order_by: [{ updated_at: desc }, { id: desc }]) {
          id
          name
          books_count
          ranked
          privacy_setting_id
          list_books(order_by: [{ position: asc }, { id: asc }], limit: 3) {
            book { cached_image }
          }
        }
        followed_lists(order_by: { id: desc }) {
          list {
            id
            name
            books_count
            ranked
            user { username }
            list_books(order_by: [{ position: asc }, { id: asc }], limit: 3) {
              book { cached_image }
            }
          }
        }
      }
    }
  ]]

  local results, err = self:query(query, {})
  if not results or not results.me then
    return nil, err or { completed = false }
  end
  return Lists.normalize(results.me)
end

--
-- How many lists there are to open (yours plus the ones you follow), for the
-- home screen's tile. One small request.
--
function HardcoverApi:getListCount()
  local query = [[
    query {
      me {
        lists_aggregate { aggregate { count } }
        followed_lists { list_id }
      }
    }
  ]]
  local results, err = self:query(query, {})
  local me = results and results.me
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  if type(me) ~= "table" then
    return nil, err or { completed = false }
  end
  local mine = tonumber(_t.dig(me, "lists_aggregate", "aggregate", "count")) or 0
  local followed = type(me.followed_lists) == "table" and #me.followed_lists or 0
  return mine + followed
end

--
-- One page of a list's books, in the list's own order, as shelf entries (with
-- `rank` on a ranked list). `source` says which part of `me` the list is read
-- through: "mine" or "followed". Returns entries, nil, has_more.
--
function HardcoverApi:getListBooks(list_id, source, ranked, offset, limit)
  offset = offset or 0
  limit = limit or 100

  local book_fields = [[
    book_id: id
    title
    release_year
    pages
    users_count
    users_read_count
    rating
    ratings_count
    description
    contributions { author { name } }
    cached_image
    book_series { position series { name } }
  ]]
  local list_books = [[
    list_books(
      order_by: [{ position: asc }, { id: asc }]
      offset: $offset
      limit: $limit
    ) {
      id
      position
      date_added
      book { ]] .. book_fields .. [[ }
    }
  ]]

  local query
  if source == "followed" then
    query = [[
      query ($listId: Int!, $offset: Int!, $limit: Int!) {
        me {
          followed_lists(where: { list_id: { _eq: $listId } }) {
            list { ]] .. list_books .. [[ }
          }
        }
      }
    ]]
  else
    query = [[
      query ($listId: Int!, $offset: Int!, $limit: Int!) {
        me {
          lists(where: { id: { _eq: $listId } }) { ]] .. list_books .. [[ }
        }
      }
    ]]
  end

  local results, err = self:query(query, { listId = list_id, offset = offset, limit = limit })
  local me = results and results.me
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  if type(me) ~= "table" then
    return nil, err or { completed = false }
  end

  local rows
  if source == "followed" then
    rows = _t.dig(me, "followed_lists", 1, "list", "list_books")
  else
    rows = _t.dig(me, "lists", 1, "list_books")
  end
  if type(rows) ~= "table" then
    -- the list is gone (unfollowed, deleted): an empty page, not an error
    rows = {}
  end

  local entries = {}
  for i, list_book in ipairs(rows) do
    entries[i] = Lists.entry(list_book, ranked)
  end
  return entries, nil, #rows >= limit
end

--
-- Your reading goals, as a list (see Goals.normalize: archived ones are left out).
-- Everything about pace is worked out on the device from this and the date.
--
function HardcoverApi:getGoals()
  local query = [[
    query {
      me {
        goals(
          where: { archived: { _eq: false } }
          order_by: [{ end_date: asc }, { id: asc }]
        ) {
          id
          goal
          metric
          description
          start_date
          end_date
          progress
          archived
          privacy_setting_id
          conditions
        }
      }
    }
  ]]

  local results, err = self:query(query, {})
  local me = results and results.me
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  if type(me) ~= "table" or type(me.goals) ~= "table" then
    return nil, err or { completed = false }
  end
  return Goals.normalize(me.goals)
end

-- The fields of a goal we read back from the goal mutations: the same ones getGoals
-- reads, so what comes back is a row Goals.normalize takes.
local GOAL_FIELDS = [[
  id
  goal
  metric
  description
  start_date
  end_date
  progress
  archived
  privacy_setting_id
  conditions
]]

--
-- Make a goal (`id` nil) or change one, from a GoalInput (see Goals.input). Needs the
-- write:goals scope; without it the answer is an insufficient-scope refusal (see
-- Lists.isScopeError). Returns the saved goal as Goals.normalize shapes it, or nil and
-- the error.
--
-- A new goal with no visibility set takes the account's own setting (one extra
-- request): a private account must not get a public goal by default.
--
-- Hardcover counts a goal's progress on its side, from the books finished in its
-- period, so after a save it is asked to count again (update_goal_progress): changing
-- the dates or what is counted changes the number. If that second request fails the
-- goal is still saved, and its number is brought up to date by the next fetch.
--
function HardcoverApi:saveGoal(id, input)
  input = input or {}
  -- GoalInput requires `conditions` (the live API refuses a change without it)
  if type(input.conditions) ~= "table" then
    local copy = {}
    for k, v in pairs(input) do copy[k] = v end
    copy.conditions = {}
    input = copy
  end

  if not id and input.privacy_setting_id == nil then
    local me = self:me()
    local setting = type(me) == "table" and tonumber(me.account_privacy_setting_id) or nil
    local copy = {}
    for k, v in pairs(input) do copy[k] = v end
    copy.privacy_setting_id = setting or 1
    input = copy
  end

  local query, vars, field
  if id then
    field = "update_goal"
    query = [[
      mutation ($id: Int!, $object: GoalInput!) {
        update_goal(id: $id, object: $object) {
          id
          errors
          goal { ]] .. GOAL_FIELDS .. [[ }
        }
      }
    ]]
    vars = { id = id, object = input }
  else
    field = "insert_goal"
    query = [[
      mutation ($object: GoalInput!) {
        insert_goal(object: $object) {
          id
          errors
          goal { ]] .. GOAL_FIELDS .. [[ }
        }
      }
    ]]
    vars = { object = input }
  end

  local result, err = self:query(query, vars)
  local saved = result and result[field]
  if type(saved) ~= "table" then
    return nil, err or { completed = false }
  end
  if type(saved.errors) == "string" and saved.errors ~= "" then
    return nil, saved.errors
  end
  local goal_id = tonumber(saved.id) or (type(saved.goal) == "table" and tonumber(saved.goal.id)) or nil
  if not goal_id then
    return nil, err or { completed = false }
  end

  local function row_of(answer)
    local goal = type(answer) == "table" and answer.goal
    if type(goal) == "table" and goal[1] ~= nil then goal = goal[1] end
    return type(goal) == "table" and goal or nil
  end

  local row = row_of(saved)
  local recount = self:query([[
    mutation ($id: Int!) {
      update_goal_progress(id: $id) {
        id
        errors
        goal { ]] .. GOAL_FIELDS .. [[ }
      }
    }
  ]], { id = goal_id })
  local recounted = recount and recount.update_goal_progress
  if type(recounted) == "table" and not (type(recounted.errors) == "string" and recounted.errors ~= "") then
    row = row_of(recounted) or row
  end

  -- The real API answers an update with `goal: null` (an insert does return it), which
  -- would leave an edited goal at 0 progress until the next refresh: ask for the goal
  -- itself.
  if not row then
    local read = self:query([[
      query ($id: Int!) {
        me {
          goals(where: { id: { _eq: $id } }) { ]] .. GOAL_FIELDS .. [[ }
        }
      }
    ]], { id = goal_id })
    local me = type(read) == "table" and read.me
    if type(me) == "table" and me[1] ~= nil then me = me[1] end
    local found = type(me) == "table" and type(me.goals) == "table" and me.goals[1]
    if type(found) == "table" then row = found end
  end

  -- what Hardcover sent back, else what was sent (progress as it was, or 0 for a new goal)
  local goal = Goals.normalize({ row })[1]
  if not goal then
    goal = Goals.normalize({ {
      id = goal_id,
      goal = input.goal,
      metric = input.metric,
      description = input.description,
      start_date = input.start_date,
      end_date = input.end_date,
      progress = row and row.progress or 0,
      privacy_setting_id = input.privacy_setting_id,
      conditions = input.conditions,
    } })[1]
  end
  if not goal then
    return nil, err or { completed = false }
  end
  return goal
end

--
-- Archive a goal: it stays on Hardcover but is hidden (the same as archiving it on
-- the website), so it can be brought back. Returns true, or nil and the error.
--
function HardcoverApi:archiveGoal(goal)
  goal = type(goal) == "table" and goal or { id = goal }
  -- GoalInput requires the name, target, dates, metric and conditions on every
  -- change (checked against the live schema), so an archive sends the goal as it is,
  -- marked archived, rather than just the flag.
  local object = {
    description = goal.name or goal.description,
    metric = goal.metric,
    goal = goal.target and math.floor(tonumber(goal.target) or 0) or goal.goal,
    start_date = goal.start_date,
    end_date = goal.end_date,
    conditions = Goals.conditions(goal.conditions),
    archived = true,
  }
  if goal.privacy_setting_id ~= nil then object.privacy_setting_id = goal.privacy_setting_id end

  local result, err = self:query([[
    mutation ($id: Int!, $object: GoalInput!) {
      update_goal(id: $id, object: $object) {
        id
        errors
      }
    }
  ]], { id = goal.id, object = object })
  local out = result and result.update_goal
  if type(out) ~= "table" then
    return nil, err or { completed = false }
  end
  if type(out.errors) == "string" and out.errors ~= "" then
    return nil, out.errors
  end
  return true
end

--
-- How many books are on each of the given shelves, as { [status_id] = count }.
--
-- One aggregate per shelf, all in a single request. Each aliased aggregate counts
-- as a top-level query against the rate limit, and a request may hold at most
-- five, so that is the most shelves asked for at once.
--
function HardcoverApi:getShelfCounts(user_id, status_ids)
  if not status_ids or #status_ids == 0 or #status_ids > 5 then
    return nil
  end

  local parts = {}
  for _, id in ipairs(status_ids) do
    parts[#parts + 1] = string.format(
      "s%d: user_books_aggregate(where: { user_id: { _eq: $userId }, status_id: { _eq: %d } }) { aggregate { count } }",
      id, id)
  end

  local query = "query ($userId: Int!) {\n  " .. table.concat(parts, "\n  ") .. "\n}"

  local results, err = self:query(query, { userId = user_id })
  if not results then
    return nil, err
  end

  local counts = {}
  for _, id in ipairs(status_ids) do
    local count = tonumber(_t.dig(results, "s" .. id, "aggregate", "count"))
    if count then
      counts[id] = count
    end
  end
  return counts
end

--
-- What you are reading now, for the home screen: the most recently updated
-- books on the Currently Reading shelf, each with the progress of its latest
-- read. Entries are the shelf's own shape (Shelf.normalizeEntry) plus
-- `progress_pages` and `edition_pages`.
--
function HardcoverApi:getCurrentlyReading(user_id, limit)
  limit = limit or 5

  local query = [[
    query ($userId: Int!, $statusId: Int!, $limit: Int!) {
      user_books(
        where: { user_id: { _eq: $userId }, status_id: { _eq: $statusId } }
        order_by: { updated_at: desc }
        limit: $limit
      ) {
        id
        status_id
        book {
          book_id: id
          title
          pages
          cached_image
          contributions {
            author {
              name
            }
          }
        }
        user_book_reads(order_by: { id: desc }, limit: 1) {
          progress_pages
          edition {
            pages
          }
        }
      }
    }
  ]]

  local results, err = self:query(query, {
    userId = user_id,
    statusId = 2,
    limit = limit,
  })
  if not results or not results.user_books then
    return nil, err or { completed = false }
  end

  return _t.map(results.user_books, function(user_book)
    local entry = Shelf.normalizeEntry(user_book)
    local read = _t.dig(user_book, "user_book_reads", 1)
    if read then
      entry.progress_pages = read.progress_pages
      entry.edition_pages = _t.dig(read, "edition", "pages")
    end
    return entry
  end)
end

--
-- One page of other readers' reviews of a book, most liked first.
--
-- Returns the raw user_books rows (see Reviews.normalizeAll), or nil and the
-- error. `id` is a final tie-break: offset paging over rows that tie on
-- likes_count and reviewed_at (reviewed_at is often null) otherwise skips and
-- repeats rows from one page to the next. Needs the read:social scope.
--
function HardcoverApi:getReviews(book_id, limit, offset)
  local query = [[
    query ($bookId: Int!, $limit: Int!, $offset: Int!) {
      user_books(
        where: { book_id: { _eq: $bookId }, has_review: { _eq: true } }
        order_by: [{ likes_count: desc }, { reviewed_at: desc }, { id: desc }]
        limit: $limit
        offset: $offset
      ) {
        id
        rating
        review_raw
        review_has_spoilers
        review_length
        likes_count
        reviewed_at
        user {
          username
          name
        }
      }
    }
  ]]

  local results, err = self:query(query, {
    bookId = book_id,
    limit = limit or 10,
    offset = offset or 0,
  })
  if not results or not results.user_books then
    return nil, err or { completed = false }
  end

  return results.user_books
end

--
-- Books like this one: Hardcover's own similar-books ranking for `book_id`, as shelf
-- entries in rank order. Two requests (the ids, then the books for them), both with
-- the permissions the plugin already has. Returns entries, or nil, err. A book with
-- no ranking yet gives an empty list, not an error.
--
function HardcoverApi:getSimilarBooks(book_id, limit)
  local first, err = self:query([[
    query ($bookId: Int!) {
      books_by_pk(id: $bookId) { cached_similar_book_ids }
    }
  ]], { bookId = book_id }, true)
  local book = first and first.books_by_pk
  if type(book) == "table" and book[1] ~= nil then book = book[1] end
  if first == nil or (type(book) ~= "table" and first.books_by_pk ~= nil) then
    return nil, err or { completed = false }
  end

  local ids = Recommendations.ids(type(book) == "table" and book.cached_similar_book_ids, limit)
  if #ids == 0 then return {} end

  return self:getBooksByIds(ids)
end

--
-- The books for `ids`, as shelf entries in the order of `ids` (the API returns them in
-- any order, and leaves out ones it does not know). One request. nil and the error when
-- it fails.
--
function HardcoverApi:getBooksByIds(ids)
  if #ids == 0 then return {} end
  local result, err = self:query([[
    query ($ids: [Int!]) {
      books(where: { id: { _in: $ids } }) {
        book_id: id
        title
        release_year
        pages
        users_count
        users_read_count
        rating
        ratings_count
        description
        contributions { author { name } }
        cached_image
        book_series { position series { name } }
      }
    }
  ]], { ids = ids }, true)
  if result == nil or type(result.books) ~= "table" then
    return nil, err or { completed = false }
  end
  return Recommendations.entries(ids, result.books)
end

--
-- "For you": books suggested from the ones you rated 4 or more, computed here from
-- Hardcover's similar-books rankings (see Recommendations.score). Two requests: your
-- best-rated books with their rankings and the ids of your whole library, then the books
-- for the top ids. Each entry carries `reason`, the title of the book it came from. Returns
-- entries (empty, with the note "no_ratings", when nothing is rated 4 or more yet), or
-- nil and the error.
--
function HardcoverApi:getForYou(limit)
  local first, err = self:query([[
    query {
      me {
        seeds: user_books(where: { rating: { _gte: 4 } }, order_by: { updated_at: desc }, limit: 15) {
          rating
          book { id title cached_similar_book_ids }
        }
        own: user_books { book_id }
      }
    }
  ]], nil, true)
  local me = first and first.me
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  if type(me) ~= "table" then return nil, err or { completed = false } end

  local seeds = type(me.seeds) == "table" and me.seeds or {}
  if #seeds == 0 then return {}, nil, "no_ratings" end
  local own = {}
  for _, row in ipairs(type(me.own) == "table" and me.own or {}) do own[#own + 1] = row.book_id end

  local picks = Recommendations.score(seeds, own, limit or Recommendations.LIMIT)
  local ids, reasons = {}, {}
  for _, pick in ipairs(picks) do
    ids[#ids + 1] = pick.id
    reasons[pick.id] = pick.reason
  end
  local entries, err2 = self:getBooksByIds(ids)
  if entries == nil then return nil, err2 end
  for _, entry in ipairs(entries) do
    entry.reason = reasons[entry.book_id] -- the title of the book it was suggested for
  end
  return entries
end


--
-- Full detail for one book, including description and community rating.
-- `edition_id` is optional; when given, edition level fields are included.
--
function HardcoverApi:getBookDetail(book_id, user_id, edition_id)
  local query

  if edition_id then
    query = [[
      query ($editionId: Int!, $userId: Int!) {
        editions(where: { id: { _eq: $editionId } }) {
          id
          edition_format
          reading_format_id
          pages
          isbn_13
          isbn_10
          release_date
          publisher {
            name
          }
          language {
            code2
            language
          }
          book {
            book_id: id
            title
            subtitle
            cached_image
            release_year
            pages
            users_count
            users_read_count
            rating
            ratings_count
            description
            contributions {
              author {
                name
              }
            }
            book_series {
              position
              series {
                id
                name
              }
            }
            user_books(where: { user_id: { _eq: $userId }}) {
              id
              status_id
              rating
            }
          }
        }
      }
    ]]
  else
    query = [[
      query ($bookId: Int!, $userId: Int!) {
        books(where: { id: { _eq: $bookId } }) {
          book_id: id
          title
          subtitle
          release_year
          pages
          users_count
          users_read_count
          rating
          ratings_count
          description
          contributions {
            author {
              name
            }
          }
          cached_image
          book_series {
            position
            series {
              id
              name
            }
          }
          user_books(where: { user_id: { _eq: $userId }}) {
            id
            status_id
            rating
          }
        }
      }
    ]]
  end

  -- The edition query filters on the edition, so that is the id it needs. It
  -- used to be sent the book id, so a linked edition either matched nothing
  -- ("no response", retried forever) or a different book's edition.
  local variables = { userId = user_id }
  if edition_id then
    variables.editionId = edition_id
  else
    variables.bookId = book_id
  end

  local results = self:query(query, variables)
  if not results then
    return nil
  end

  local row
  if edition_id then
    local edition = _t.dig(results, "editions", 1)
    if not edition then
      return nil
    end

    -- edition fields are more precise than the book level equivalents, so
    -- overlay them onto the book before handing it to the display layer
    row = edition.book or {}
    row.edition_id = edition.id
    row.edition_format = edition.edition_format
    row.reading_format_id = edition.reading_format_id
    row.publisher = edition.publisher
    row.language = edition.language
    row.isbn_13 = edition.isbn_13
    row.isbn_10 = edition.isbn_10
    row.release_date = edition.release_date

    if edition.pages then
      row.pages = edition.pages
    end
  else
    row = _t.dig(results, "books", 1)
  end

  if not row then
    return nil
  end

  local user_book = _t.dig(row, "user_books", 1)

  return {
    book = row,
    user_book_id = user_book and user_book.id,
    status_id = user_book and user_book.status_id,
    user_rating = user_book and user_book.rating,
  }
end

--
-- The books in a series, in order, with the reader's own status on each.
--
-- Follows Hardcover's own recipe for a clean list (see their guide "Getting All
-- Books in a Series"): leave out merged duplicates (those with a canonical
-- book), partial editions and compilations, and take the most popular book at
-- each position. Returns
--   { id, name, is_completed, books = { { book_id, title, position,
--     release_year, cover, status_id, rating }, ... } }
-- or nil (and the error) when the request fails.
--
function HardcoverApi:getSeriesBooks(series_id, user_id)
  if not series_id then return nil end

  local query = [[
    query ($seriesId: Int!, $userId: Int!) {
      series_by_pk(id: $seriesId) {
        id
        name
        is_completed
        book_series(
          where: {
            compilation: { _eq: false }
            book: { canonical_id: { _is_null: true }, is_partial_book: { _eq: false } }
          }
          distinct_on: position
          order_by: [{ position: asc }, { book: { users_count: desc } }]
        ) {
          position
          book {
            book_id: id
            title
            release_year
            cached_image
            user_books(where: { user_id: { _eq: $userId } }) {
              status_id
              rating
            }
          }
        }
      }
    }
  ]]

  local results, err = self:query(query, { seriesId = series_id, userId = user_id }, true)
  local series = results and results.series_by_pk
  if not series then
    return nil, err
  end

  local books = {}
  for _, entry in ipairs(series.book_series or {}) do
    local book = entry.book
    if book and book.book_id then
      local mine = _t.dig(book, "user_books", 1)
      books[#books + 1] = {
        book_id = book.book_id,
        title = book.title,
        position = entry.position,
        release_year = book.release_year,
        cover = Shelf.coverOf(book),
        status_id = mine and mine.status_id,
        rating = mine and mine.rating,
      }
    end
  end

  return {
    id = series.id,
    name = series.name,
    is_completed = series.is_completed,
    books = books,
  }
end

function HardcoverApi:createRead(user_book_id, edition_id, page, started_at)
  local query = [[
    mutation InsertUserBookRead($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
      insert_user_book_read(user_book_id: $id, user_book_read: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result = self:query(query, { id = user_book_id, pages = page, editionId = edition_id, startedAt = started_at })
  if result and result.insert_user_book_read then
    local user_book_read = result.insert_user_book_read.user_book_read
    return self:normalizeUserBookRead(user_book_read)
  end
end

function HardcoverApi:updatePage(user_read_id, edition_id, page, started_at)
  local query = [[
    mutation UpdateBookProgress($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
      update_user_book_read(id: $id, object: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result = self:query(query, { id = user_read_id, pages = page, editionId = edition_id, startedAt = started_at })
  if result and result.update_user_book_read then
    return self:normalizeUserBookRead(result.update_user_book_read.user_book_read)
  end
end

function HardcoverApi:updateUserBook(book_id, status_id, privacy_setting_id, edition_id)
  if not privacy_setting_id then
    local me = self:me()
    privacy_setting_id = me.account_privacy_setting_id or 1
  end

  local query = [[
    mutation ($object: UserBookCreateInput!) {
      insert_user_book(object: $object) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  local update_args = {
    book_id = book_id,
    privacy_setting_id = privacy_setting_id,
    status_id = status_id,
    edition_id = edition_id
  }

  local result, err = self:query(query, { object = update_args })
  if result and result.insert_user_book then
    local inserted = result.insert_user_book
    if inserted.user_book then
      return inserted.user_book
    end
    return nil, inserted.error
  end
  return nil, err
end

-- Take a book out of the library altogether (its status, rating and reads go
-- with it). Returns { id = user_book_id } on success.
function HardcoverApi:removeUserBook(user_book_id)
  local query = [[
    mutation ($id: Int!) {
      delete_user_book(id: $id) {
        id
      }
    }
  ]]

  local result, err = self:query(query, { id = user_book_id })
  if result and result.delete_user_book then
    return result.delete_user_book
  end
  return nil, err
end

--
-- Which of your own lists a book is on: every list of yours (id, name, size, ranked)
-- and, for each, the list_books row that is this book if it is there (its id is what
-- removing needs). The lists you follow cannot be added to, so they are not asked
-- for. Works with the scopes every sign-in has. Returns rows (see
-- Lists.membership), or nil and the error.
--
function HardcoverApi:getBookLists(book_id)
  local query = [[
    query ($bookId: Int!) {
      me {
        lists(order_by: [{ updated_at: desc }, { id: desc }]) {
          id
          name
          books_count
          ranked
          privacy_setting_id
          list_books(where: { book_id: { _eq: $bookId } }) {
            id
          }
        }
      }
    }
  ]]

  local results, err = self:query(query, { bookId = book_id })
  local me = results and results.me
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  if type(me) ~= "table" then
    return nil, err or { completed = false }
  end
  return Lists.membership(me)
end

--
-- Put a book on one of your lists (needs the write:lists scope, see Lists.WRITE_SCOPE).
-- `position` is where in the list; the caller passes the end (Lists.insertObject).
-- Returns { id = the new list_books row's id (nil if the answer did not carry
-- one) }, or nil and the error: Hardcover's own text when it refused, the request's
-- error table otherwise.
--
-- Written by analogy with insert_user_book (a payload with `error` and an id); the
-- answer is read loosely so a slightly different payload still counts as done.
--
function HardcoverApi:addToList(book_id, list_id, position)
  -- ListBookIdType is { id, list_book }: unlike insert_user_book it has no `error`
  -- field (asking for one fails the whole request on validation; checked against the
  -- API's schema). A refusal comes back as a GraphQL error instead.
  local query = [[
    mutation ($object: ListBookInput!) {
      insert_list_book(object: $object) {
        id
        list_book { id }
      }
    }
  ]]

  local result, err = self:query(query, { object = Lists.insertObject(book_id, list_id, position) })
  local inserted = result and result.insert_list_book
  if type(inserted) == "table" then
    if type(inserted.error) == "string" and inserted.error ~= "" then
      return nil, inserted.error
    end
    return { id = Lists.listBookId(inserted) }
  end
  return nil, err or { completed = false }
end

-- Take a book off a list, by the id of its list_books row. Returns { id } or nil
-- and the error.
function HardcoverApi:removeFromList(list_book_id)
  local query = [[
    mutation ($id: Int!) {
      delete_list_book(id: $id) {
        id
      }
    }
  ]]

  local result, err = self:query(query, { id = list_book_id })
  if result and type(result.delete_list_book) == "table" then
    return result.delete_list_book
  end
  return nil, err or { completed = false }
end

function HardcoverApi:updateRating(user_book_id, rating)
  local query = [[
    mutation ($id: Int!, $rating: numeric) {
      update_user_book(id: $id, object: { rating: $rating }) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  if rating == 0 or rating == nil then
    rating = json.util.null
  end

  local result = self:query(query, { id = user_book_id, rating = rating })
  if result and result.update_user_book then
    return result.update_user_book.user_book
  end
end

function HardcoverApi:removeRead(user_book_id)
  local query = [[
    mutation($id: Int!) {
      delete_user_book(id: $id) {
        id
      }
    }
  ]]
  local result = self:query(query, { id = user_book_id })
  if result then
    return result.delete_user_book
  end
end

function HardcoverApi:createJournalEntry(object)
  local query = [[
    mutation InsertReadingJournalEntry($object: ReadingJournalCreateType!) {
      insert_reading_journal(object: $object) {
        reading_journal {
          id
        }
      }
    }
  ]]

  local result = self:query(query, { object = object })
  if result then
    return result.insert_reading_journal.reading_journal
  end
end

--
-- Async wrappers.
--
-- Each one runs the call inside Trapper:wrap. That is what makes the request
-- non-blocking: inside a wrapped coroutine, query() forks a subprocess and
-- yields back to KOReader's event loop, so the screen the caller just showed
-- (a "Loading..." message, an empty dialog) actually gets painted while the
-- request is in flight, and a tap can cancel it. Outside a wrap,
-- dismissableRunInSubprocess() logs "unwrapped dismissableRunInSubprocess(),
-- falling back to blocking in-process run" and the whole UI freezes until the
-- reply arrives -- which is what these did when they merely called the
-- blocking function and delayed the callback.
--
-- Every callback is invoked through UIManager:nextTick, so a caller may touch
-- widgets directly. Callers must still check UIManager:isWidgetShown before
-- writing to a dialog: the user can close it while the request is in flight,
-- and updating a freed widget crashes.
--
-- If the call raises, the callback still fires (with no results) so a dialog
-- waiting on it shows its retry instead of loading forever; Trapper:wrap alone
-- would swallow the error and the callback would never run.
--

-- Delivers on the next UI tick. Guarded because a caller may legitimately have
-- already torn its screen down.
local function deliver(callback, ...)
  local args = { ... }
  local n = select("#", ...)
  UIManager:nextTick(function()
    callback(unpack(args, 1, n))
  end)
end

local function async(callback, fn, ...)
  local args = { ... }
  local n = select("#", ...)
  Trapper:wrap(function()
    local results = { pcall(fn, unpack(args, 1, n)) }
    if not results[1] then
      logger.warn("hardcover api: async call raised", results[2])
      deliver(callback)
      return
    end
    deliver(callback, unpack(results, 2, table.maxn(results)))
  end)
end

function HardcoverApi:saveGoalAsync(id, input, callback)
  async(callback, self.saveGoal, self, id, input)
end

function HardcoverApi:archiveGoalAsync(goal, callback)
  async(callback, self.archiveGoal, self, goal)
end

function HardcoverApi:getGoalsAsync(callback)
  async(callback, self.getGoals, self)
end

function HardcoverApi:getListsAsync(callback)
  async(callback, self.getLists, self)
end

function HardcoverApi:getBookListsAsync(book_id, callback)
  async(callback, self.getBookLists, self, book_id)
end

function HardcoverApi:addToListAsync(book_id, list_id, position, callback)
  async(callback, self.addToList, self, book_id, list_id, position)
end

function HardcoverApi:removeFromListAsync(list_book_id, callback)
  async(callback, self.removeFromList, self, list_book_id)
end

function HardcoverApi:getListCountAsync(callback)
  async(callback, self.getListCount, self)
end

function HardcoverApi:getShelfAsync(user_id, status_id, offset, limit, callback)
  async(callback, self.getShelf, self, user_id, status_id, offset, limit)
end

--
-- Your vibes (Vibes.normalize's rows), with the covers of each one's first books for the
-- index. Two requests: the vibes of yours (Hardcover's own for your account included),
-- then the covers. Needs the read:vibes permission: without it the answer is a refusal
-- (see Vibes.isScopeError). Returns vibes, cover_urls (vibe id -> urls), or nil and the error.
--
function HardcoverApi:getVibes(user_id)
  local first, err = self:query([[
    query ($userId: Int!) {
      vibes(where: { user_id: { _eq: $userId } }, order_by: [{ id: asc }]) {
        id
        title
        description
        vibe_type
        privacy_setting_id
        books_generated_at
        cached_book_ids
      }
    }
  ]], { userId = user_id }, true)
  if first == nil or type(first.vibes) ~= "table" then
    return nil, err or { completed = false }
  end

  local vibes = Vibes.normalize(first.vibes)
  local wanted, owner = {}, {}
  for _, vibe in ipairs(vibes) do
    for i = 1, math.min(Vibes.COVERS, #vibe.ids) do
      wanted[#wanted + 1] = vibe.ids[i]
      owner[vibe.ids[i]] = owner[vibe.ids[i]] or {}
      table.insert(owner[vibe.ids[i]], vibe.id)
    end
  end

  -- the covers are a nicety: a failure here still gives the index (with empty boxes)
  local covers = {}
  if #wanted > 0 then
    local second = self:query([[
      query ($ids: [Int!]) {
        books(where: { id: { _in: $ids } }) { book_id: id cached_image }
      }
    ]], { ids = wanted }, true)
    local by_id = {}
    for _, book in ipairs(second and type(second.books) == "table" and second.books or {}) do
      local cover = Shelf.coverOf(book)
      if cover then by_id[tonumber(book.book_id)] = cover.url end
    end
    for _, vibe in ipairs(vibes) do
      local urls = {}
      for i = 1, math.min(Vibes.COVERS, #vibe.ids) do
        local url = by_id[vibe.ids[i]]
        if url then urls[#urls + 1] = url end
      end
      covers[vibe.id] = urls
    end
  end
  return vibes, covers
end

-- One page of a vibe's books, in the vibe's ranking, as shelf entries (one request).
function HardcoverApi:getVibeBooks(vibe, offset, limit)
  return self:getBooksByIds(Vibes.page(vibe, offset, limit))
end

function HardcoverApi:getBooksByIdsAsync(ids, callback)
  async(callback, self.getBooksByIds, self, ids)
end

function HardcoverApi:getVibesAsync(user_id, callback)
  async(callback, self.getVibes, self, user_id)
end

function HardcoverApi:getForYouAsync(callback)
  async(callback, self.getForYou, self)
end

function HardcoverApi:getSimilarBooksAsync(book_id, callback)
  async(callback, self.getSimilarBooks, self, book_id)
end

function HardcoverApi:getBookDetailAsync(book_id, user_id, edition_id, callback)
  async(callback, self.getBookDetail, self, book_id, user_id, edition_id)
end

function HardcoverApi:getReviewsAsync(book_id, limit, offset, callback)
  async(callback, self.getReviews, self, book_id, limit, offset)
end

function HardcoverApi:updateUserBookAsync(book_id, status_id, privacy_setting_id, edition_id, callback)
  async(callback, self.updateUserBook, self, book_id, status_id, privacy_setting_id, edition_id)
end

function HardcoverApi:removeUserBookAsync(user_book_id, callback)
  async(callback, self.removeUserBook, self, user_book_id)
end

function HardcoverApi:findBooksAsync(title, author, user_id, callback)
  async(callback, self.findBooks, self, title, author, user_id)
end

function HardcoverApi:findEditionsAsync(book_id, user_id, callback)
  async(callback, self.findEditions, self, book_id, user_id)
end

function HardcoverApi:findDefaultEditionAsync(book_id, user_id, callback)
  async(callback, self.findDefaultEdition, self, book_id, user_id)
end

function HardcoverApi:findBookByIdentifiersAsync(identifiers, user_id, callback)
  async(callback, self.findBookByIdentifiers, self, identifiers, user_id)
end

return HardcoverApi
