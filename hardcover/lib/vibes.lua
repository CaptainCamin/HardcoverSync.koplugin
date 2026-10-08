-- Hardcover's "vibes", as plain data.
--
-- A vibe is a saved recommendation recipe whose result Hardcover keeps as a ranked list of
-- book ids (`cached_book_ids`, up to 250). Besides the ones you make, your account has
-- ones Hardcover makes for you: "Top Picks", "Recommendations" and "Based on ...". Reading
-- them needs the read:vibes permission (a sign-in from before it was asked for lacks it).
-- Checked against live data: `vibe_type` 0 is one you made, 1 your Recommendations, 2 a
-- "Based on ..." one, 3 Top Picks, 4 a book club's.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite.

local Lists = require("hardcover/lib/lists")

local Vibes = {}

Vibes.SCOPE = "read:vibes"

-- How many covers the index shows beside each vibe (the same as a list's)
Vibes.COVERS = Lists.COVERS

local KIND = { [0] = "mine", [1] = "recommendations", [2] = "based_on", [3] = "top_picks", [4] = "club" }

-- the order of the index: Hardcover's own first, then yours
local ORDER = { top_picks = 1, recommendations = 2, based_on = 3, club = 4, mine = 5 }

function Vibes.kind(vibe_type)
  return KIND[tonumber(vibe_type)] or "mine"
end

-- A vibe's ids as whole numbers, in rank order, without repeats.
local function ids(raw)
  local out, seen = {}, {}
  for _, value in ipairs(type(raw) == "table" and raw or {}) do
    local id = tonumber(value)
    if id and id == math.floor(id) and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end
Vibes.ids = ids

--
-- The `vibes` rows from the API as { id, title, description, kind, ids, count, private,
-- generated_at }, Hardcover's own first (then yours), each group in id order. Rows with no
-- id, and vibes with nothing in them, are left out.
--
function Vibes.normalize(rows)
  local out = {}
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if type(row) == "table" and row.id then
      local list = ids(row.cached_book_ids)
      if #list > 0 then
        out[#out + 1] = {
          id = row.id,
          title = (type(row.title) == "string" and row.title ~= "") and row.title or "Untitled vibe",
          description = type(row.description) == "string" and row.description or nil,
          kind = Vibes.kind(row.vibe_type),
          ids = list,
          count = #list,
          private = row.privacy_setting_id ~= nil and row.privacy_setting_id ~= 1 or nil,
          generated_at = row.books_generated_at,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.kind ~= b.kind then return (ORDER[a.kind] or 9) < (ORDER[b.kind] or 9) end
    return tonumber(a.id) < tonumber(b.id)
  end)
  return out
end

-- Whether a vibe is one Hardcover made for you (not one you made).
function Vibes.isSystem(vibe)
  return vibe.kind ~= "mine"
end

--
-- The two groups of the index, as rows the lists screen draws (see Lists.normalize): what
-- Hardcover made for you, then what you made. `cover_urls` maps a vibe id to the covers of
-- its first books. Each row keeps its `vibe`.
--
function Vibes.rows(vibes, cover_urls)
  cover_urls = cover_urls or {}
  local system, mine = {}, {}
  for _, vibe in ipairs(vibes or {}) do
    local row = {
      id = vibe.id,
      source = "vibe",
      name = vibe.title,
      count = vibe.count,
      ranked = true, -- the order is Hardcover's ranking
      owner = Vibes.isSystem(vibe) and "Hardcover" or nil,
      private = (not Vibes.isSystem(vibe)) and vibe.private or nil,
      covers = cover_urls[vibe.id] or {},
      vibe = vibe,
    }
    local into = Vibes.isSystem(vibe) and system or mine
    into[#into + 1] = row
  end
  return system, mine
end

-- A page of a vibe's ids: ids[offset + 1 .. offset + limit].
function Vibes.page(vibe, offset, limit)
  local out = {}
  for i = (offset or 0) + 1, math.min((offset or 0) + (limit or 20), #vibe.ids) do
    out[#out + 1] = vibe.ids[i]
  end
  return out
end

Vibes.isScopeError = Lists.isScopeError

return Vibes
