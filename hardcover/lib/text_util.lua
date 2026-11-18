-- Small shared text helpers.

local TextUtil = {}

-- Leading and trailing whitespace only; callers keep their own type checks and coercion.
function TextUtil.trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Emoji and symbol characters in U+1F000–U+1FFFF (four UTF-8 bytes: F0 9F xx xx) and the
-- variation selector (U+FE0F, emoji presentation only). No font KOReader ships draws them.
-- CJK Extension B+ (U+20000+, e.g. 𠮷) is preserved: the bundled CJK fallback draws those.
-- ZWJ (U+200D) is preserved: it forms legitimate Indic conjuncts (e.g. Malayalam chillu);
-- callers check for visible content to reject an invisible remainder.
-- BMP symbols (a star, a heart) stay: the fallback fonts draw those.
function TextUtil.stripAstral(text)
  text = text:gsub("\240\159[\128-\191][\128-\191]", "")
  text = text:gsub("\239\184\143", "")
  return (text:gsub("%s+", " "))
end

return TextUtil
