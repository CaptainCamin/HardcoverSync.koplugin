-- The installed version, as { major, minor, patch } plus:
--   .text  the version as written in _meta.lua ("1.4.1", or "1.4.1-beta.2" for a beta)
--   .beta  the beta number when it is a beta ("-beta.2" -> 2, a suffix with no number -> 0),
--          nil for a stable release
-- Beta builds are stamped with their tag by the release workflow, so a beta knows it is one.
local data = require('_meta')
local version = {}

local core, suffix = tostring(data.version):match("^([%d%.]+)%-?(.*)$")
for str in string.gmatch(core or tostring(data.version), "[^.]+") do
  table.insert(version, tonumber(str))
end
if suffix and suffix ~= "" then
  version.beta = tonumber(suffix:match("(%d+)%s*$")) or 0
end
version.text = tostring(data.version)
return version
