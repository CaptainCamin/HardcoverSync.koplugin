-- Small shared text helpers.

local TextUtil = {}

-- Leading and trailing whitespace only; callers keep their own type checks and coercion.
function TextUtil.trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

return TextUtil
