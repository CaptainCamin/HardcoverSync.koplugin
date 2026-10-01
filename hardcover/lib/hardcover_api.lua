local config = require("hardcover/lib/config")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local _t = require("hardcover/lib/table_util")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local socketutil = require("socketutil")

local Book = require("hardcover/lib/book")
local Shelf = require("hardcover/lib/shelf")
local VERSION = require("hardcover_version")

local api_url = "https://api.hardcover.app/v1/graphql"

local user_agent = T("hardcoverapp.koplugin/%1 (https://github.com/billiam/hardcoverapp.koplugin)",
  table.concat(VERSION, "."))

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

function HardcoverApi:query(query, parameters)
  if not NetworkManager:isConnected() or not self.enabled then
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
  end, true, true)

  if completed and content then
    local code, response = string.match(content, "^([^:]*):(.*)")
    if string.find(code, "^%d%d%d") then
      -- 401 means the token we sent was rejected. With OAuth that is usually
      -- just an expiry we can recover from, so invalidate it and let the next
      -- call refresh rather than failing outright.
      if code == "401" and self.auth then
        self.auth:invalidateAccessToken()
      end

      local data = json.decode(response, json.decode.simple)
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
    return {}, err
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
        order_by: { date_added: desc }
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

  local result = self:query(query, { object = update_args })
  if result and result.insert_user_book then
    return result.insert_user_book.user_book
  end
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

function HardcoverApi:getShelfAsync(user_id, status_id, offset, limit, callback)
  async(callback, self.getShelf, self, user_id, status_id, offset, limit)
end

function HardcoverApi:getBookDetailAsync(book_id, user_id, edition_id, callback)
  async(callback, self.getBookDetail, self, book_id, user_id, edition_id)
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
