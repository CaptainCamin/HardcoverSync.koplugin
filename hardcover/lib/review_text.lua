-- A review as Hardcover wants it written: a Slate document, one paragraph for each line of text.
--
-- Checked against the live API (spec/live/hardcover_live.lua, docs/hardcover-journal-api.md):
-- `review_slate` on update_user_book sets the review, and a document with one empty paragraph
-- clears it. Sending the review as markdown works for setting but cannot clear.
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite.

local ReviewText = {}

-- What the writer typed, with the line ends of any platform made "\n", and nothing around it.
function ReviewText.clean(text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--
-- The `review_slate` value for `text`: { document = { object = "document", children = {...} } },
-- a paragraph block for each line. No text is one empty paragraph, which clears a review.
-- `json` is KOReader's, for the lists that must go out as [] and not {}; the specs pass a stand-in.
--
function ReviewText.slate(text, json)
  local function list()
    local t = {}
    if json and json.util and json.util.InitArray then t = json.util.InitArray(t) end
    return t
  end
  local lines = {}
  for line in (ReviewText.clean(text) .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end

  local children = list()
  for _, line in ipairs(lines) do
    local leaf = { object = "text", text = line, marks = list() }
    local leaves = list()
    leaves[1] = leaf
    children[#children + 1] = { object = "block", type = "paragraph", children = leaves }
  end
  return { document = { object = "document", children = children } }
end

return ReviewText
