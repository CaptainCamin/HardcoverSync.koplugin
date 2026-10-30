local config = require("hardcover/lib/config")
local logger = require("logger")
local json = require("json")
local _t = require("hardcover/lib/table_util")
local T = require("ffi/util").template
local Network = require("hardcover/lib/network")

local Book = require("hardcover/lib/book")
local Journal = require("hardcover/lib/journal")
local Goals = require("hardcover/lib/goals")
local Lists = require("hardcover/lib/lists")
local Recommendations = require("hardcover/lib/recommendations")
local ReviewText = require("hardcover/lib/review_text")
local Vibes = require("hardcover/lib/vibes")
local Stats = require("hardcover/lib/stats")
local Shelf = require("hardcover/lib/shelf")
local VERSION = require("hardcover_version")

local api_url = "https://api.hardcover.app/v1/graphql"

local user_agent = T("hardcoversync.koplugin/%1 (https://github.com/CaptainCamin/HardcoverSync.koplugin)",
  VERSION.text or table.concat(VERSION, "."))

local HardcoverApi = {
  enabled = true
}

-- How a request is run and sent. These are KOReader's (runtime.lua forks it and hands the
-- answer back on the UI's tick; transport.lua does the HTTP), found when first needed so
-- that this file does not tie the layer to the UI, and a test can set
-- `HardcoverApi.runtime` / `HardcoverApi.transport` to plain-Lua fakes.
local function runtime()
  return HardcoverApi.runtime or require("hardcover/lib/runtime")
end

local function transport()
  return HardcoverApi.transport or require("hardcover/lib/transport")
end

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

-- ------------------------------------------------------------------------------
-- Requests
-- ------------------------------------------------------------------------------

function HardcoverApi:me()
  local result = self:query([[{
    me {
      id
      username
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

  completed, content = runtime().subprocess(function()
    return self:_query(query, parameters, headers)
  end, background)

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

        return nil, { errors = err, status = tonumber(code),
          message = type(data.error_description) == "string" and data.error_description ~= ""
            and data.error_description or nil }
      end
    else
      return nil, { completed = false }
    end
  else
    return nil, { completed = completed }
  end
end

-- Runs in the subprocess: send the request, return "<code>:<body>" (see transport.lua).
function HardcoverApi:_query(query, parameters, headers)
  return transport().post(api_url, headers or request_headers(), {
    query = query,
    variables = parameters,
  })
end

-- ------------------------------------------------------------------------------
-- Looking books up: the catalogue, one book's details, a series
-- ------------------------------------------------------------------------------

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
    query ($id: Int!, $userId: Int!) {
      editions(where: { id: { _eq: $id }}) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local editions, err = self:query(editionSearch, { id = edition_id, userId = user_id })
  if editions and editions.editions and #editions.editions > 0 then
    return self:normalizedEdition(editions.editions[1])
  end
  if not editions then return nil, err or { completed = false } end
end

function HardcoverApi:findBookBySlug(slug, user_id)
  local slugSearch = [[
    query ($slug: String!, $userId: Int!) {
      books(where: { slug: { _eq: $slug }}) {
        ...BookParts
      }
    }]] .. book_fragment

  local books, err = self:query(slugSearch, { slug = slug, userId = user_id })
  if books and books.books and #books.books > 0 then
    return books.books[1]
  end
  if not books then return nil, err or { completed = false } end
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

  -- no answer at all (offline, not signed in) is a failure, not "nothing found"
  if not results then
    return nil, { completed = false }
  end
  if not _t.dig(results, "search", "ids") then
    return {}
  end

  local ids = _t.map(results.search.ids, function(id) return tonumber(id) end)
  return self:hydrateBooks(ids, userId)
end

-- The book for some identifiers, or nil. When nil, a second value says the call itself failed
-- (offline, rate limit, expired token), so "Hardcover has no such book" can be told apart from "could
-- not ask". A later identifier that answers still wins over an earlier failure.
function HardcoverApi:findBookByIdentifiers(identifiers, user_id)
  local failure

  if identifiers.edition_id then
    local book, err = self:hydrateBookFromEdition(identifiers.edition_id, user_id)
    if book then
      return book
    end
    failure = failure or err
  end

  if identifiers.book_slug then
    local book, err = self:findBookBySlug(identifiers.book_slug, user_id)
    if book then
      return book
    end
    failure = failure or err
  end

  for _, isbnKey in ipairs({ 'isbn_13', 'isbn_10' }) do
    if identifiers[isbnKey] then
      local editionSearch = [[
        query ($isbn: String!, $userId: Int!) {
          editions(where: { ]] .. isbnKey .. [[: { _eq: $isbn }}) {
            ...EditionParts
          }
        }]] .. edition_fragment

      local editions, err = self:query(editionSearch, { isbn = tostring(identifiers[isbnKey]), userId = user_id })
      if editions and editions.editions and #editions.editions > 0 then
        return self:normalizedEdition(editions.editions[1])
      end
      if not editions then failure = failure or err or { completed = false } end
    end
  end

  return nil, failure
end

-- findBookByIdentifiers for many files at once: `list` is a list of parsed identifiers, and the
-- answer a list of the same length (a book, or false where Hardcover has none of that file's
-- identifiers). At most four requests however long the list: the editions, the slugs, the ISBN-13s and
-- the ISBN-10s asked for. A file's identifiers are tried in the same order as there (edition, slug,
-- ISBN-13, ISBN-10). Returns nil and an error when any request failed, as nothing is then known.
function HardcoverApi:findBooksByIdentifiers(list, user_id)
  local function collect(field)
    local values, seen = {}, {}
    for _, identifiers in ipairs(list) do
      local value = identifiers[field]
      if value ~= nil and not seen[tostring(value)] then
        seen[tostring(value)] = true
        values[#values + 1] = value
      end
    end
    return values
  end

  -- one request: the rows of `field` (a Hardcover column of the table) in `values`, keyed by it
  local function ask(table_name, column, variable_type, values, fragment_name, fragment)
    local out = {}
    if #values == 0 then return out end
    local results, err = self:query([[
      query ($values: []] .. variable_type .. [[!], $userId: Int!) {
        ]] .. table_name .. [[(where: { ]] .. column .. [[: { _in: $values }}) {
          ]] .. column .. [[
          ...]] .. fragment_name .. [[

        }
      }]] .. fragment, { values = values, userId = user_id })
    if not results then return nil, err or { completed = false } end
    for _, row in ipairs(results[table_name] or {}) do
      local key = tostring(row[column])
      -- the first row for a value wins, as it does for one book
      if out[key] == nil then out[key] = row end
    end
    return out
  end

  local editions, err = ask("editions", "id", "Int", collect("edition_id"), "EditionParts", edition_fragment)
  if not editions then return nil, err end
  local slugs
  slugs, err = ask("books", "slug", "String", collect("book_slug"), "BookParts", book_fragment)
  if not slugs then return nil, err end
  local isbn13
  isbn13, err = ask("editions", "isbn_13", "String", collect("isbn_13"), "EditionParts", edition_fragment)
  if not isbn13 then return nil, err end
  local isbn10
  isbn10, err = ask("editions", "isbn_10", "String", collect("isbn_10"), "EditionParts", edition_fragment)
  if not isbn10 then return nil, err end

  local answers = {}
  for i, identifiers in ipairs(list) do
    local by_edition = identifiers.edition_id and editions[tostring(identifiers.edition_id)]
    local by_slug = identifiers.book_slug and slugs[tostring(identifiers.book_slug)]
    local by_isbn = (identifiers.isbn_13 and isbn13[tostring(identifiers.isbn_13)])
      or (identifiers.isbn_10 and isbn10[tostring(identifiers.isbn_10)])
    if by_edition then
      answers[i] = self:normalizedEdition(by_edition)
    elseif by_slug then
      answers[i] = by_slug
    elseif by_isbn then
      answers[i] = self:normalizedEdition(by_isbn)
    else
      answers[i] = false
    end
  end
  return answers
end

-- Books whose title is exactly one of `titles`, in one request: a table from each title to its books
-- (most read first; a title with none is absent). Only a title spelled as Hardcover spells it is found,
-- so this is a quick first try before a search, which also finds the loose spellings. At most
-- TITLE_ROWS books come back in all, so a batch of very common titles may miss some: those are then
-- searched for as usual. Returns nil and an error when the call failed.
HardcoverApi.TITLE_ROWS = 200
function HardcoverApi:findBooksByTitles(titles, user_id)
  local out = {}
  if #titles == 0 then return out end
  local results, err = self:query([[
    query ($titles: [String!], $userId: Int!) {
      books(where: { title: { _in: $titles }}, order_by: { users_read_count: desc_nulls_last }, limit: ]]
      .. HardcoverApi.TITLE_ROWS .. [[) {
        ...BookParts
      }
    }]] .. book_fragment, { titles = titles, userId = user_id })
  if not results then return nil, err or { completed = false } end
  for _, book in ipairs(results.books or {}) do
    out[book.title] = out[book.title] or {}
    table.insert(out[book.title], book)
  end
  return out
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

-- Hardcover answers a read it does not know (a deleted or wrong id) with an error and no read.
function HardcoverApi:normalizeUserBookRead(user_book_read)
  if type(user_book_read) ~= "table" or type(user_book_read.user_book) ~= "table" then
    return nil
  end
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
        user_book_reads(order_by: {id: asc}) {
          finished_at
          progress_pages
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
      local read = Book:currentRead(user_book.user_book_reads)
      local read_edition = read and read.edition
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
  local default_book = default_edition_results and default_edition_results.books_by_pk
  if type(default_book) == "table" then
    if default_book.default_ebook_edition then
      return default_book.default_ebook_edition
    end

    if default_book.default_physical_edition then
      return default_book.default_physical_edition
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
-- Full detail for one book, including description and community rating.
-- `edition_id` is optional; when given, edition level fields are included.
--
-- What the details screen shows of a book, the same whether the book is asked for by itself or
-- through a linked edition (the edition's own fields are laid over these afterwards). One list,
-- so a field added for the screen cannot reach only one of the two requests.
local BOOK_DETAIL_FIELDS = [[
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
  ratings_distribution
  cached_tags
  first_release_date: release_date
  reviews_count
  lists_count
  editions_count
  default_audio_edition { audio_seconds }
  description
  contributions {
    contribution
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
    review_raw
    review_has_spoilers
  }
]]

-- The edition's own part of the same answer, laid over the book by `overlayEdition`.
local EDITION_DETAIL_FIELDS = [[
  id
  edition_format
  reading_format_id
  pages
  audio_seconds
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
    ]] .. BOOK_DETAIL_FIELDS .. [[
  }
]]

-- An edition's fields are more precise than the book level equivalents, so they are laid
-- over the book before it goes to the display layer. Returns the book row, or nil.
local function overlayEdition(edition)
  if not edition then
    return nil
  end
  local row = edition.book or {}
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
  if edition.audio_seconds then
    row.audio_seconds = edition.audio_seconds
  end
  return row
end

-- What getBookDetail answers for a book row: the book, and your status and rating on it.
local function detailOf(row)
  local user_book = _t.dig(row, "user_books", 1)
  return {
    book = row,
    user_book_id = user_book and user_book.id,
    status_id = user_book and user_book.status_id,
    user_rating = user_book and user_book.rating,
    user_review = user_book and user_book.review_raw,
    review_spoilers = user_book and user_book.review_has_spoilers,
    review_known = true, -- the review above is Hardcover's own answer, not a saved copy that left it out
  }
end

function HardcoverApi:getBookDetail(book_id, user_id, edition_id)
  local query

  if edition_id then
    query = [[
      query ($editionId: Int!, $userId: Int!) {
        editions(where: { id: { _eq: $editionId } }) {
          ]] .. EDITION_DETAIL_FIELDS .. [[
        }
      }
    ]]
  else
    query = [[
      query ($bookId: Int!, $userId: Int!) {
        books(where: { id: { _eq: $bookId } }) {
          ]] .. BOOK_DETAIL_FIELDS .. [[
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
    row = overlayEdition(_t.dig(results, "editions", 1))
  else
    row = _t.dig(results, "books", 1)
  end

  if not row then
    return nil
  end

  return detailOf(row)
end

-- The details of many books in one go: two requests however many books, one for the books
-- asked for by themselves and one for those asked for through a linked edition.
-- `items` is { { book_id =, edition_id = (optional) }, ... }. Returns a list of
-- { book_id =, edition_id = (nil for a book asked for by itself), detail = what getBookDetail
-- gives }, with no entry for a book Hardcover does not have, or nil when a request failed
-- (nothing is then known about any of them).
function HardcoverApi:getBookDetails(items, user_id)
  local book_ids, edition_ids = {}, {}
  for _, item in ipairs(items or {}) do
    if item.edition_id then
      edition_ids[#edition_ids + 1] = item.edition_id
    elseif item.book_id then
      book_ids[#book_ids + 1] = item.book_id
    end
  end

  local out = {}
  if #book_ids > 0 then
    local results = self:query([[
      query ($ids: [Int!], $userId: Int!) {
        books(where: { id: { _in: $ids } }) {
          ]] .. BOOK_DETAIL_FIELDS .. [[
        }
      }
    ]], { ids = book_ids, userId = user_id })
    if not results then
      return nil
    end
    for _, row in ipairs(results.books or {}) do
      out[#out + 1] = { book_id = row.book_id, detail = detailOf(row) }
    end
  end

  if #edition_ids > 0 then
    local results = self:query([[
      query ($ids: [Int!], $userId: Int!) {
        editions(where: { id: { _in: $ids } }) {
          ]] .. EDITION_DETAIL_FIELDS .. [[
        }
      }
    ]], { ids = edition_ids, userId = user_id })
    if not results then
      return nil
    end
    for _, edition in ipairs(results.editions or {}) do
      local row = overlayEdition(edition)
      if row then
        out[#out + 1] = { book_id = row.book_id, edition_id = edition.id, detail = detailOf(row) }
      end
    end
  end

  return out
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

-- ------------------------------------------------------------------------------
-- Your library: shelves, reading progress, status, rating, journal, stats
-- ------------------------------------------------------------------------------

--
-- One page of a user's shelf. `status_id` may be nil for the whole library.
-- `background` for a download nobody is waiting on (a tap must not cancel it).
-- Returns a list of normalized entries plus has_more, which the dialog uses
-- to decide whether to offer a "load more" action.
--
function HardcoverApi:getShelf(user_id, status_id, offset, limit, background)
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
  }, background)
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
-- How many books are on each of the given shelves, as { [status_id] = count }, and each
-- shelf's fingerprint (Shelf.fingerprint: the count, the latest change, the total of
-- your ratings), as { [status_id] = fingerprint }: what says whether a saved shelf is
-- still right, in the request Home already makes.
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
      "s%d: user_books_aggregate(where: { user_id: { _eq: $userId }, status_id: { _eq: %d } }) "
        .. "{ aggregate { count max { updated_at } sum { rating } } }",
      id, id)
  end

  local query = "query ($userId: Int!) {\n  " .. table.concat(parts, "\n  ") .. "\n}"

  local results, err = self:query(query, { userId = user_id }, true)
  if not results then
    return nil, err
  end

  local counts, prints = {}, {}
  for _, id in ipairs(status_ids) do
    local aggregate = _t.dig(results, "s" .. id, "aggregate")
    local count = tonumber(type(aggregate) == "table" and aggregate.count or nil)
    if count then
      counts[id] = count
      prints[id] = Shelf.fingerprint(aggregate)
    end
  end
  return counts, nil, prints
end

--
-- One page of which books are on a shelf, and nothing about the books: { user_book_id,
-- book_id, status_id, rating, date_added } rows, in the shelf's order (newest first, as
-- getShelf). What a shelf that changed re-downloads when the device has most of its
-- books: about 70 bytes a book (the 611-book Read shelf is 43 KB in one request, against
-- 840 KB in seven with the books). Never cancelled by a tap. Returns rows, nil, has_more.
--
function HardcoverApi:getShelfMembers(user_id, status_id, offset, limit)
  offset = offset or 0
  limit = limit or 500
  local results, err = self:query([[
    query ($userId: Int!, $statusId: Int!, $offset: Int!, $limit: Int!) {
      user_books(
        where: { user_id: { _eq: $userId }, status_id: { _eq: $statusId } }
        order_by: [{ date_added: desc }, { id: desc }]
        offset: $offset
        limit: $limit
      ) { id status_id rating date_added book_id }
    }
  ]], { userId = user_id, statusId = status_id, offset = offset, limit = limit }, true)
  if not results or type(results.user_books) ~= "table" then
    return nil, err or { completed = false }
  end
  local members = {}
  for _, row in ipairs(results.user_books) do
    if type(row) == "table" and tonumber(row.book_id) then
      members[#members + 1] = {
        user_book_id = tonumber(row.id),
        book_id = tonumber(row.book_id),
        status_id = tonumber(row.status_id),
        rating = tonumber(row.rating),
        date_added = row.date_added,
      }
    end
  end
  return members, nil, #results.user_books >= limit
end

--
-- What you are reading now, for the home screen: the most recently updated
-- books on the Currently Reading shelf, each with the progress of its current
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
        user_book_reads(order_by: { id: asc }) {
          progress_pages
          finished_at
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
  }, true)
  if not results or not results.user_books then
    return nil, err or { completed = false }
  end

  return _t.map(results.user_books, function(user_book)
    local entry = Shelf.normalizeEntry(user_book)
    local read = Book:currentRead(user_book.user_book_reads)
    if read then
      entry.progress_pages = read.progress_pages
      entry.edition_pages = _t.dig(read, "edition", "pages")
    end
    return entry
  end)
end

-- `action_at` (optional, "2026-10-23T18:04:11Z", UTC) is when the page was read. Hardcover stamps
-- the progress entry it writes in the journal with it; without it the entry gets the time the page
-- arrives, which is days late for a page read offline. Verified on the live API (see
-- docs/hardcover-journal-api.md). It is declared only when given: a variable that is not sent reads
-- as null.
function HardcoverApi:createRead(user_book_id, edition_id, page, started_at, action_at)
  local action_var = action_at ~= nil and ", $actionAt: timestamptz" or ""
  local action_field = action_at ~= nil and "action_at: $actionAt," or ""
  local query = [[
    mutation InsertUserBookRead($id: Int!, $pages: Int, $editionId: Int, $startedAt: date]] .. action_var .. [[) {
      insert_user_book_read(user_book_id: $id, user_book_read: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
        ]] .. action_field .. [[
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

  local result = self:query(query, {
    id = user_book_id, pages = page, editionId = edition_id, startedAt = started_at, actionAt = action_at,
  })
  if result and result.insert_user_book_read then
    local user_book_read = result.insert_user_book_read.user_book_read
    return self:normalizeUserBookRead(user_book_read)
  end
end

-- `action_at`: when the page was read, as for createRead.
function HardcoverApi:updatePage(user_read_id, edition_id, page, started_at, action_at)
  -- A variable that is not sent reads as null, and null clears the read's start date (and the
  -- date on the journal's "started" entry), so without a date the field is left out.
  local started_var = started_at ~= nil and ", $startedAt: date" or ""
  local started_field = started_at ~= nil and "started_at: $startedAt," or ""
  local action_var = action_at ~= nil and ", $actionAt: timestamptz" or ""
  local action_field = action_at ~= nil and "action_at: $actionAt," or ""
  local query = [[
    mutation UpdateBookProgress($id: Int!, $pages: Int, $editionId: Int]] .. started_var .. action_var .. [[) {
      update_user_book_read(id: $id, object: {
        progress_pages: $pages,
        edition_id: $editionId,
        ]] .. started_field .. action_field .. [[
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

  local result = self:query(query, {
    id = user_read_id, pages = page, editionId = edition_id, startedAt = started_at, actionAt = action_at,
  })
  if result and result.update_user_book_read then
    return self:normalizeUserBookRead(result.update_user_book_read.user_book_read)
  end
end

-- Put the day a book was finished on its latest read. Hardcover dates a finish with the day the
-- status arrives, so a book finished offline and sent later would get the wrong day. `user_book`
-- is what updateUserBook answered with; returns the updated user book, or nil when there is no
-- date, no read to put it on, or it already has that day (a refusal leaves the finish as sent).
-- The read's own start date, page and edition go with it so none of them is cleared.
function HardcoverApi:setFinishedDate(user_book, date)
  local reads = type(user_book) == "table" and user_book.user_book_reads
  local read = type(reads) == "table" and reads[#reads]
  if not date or not read or not read.id or read.finished_at == date then return nil end

  local query = [[
    mutation SetFinished($id: Int!, $pages: Int, $editionId: Int, $startedAt: date, $finishedAt: date) {
      update_user_book_read(id: $id, object: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
        finished_at: $finishedAt,
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
  local result = self:query(query, {
    id = read.id, pages = read.progress_pages, editionId = read.edition_id,
    startedAt = read.started_at, finishedAt = date,
  })
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

-- Change the status on an existing library record. The caller has its user_book id; use
-- update_user_book rather than the insert action used when adding a book to the library.
-- `privacy_setting_id` (optional) is set on the record too; left out, privacy is not touched.
function HardcoverApi:updateUserBookStatus(user_book_id, status_id, privacy_setting_id)
  local query = [[
    mutation ($id: Int!, $object: UserBookUpdateInput!) {
      update_user_book(id: $id, object: $object) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  local result, err = self:query(query, {
    id = user_book_id, object = { status_id = status_id, privacy_setting_id = privacy_setting_id },
  })
  if result and result.update_user_book then
    local updated = result.update_user_book
    if updated.user_book then return updated.user_book end
    return nil, updated.error
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

function HardcoverApi:updateRating(user_book_id, rating)
  -- The API marks a book Read when rating is sent without its current status.
  -- Fetch by library record, including for old queued ratings without a book ID.
  local found, lookup_err = self:query([[
    query ($id: Int!) {
      user_books(where: { id: { _eq: $id } }) { id status_id }
    }
  ]], { id = user_book_id })
  local book = found and found.user_books and found.user_books[1]
  if not (book and book.status_id) then return nil, lookup_err or { error = "no_response" } end

  local query = [[
    mutation ($id: Int!, $rating: numeric, $statusId: Int!) {
      update_user_book(id: $id, object: { rating: $rating, status_id: $statusId }) {
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

  local result, err = self:query(query, { id = user_book_id, rating = rating, statusId = book.status_id })
  if result and result.update_user_book then
    local updated = result.update_user_book
    if updated.user_book then return updated.user_book end
    return nil, updated.error
  end
  return nil, err
end

--
-- Write your review of a book, or clear it with empty text. Hardcover takes the review as a Slate
-- document (see ReviewText); the spoiler flag has to go with every write, or it falls back to false.
-- `json` is KOReader's, for the empty lists inside the document. Returns the user book (with
-- review_raw and has_review) or nil and the reason.
--
function HardcoverApi:updateReview(user_book_id, text, spoilers, json_lib)
  local query = [[
    mutation ($id: Int!, $object: UserBookUpdateInput!) {
      update_user_book(id: $id, object: $object) {
        error
        user_book {
          ...UserBookParts
          review_raw
          review_has_spoilers
          has_review
        }
      }
    }
  ]] .. user_book_fragment

  local object = {
    review_slate = ReviewText.slate(text, json_lib or json),
    review_has_spoilers = spoilers == true,
  }
  local result, err = self:query(query, { id = user_book_id, object = object })
  if result and result.update_user_book then
    local updated = result.update_user_book
    if updated.user_book then return updated.user_book end
    return nil, updated.error
  end
  return nil, err
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

  local result, err = self:query(query, { object = object })
  local created = result and result.insert_reading_journal and result.insert_reading_journal.reading_journal
  if created then return created end
  -- the reason goes back too: the queue holds a refused entry but retries one never answered
  return nil, err
end

-- Change the text of one of your journal entries. Only the text is sent: privacy, tags and page
-- stay as they are. Returns { id }, or nil and the reason (as createJournalEntry).
function HardcoverApi:updateJournalEntry(id, text)
  local query = [[
    mutation UpdateReadingJournalEntry($id: Int!, $object: ReadingJournalUpdateType!) {
      update_reading_journal(id: $id, object: $object) {
        id
      }
    }
  ]]
  local result, err = self:query(query, { id = tonumber(id), object = { entry = text } })
  local updated = result and result.update_reading_journal
  if type(updated) == "table" then return updated end
  return nil, err
end

-- Delete one of your journal entries. Returns { id }, or nil and the reason.
function HardcoverApi:deleteJournalEntry(id)
  local query = [[
    mutation DeleteReadingJournalEntry($id: Int!) {
      delete_reading_journal(id: $id) {
        id
      }
    }
  ]]
  local result, err = self:query(query, { id = tonumber(id) })
  -- an answer at all is the entry gone: what it says about the id it no longer has is not needed
  local deleted = result and result.delete_reading_journal
  if type(deleted) == "table" then return deleted end
  return nil, err
end

--
-- The books you have finished, for Stats: lean rows (no covers, no descriptions) in pages of
-- STATS_PAGE, in a fixed order so the pages do not overlap, plus your genre counts. Returns
-- { rows = Stats rows, genres = Stats.genres, complete = bool } (complete false when the
-- library is longer than STATS_MAX_PAGES pages), or nil and the error.
--
local STATS_PAGE = 500
local STATS_MAX_PAGES = 8

function HardcoverApi:getStats(user_id)
  local raw, genres = {}, nil
  local complete = false
  for page = 0, STATS_MAX_PAGES - 1 do
    local result, err = self:query([[
      query ($userId: Int!, $offset: Int!, $limit: Int!) {
        ]] .. (page == 0 and "me { cached_genres }" or "") .. [[
        user_books(
          where: { user_id: { _eq: $userId }, status_id: { _eq: 3 } }
          order_by: [{ id: asc }]
          offset: $offset
          limit: $limit
        ) {
          id
          rating
          last_read_date
          user_book_reads(order_by: [{ finished_at: desc_nulls_last }], limit: 1) {
            started_at
            finished_at
            finished_at_precision
          }
          book { title pages audio_seconds contributions { author { name } } }
        }
      }
    ]], { userId = user_id, offset = page * STATS_PAGE, limit = STATS_PAGE }, true)
    if result == nil or type(result.user_books) ~= "table" then
      return nil, err or { completed = false }
    end
    if page == 0 then
      local me = type(result.me) == "table" and result.me[1] or nil
      genres = Stats.genres(type(me) == "table" and me.cached_genres or nil)
    end
    for _, row in ipairs(result.user_books) do raw[#raw + 1] = row end
    if #result.user_books < STATS_PAGE then
      complete = true
      break
    end
  end
  return { rows = Stats.normalizeAll(raw), genres = genres or {}, complete = complete }
end

-- ------------------------------------------------------------------------------
-- Lists
-- ------------------------------------------------------------------------------

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
          updated_at
          list_books_aggregate { aggregate { count } }
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
            updated_at
            list_books_aggregate { aggregate { count } }
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
-- How many lists there are to open (yours plus the ones you follow), for the home
-- screen's tile, and each one's fingerprint (see Lists.marks), so Home can tell whether
-- the saved lists are still right without fetching them. One small request (about 100
-- bytes a list). Returns count, marks; or nil and the error.
--
function HardcoverApi:getListCount()
  local query = [[
    query {
      me {
        lists { id updated_at list_books_aggregate { aggregate { count } } }
        followed_lists { list { id updated_at list_books_aggregate { aggregate { count } } } }
      }
    }
  ]]
  local results, err = self:query(query, {}, true) -- a tap while Home is scrolled must not cancel it
  local me = results and results.me
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  if type(me) ~= "table" then
    return nil, err or { completed = false }
  end
  local marks = Lists.marks(me)
  return #marks, marks
end

-- The list_books rows out of an answer read through `me` (see getListBooks), or nil and
-- the error. A list that is gone (unfollowed, deleted) is an empty page, not an error.
local function listBookRows(results, err, source)
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
  return type(rows) == "table" and rows or {}
end

--
-- One page of a list's books, in the list's own order, as shelf entries (with
-- `rank` on a ranked list). `source` says which part of `me` the list is read
-- through: "mine" or "followed". `background` for a download nobody is waiting on
-- (a tap must not cancel it). Returns entries, nil, has_more.
--
function HardcoverApi:getListBooks(list_id, source, ranked, offset, limit, background)
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

  local results, err = self:query(query, { listId = list_id, offset = offset, limit = limit }, background)
  local rows, failure = listBookRows(results, err, source)
  if not rows then return nil, failure end

  local entries = {}
  for i, list_book in ipairs(rows) do
    entries[i] = Lists.entry(list_book, ranked)
  end
  return entries, nil, #rows >= limit
end

--
-- One page of which books a list holds, and nothing about the books: { list_book_id,
-- position, book_id, date_added } rows in the list's order. What a list that changed
-- re-downloads, when the device already has most of its books (about 60 bytes a book,
-- against 1.3 KB with the book). Never cancelled by a tap: nobody is waiting on it.
-- Returns rows, nil, has_more.
--
function HardcoverApi:getListMembers(list_id, source, offset, limit)
  offset = offset or 0
  limit = limit or 100

  local list_books = [[
    list_books(order_by: [{ position: asc }, { id: asc }], offset: $offset, limit: $limit) {
      id position date_added book_id
    }
  ]]
  local query
  if source == "followed" then
    query = [[
      query ($listId: Int!, $offset: Int!, $limit: Int!) {
        me { followed_lists(where: { list_id: { _eq: $listId } }) { list { ]] .. list_books .. [[ } } }
      }
    ]]
  else
    query = [[
      query ($listId: Int!, $offset: Int!, $limit: Int!) {
        me { lists(where: { id: { _eq: $listId } }) { ]] .. list_books .. [[ } }
      }
    ]]
  end

  local results, err = self:query(query, { listId = list_id, offset = offset, limit = limit }, true)
  local rows, failure = listBookRows(results, err, source)
  if not rows then return nil, failure end

  local members = {}
  for _, list_book in ipairs(rows) do
    if type(list_book) == "table" and tonumber(list_book.book_id) then
      members[#members + 1] = {
        list_book_id = tonumber(list_book.id),
        position = tonumber(list_book.position),
        book_id = tonumber(list_book.book_id),
        date_added = list_book.date_added,
      }
    end
  end
  return members, nil, #rows >= limit
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

-- ------------------------------------------------------------------------------
-- Reading goals
-- ------------------------------------------------------------------------------

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

  local results, err = self:query(query, {}, true)
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

-- ------------------------------------------------------------------------------
-- What other readers and Hardcover say: reviews, similar books, for you, vibes
-- ------------------------------------------------------------------------------

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
-- One page of your journal, newest first: every entry Hardcover wrote for you (progress, starts
-- and finishes, ratings, statuses, lists, notes, quotes, reviews), from `opts.offset` (see
-- Journal.query). One request. Returns { entries, count, more } or nil and the error.
--
function HardcoverApi:getJournal(opts)
  local query = Journal.query(opts)
  if not query then return { entries = {}, count = 0, more = false } end
  -- Journal pages are requested by the user; scrolling or tapping the screen while
  -- one loads must not interrupt the subprocess.
  local results, err = self:query(query, nil, true)
  if not results then return nil, err or { completed = false } end
  return Journal.parse(results, opts and opts.limit)
end

--
-- Books like this one: Hardcover's own similar-books ranking for `book_id`, as shelf
-- entries in rank order. Two requests (the ids, then the books for them), both with
-- the permissions the plugin already has. Returns entries, or nil, err. A book with
-- no ranking yet gives an empty list, not an error.
--
--
-- With `user_id`, the first request also brings what the details screen shows that
-- changes: the community numbers, and your status and rating on the book. A third
-- return value carries them, { rating, ratings_count, users_count, users_read_count,
-- user_book = { id, status_id, rating } or false (not in your library) }, so a book
-- whose details were shown from the device is brought up to date without asking for
-- the book again.
--
function HardcoverApi:getSimilarBooks(book_id, limit, user_id)
  local first, err
  if user_id then
    first, err = self:query([[
      query ($bookId: Int!, $userId: Int!) {
        books_by_pk(id: $bookId) {
          cached_similar_book_ids
          rating ratings_count users_count users_read_count
          user_books(where: { user_id: { _eq: $userId } }) { id status_id rating }
        }
      }
    ]], { bookId = book_id, userId = user_id }, true)
  else
    first, err = self:query([[
      query ($bookId: Int!) {
        books_by_pk(id: $bookId) { cached_similar_book_ids }
      }
    ]], { bookId = book_id }, true)
  end
  local book = first and first.books_by_pk
  if type(book) == "table" and book[1] ~= nil then book = book[1] end
  if first == nil or (type(book) ~= "table" and first.books_by_pk ~= nil) then
    return nil, err or { completed = false }
  end

  local about
  if user_id and type(book) == "table" then
    local mine = _t.dig(book, "user_books", 1)
    about = {
      rating = book.rating,
      ratings_count = book.ratings_count,
      users_count = book.users_count,
      users_read_count = book.users_read_count,
      user_book = type(mine) == "table" and { id = mine.id, status_id = mine.status_id, rating = mine.rating } or false,
    }
  end

  local ids = Recommendations.ids(type(book) == "table" and book.cached_similar_book_ids, limit)
  if #ids == 0 then return {}, nil, about end

  local entries, books_err = self:getBooksByIds(ids)
  return entries, books_err, about
end

--
-- "For you": books suggested from the ones you rated 4 or more, computed here from
-- Hardcover's similar-books rankings (see Recommendations.score). Three requests: your
-- best-rated books with their rankings, which of the best-scoring candidates you already
-- have, then the books for the ones left. Each entry carries `reason`, the title of the book it came from. Returns
-- entries (empty, with the note "no_ratings", when nothing is rated 4 or more yet), or
-- nil and the error.
--
function HardcoverApi:getForYou(limit)
  limit = limit or Recommendations.LIMIT
  local first, err = self:query([[
    query {
      me {
        seeds: user_books(where: { rating: { _gte: 4 } }, order_by: { updated_at: desc }, limit: 15) {
          rating
          book { id title cached_similar_book_ids }
        }
      }
    }
  ]], nil, true)
  local me = first and first.me
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  if type(me) ~= "table" then return nil, err or { completed = false } end

  local seeds = type(me.seeds) == "table" and me.seeds or {}
  if #seeds == 0 then return {}, nil, "no_ratings" end

  -- A pool well past what is shown, then the ones already in your library are dropped. The
  -- library is not fetched whole (a long one would be cut short by the API's row limit and
  -- let owned books through): only these few ids are asked about.
  local pool = Recommendations.score(seeds, {}, limit * 4)
  local pool_ids = {}
  for _, pick in ipairs(pool) do pool_ids[#pool_ids + 1] = pick.id end

  local second, err2 = self:query([[
    query ($ids: [Int!]) {
      me { owned: user_books(where: { book_id: { _in: $ids } }) { book_id } }
    }
  ]], { ids = pool_ids }, true)
  local owner = second and second.me
  if type(owner) == "table" and owner[1] ~= nil then owner = owner[1] end
  if type(owner) ~= "table" then return nil, err2 or { completed = false } end
  local owned = {}
  for _, row in ipairs(type(owner.owned) == "table" and owner.owned or {}) do owned[tonumber(row.book_id)] = true end

  local ids, reasons = {}, {}
  for _, pick in ipairs(pool) do
    if not owned[pick.id] and #ids < limit then
      ids[#ids + 1] = pick.id
      reasons[pick.id] = pick.reason
    end
  end

  local entries, err3 = self:getBooksByIds(ids)
  if entries == nil then return nil, err3 end
  for _, entry in ipairs(entries) do
    entry.reason = reasons[entry.book_id] -- the title of the book it was suggested for
  end
  return entries
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

--
-- Async wrappers.
--
-- Each one runs the call inside a wrap (Trapper:wrap, through runtime.lua). That is what makes the request
-- non-blocking: inside a wrapped coroutine, query() forks a subprocess and
-- yields back to KOReader's event loop, so the screen the caller just showed
-- (a "Loading..." message, an empty dialog) actually gets painted while the
-- request is in flight, and a tap can cancel it. Outside a wrap,
-- dismissableRunInSubprocess() logs "unwrapped dismissableRunInSubprocess(),
-- falling back to blocking in-process run" and the whole UI freezes until the
-- reply arrives -- which is what these did when they merely called the
-- blocking function and delayed the callback.
--
-- Every callback is invoked on the next UI tick (UIManager:nextTick), so a caller may touch
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
  runtime().next_tick(function()
    callback(unpack(args, 1, n))
  end)
end

local function async(callback, fn, ...)
  local args = { ... }
  local n = select("#", ...)
  runtime().wrap(function()
    local results = { pcall(fn, unpack(args, 1, n)) }
    if not results[1] then
      logger.warn("hardcover api: async call raised", results[2])
      deliver(callback)
      return
    end
    deliver(callback, unpack(results, 2, table.maxn(results)))
  end)
end

--
-- One wrapper per blocking call below: `name .. "Async"` takes the same arguments as
-- `name` plus a callback as the last one, and calls it with whatever `name` returned.
-- `name` is looked up when the wrapper is called, so a replaced method (a test, a
-- spec's stub) is the one that runs.
--
local ASYNC_METHODS = {
  "saveGoal",
  "archiveGoal",
  "getGoals",
  "getLists",
  "getBookLists",
  "addToList",
  "removeFromList",
  "getListCount",
  "getShelf",
  "getShelfCounts",
  "getStats",
  "getBooksByIds",
  "getVibes",
  "getForYou",
  "me",
  "getSimilarBooks",
  "getBookDetail",
  "getReviews",
  "getJournal",
  "updateUserBook",
  "removeUserBook",
  "findBooks",
  "findEditions",
  "findDefaultEdition",
  "findBookByIdentifiers",
}

for _, name in ipairs(ASYNC_METHODS) do
  HardcoverApi[name .. "Async"] = function(self, ...)
    local n = select("#", ...)
    local callback = select(n, ...)
    async(callback, self[name], self, unpack({ ... }, 1, n - 1))
  end
end

return HardcoverApi
