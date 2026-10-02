-- Other readers' reviews of a book: shaping, truncation and spoiler handling.
--
-- Pure: no widgets and no KOReader, so it runs under stock Lua in the harness.
-- The dialog (ui/reviews_dialog.lua) only lays out what this returns.
--
-- What the real API does, which this is written around (checked against live
-- data, not guessed):
--
--   * `user` is often null (the reader's privacy settings), so a review has no
--     name more often than not: it is shown as "A reader".
--   * `reviewed_at` is often null, and `rating` may be null.
--   * `review_raw` is plain text with blank-line paragraph breaks and can run to
--     hundreds of words, so the list shows an excerpt and the full text opens
--     in a viewer.
--   * `review_has_spoilers` reviews stay hidden until the reader taps them.

local Reviews = {}

-- One request fetches one page of this many reviews (the API allows 60 requests
-- a minute; the list only ever asks when the reader does).
Reviews.PAGE_SIZE = 10

-- How much of a review the list shows before "Read more": about six lines at
-- the list's font on a 1264px panel (a line is about 70 characters). The list
-- flattens line breaks, so this is a character budget; the viewer keeps them.
Reviews.EXCERPT_CHARS = 300

-- U+2026 horizontal ellipsis and U+00B7 middle dot, as bytes: the CI Lua is 5.1,
-- which has no \u{} escape.
local ELLIPSIS = "\226\128\166"
local DOT = " \194\183 "

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--
-- A reader's name. Falls back to "A reader" when the account is private (no
-- `user`) or has neither a display name nor a username.
--
function Reviews.reviewer(user_book)
  local user = type(user_book) == "table" and user_book.user
  if type(user) == "table" then
    for _, key in ipairs({ "name", "username" }) do
      local value = user[key]
      if type(value) == "string" and trim(value) ~= "" then
        return trim(value)
      end
    end
  end
  return "A reader"
end

--
-- "4.5*", "4*", or nil when there is no rating (null or zero).
--
function Reviews.ratingText(rating)
  rating = tonumber(rating)
  if not rating or rating <= 0 then return nil end
  if rating % 1 == 0 then return string.format("%d*", rating) end
  return string.format("%.1f*", rating)
end

--
-- "1 like" / "12 likes", or nil for none.
--
function Reviews.likesText(count)
  count = tonumber(count)
  if not count or count < 1 then return nil end
  count = math.floor(count)
  return count == 1 and "1 like" or (count .. " likes")
end

-- The date part of an ISO timestamp, or nil.
function Reviews.dateText(value)
  if type(value) ~= "string" then return nil end
  return value:match("^(%d%d%d%d%-%d%d%-%d%d)")
end

--
-- Cut `text` to at most `max_chars` characters, at a word boundary, with an
-- ellipsis, and with paragraph breaks flattened to a space (the list cannot
-- show them). Returns the excerpt and whether anything was cut. Never splits a
-- UTF-8 sequence.
--
function Reviews.excerpt(text, max_chars)
  max_chars = max_chars or Reviews.EXCERPT_CHARS
  text = trim((tostring(text or ""):gsub("%s*[\r\n]+%s*", "  ")))

  local cut = false
  if #text > max_chars then
    local piece = text:sub(1, max_chars)
    -- back up off the middle of a multi-byte character
    while #piece > 0 do
      local b = piece:byte(#piece)
      if b >= 128 and b < 192 then
        piece = piece:sub(1, #piece - 1)
      elseif b >= 192 then
        piece = piece:sub(1, #piece - 1)
        break
      else
        break
      end
    end
    -- and back to a word boundary when there is one near the end
    local boundary = piece:match("^(.*)%s%S*$")
    if boundary and #boundary > max_chars * 0.6 then piece = boundary end
    text = piece
    cut = true
  end

  text = trim(text)
  if cut then text = text .. ELLIPSIS end
  return text, cut
end

--
-- Five star glyphs for a rating out of five, rounded to the nearest whole star
-- (a filled star for each, an outlined one for the rest); "" for no rating.
-- U+2605 and U+2606 as bytes, for the CI Lua.
--
function Reviews.stars(rating)
  rating = tonumber(rating)
  if not rating or rating <= 0 then return "" end
  local full = math.min(5, math.max(0, math.floor(rating + 0.5)))
  return string.rep("\226\152\133", full) .. string.rep("\226\152\134", 5 - full)
end

--
-- What the reviews screen says about the book itself: its title and the
-- community rating (with how many rated it), from the details the reader was
-- looking at. The API gives no breakdown of the ratings by star (it would take
-- a query of its own), so this is all there is to summarise; nil when there is
-- nothing to show.
--
function Reviews.summary(detail)
  local book = type(detail) == "table" and detail.book
  if type(book) ~= "table" then return nil end
  local title = type(book.title) == "string" and book.title ~= "" and book.title or nil
  local rating = tonumber(book.rating)
  if rating and rating <= 0 then rating = nil end
  local count = tonumber(book.ratings_count)
  if count and count <= 0 then count = nil end
  if not (title or rating) then return nil end
  return { title = title, rating = rating, count = count }
end

--
-- One API user_books row as the dialog needs it.
--
-- `text` is the whole review; `excerpt`/`truncated` is what the list shows.
-- A review with no text at all (rating-only rows slip past has_review) is
-- dropped by `normalizeAll`, not here.
--
function Reviews.normalize(user_book)
  if type(user_book) ~= "table" then return nil end
  local text = type(user_book.review_raw) == "string" and trim(user_book.review_raw) or ""
  local excerpt, truncated = Reviews.excerpt(text)
  return {
    id = user_book.id,
    reviewer = Reviews.reviewer(user_book),
    rating = Reviews.ratingText(user_book.rating),
    rating_value = (tonumber(user_book.rating) or 0) > 0 and tonumber(user_book.rating) or nil,
    likes = Reviews.likesText(user_book.likes_count),
    date = Reviews.dateText(user_book.reviewed_at),
    has_spoilers = user_book.review_has_spoilers == true,
    text = text,
    excerpt = excerpt,
    truncated = truncated,
  }
end

-- The page's rows, normalised, skipping any with no text.
function Reviews.normalizeAll(rows)
  local out = {}
  for _, row in ipairs(rows or {}) do
    local review = Reviews.normalize(row)
    if review and review.text ~= "" then out[#out + 1] = review end
  end
  return out
end

-- "Name · 4.5* · 12 likes · 2024-05-03", leaving out what is missing.
function Reviews.headline(review)
  local parts = { review.reviewer }
  for _, key in ipairs({ "rating", "likes", "date" }) do
    if review[key] then parts[#parts + 1] = review[key] end
  end
  return table.concat(parts, DOT)
end

--
-- What a row says when it is a spoiler that has not been revealed.
--
Reviews.SPOILER_PROMPT = "Contains spoilers - tap to show"
Reviews.READ_MORE = "Read more"
Reviews.LOAD_MORE = "Load more reviews"

--
-- The text of one list row, and what tapping it will do.
--
-- Returns text, action where action is "reveal" (a hidden spoiler), "full" (an
-- excerpt that has a rest to read) or nil (nothing to do).
--
function Reviews.rowText(review, revealed)
  local head = Reviews.headline(review)
  if review.has_spoilers and not revealed then
    return head .. ": " .. Reviews.SPOILER_PROMPT, "reveal"
  end
  if review.truncated then
    return head .. ": " .. review.excerpt .. "  " .. Reviews.READ_MORE .. " >", "full"
  end
  return head .. ": " .. review.excerpt, nil
end

--
-- Append a fetched page, dropping rows already held. Offset paging over a list
-- that changes between requests (a like moves a review up the order) can
-- return a row twice; showing it twice would be wrong, and dropping it is safe
-- because the tie-break keeps the order otherwise stable.
--
function Reviews.appendPage(existing, page)
  local out, seen = {}, {}
  for _, r in ipairs(existing or {}) do
    out[#out + 1] = r
    if r.id then seen[r.id] = true end
  end
  for _, r in ipairs(page or {}) do
    if not (r.id and seen[r.id]) then
      out[#out + 1] = r
      if r.id then seen[r.id] = true end
    end
  end
  return out
end

--
-- Whether to offer "Load more": a full page means there may be another. The
-- raw row count is what counts, not the normalised one -- a page of ten rows
-- with a textless one dropped is still a full page.
--
function Reviews.hasMore(raw_count, limit)
  return (raw_count or 0) >= (limit or Reviews.PAGE_SIZE)
end

return Reviews
