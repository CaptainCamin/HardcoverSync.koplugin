#!/usr/bin/env bash
#
# Build the installable plugin zip.
#
# Produces hardcoversync.koplugin.zip containing a single top-level
# hardcoversync.koplugin/ directory, which is what KOReader's plugin loader
# expects. The name comes from _meta.lua, not from the checkout directory, so a
# clone under any name (CI checks out the repository's own name) builds the
# same archive. Dev-only files (specs, harnesses, CI config, git metadata) are
# excluded so the release stays small.
#
# This is the only packaging path in the repo: the release workflow
# (.github/workflows/release.yml) calls it rather than zipping anything itself,
# so the two cannot disagree about what ships.
#
# Usage:  ./spec/package_release.sh [output-dir]

set -euo pipefail

# run from the plugin root regardless of where this was invoked from
cd "$(dirname "$0")/.." || exit 1

PLUGIN_NAME="$(sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' _meta.lua | head -1)"
if [ -z "$PLUGIN_NAME" ]; then
  echo "Cannot read the plugin name from _meta.lua"
  exit 1
fi
PLUGIN_DIR="$PLUGIN_NAME.koplugin"
ROOT="$PWD"
OUT_DIR="${1:-$PWD/..}"
ZIP="$OUT_DIR/$PLUGIN_DIR.zip"

if [ ! -d "$OUT_DIR" ]; then
  echo "Output directory does not exist: $OUT_DIR"
  exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "This script needs 'zip' on your PATH."
  exit 1
fi

# Refuse to ship a real config: it holds the user's API token.
if [ -f hardcover_config.lua ]; then
  echo "ERROR: hardcover_config.lua exists -- it holds credentials and must not be published."
  echo "       It is gitignored, so this likely means an untracked local file."
  exit 1
fi

# Belt and braces: fail if any source file looks like it contains a real
# Hardcover API token.
#
# All three credential prefixes are checked, not just hc_pat_. The plugin ships
# OAuth, and a real access or refresh token starts hc_at_ / hc_rt_ -- a guard
# covering only hc_pat_ would wave one of those straight through. The public
# OAuth client id (636a2d1e-...) is not a secret and carries none of these
# prefixes, so it is unaffected.
#
# The body must be long enough (16+ chars) that the bare prefix constants in
# oauth.lua -- "hc_at_", "hc_rt_" -- cannot match. That is why this is a
# pattern with a quantifier rather than a plain grep for the prefix.
if grep -rlE 'hc_(pat|at|rt)_[A-Za-z0-9_-]{16,}' \
     --include='*.lua' --include='*.sh' --include='*.md' . 2>/dev/null \
     | grep -q .; then
  echo "ERROR: a file appears to contain a Hardcover API token. Refusing to package."
  echo "       Matches (token-shaped strings outside the spec fixtures are the"
  echo "       ones that matter -- the spec uses deliberate placeholders):"
  grep -rnoE 'hc_(pat|at|rt)_[A-Za-z0-9_-]{16,}' \
    --include='*.lua' --include='*.sh' --include='*.md' . 2>/dev/null \
    | grep -v '^\./spec/' | sed 's/^/         /'
  exit 1
fi

rm -f "$ZIP"

# Stage a clean copy, then zip that.
#
# The previous approach ran `zip -r` from OUT_DIR and relied on the plugin
# directory already being there -- which only works when OUT_DIR is the plugin's
# parent. Point it anywhere else (a release staging area, /tmp) and zip silently
# found nothing: it exits 12 with no output, because `zip` had no input path.
#
# Staging also makes the dev-directory check below meaningful. Excluding spec/
# and .git/ with a growing -x list is a list that drifts; a staged copy either
# contains a dev directory or it does not, and the archive cannot disagree.
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/$PLUGIN_DIR"

# Only what ships. The config example must be included: it is the template a
# user copies to create their own config, and without it they have no way to
# learn the key names.
for item in _meta.lua main.lua hardcover icons hardcover_version.lua \
            hardcover_config.example.lua LICENSE README.md CHANGELOG.md; do
  if [ -e "$ROOT/$item" ]; then
    cp -R "$ROOT/$item" "$STAGE/$PLUGIN_DIR/"
  fi
done

# Nothing untracked or gitignored may ride along in the staged copy.
for unwanted in spec .git .github .gitignore; do
  if [ -e "$STAGE/$PLUGIN_DIR/$unwanted" ]; then
    echo "ERROR: $unwanted was staged. It must not ship."
    rm -rf "$STAGE"
    exit 1
  fi
done

# Run from the staging directory so the archive holds "$PLUGIN_DIR/..."
# rather than an extra parent directory in the path.
(
  cd "$STAGE" || exit 1
  zip -r "$ZIP" "$PLUGIN_DIR" \
    -x "*/*.git/*" \
       "*/.git/*" \
       "*/.gitignore" \
       "*/.github/*" \
       "*/spec/*" \
       "*/.luacheckrc" \
       "*/.luacov" \
       "*/.tool-versions" \
       "*/lua_modules/*" \
       "*/.luarocks/*" \
       "*/lua" \
       "*/luarocks" \
       "*/.DS_Store" \
       "*/*.rockspec" \
    >/dev/null
)

echo "Built $ZIP"

# Report what actually shipped, so an accidental omission is visible.
echo
echo "Contents:"
unzip -l "$ZIP" | sed -n '4,$p'

# sanity: the loader needs _meta.lua and main.lua at the top level.
# unzip -l output pads names with leading spaces, so match on the path
# substring rather than anchoring at the start of the line.
listing=$(unzip -l "$ZIP")
for required in "$PLUGIN_DIR/_meta.lua" "$PLUGIN_DIR/main.lua"; do
  if ! printf '%s\n' "$listing" | grep -q "  $required\$"; then
    echo
    echo "ERROR: $required is missing from the archive."
    exit 1
  fi
done

echo
echo "OK: _meta.lua and main.lua are present."

# ---------------------------------------------------------------------------
# Verify the built artifact, not just the working tree.
#
# The listing above shows what zip was told to include; it does not show that
# the bytes are right. Everything below works by extracting the archive and
# comparing it against the working tree.
#
# Deliberately NOT done: grepping the archive for a string that was removed.
# That string survives in the comment explaining why it was wrong, so the check
# reports a leak that is not there and teaches you to distrust the guard. Diff
# is definitive; grep is a hint.
# ---------------------------------------------------------------------------

echo
echo "Verifying the archive..."

VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
unzip -q "$ZIP" -d "$VERIFY_DIR"
EXTRACTED="$VERIFY_DIR/$PLUGIN_DIR"

if [ ! -d "$EXTRACTED" ]; then
  echo "ERROR: the archive has no top-level $PLUGIN_DIR/ directory."
  echo "       KOReader would install nothing at all from this zip."
  exit 1
fi
echo "  top-level $PLUGIN_DIR/ present"

# A credential in the archive is the worst outcome, and the preflight check only
# looks at the working tree. Check the built bytes.
if [ -f "$EXTRACTED/hardcover_config.lua" ]; then
  echo "ERROR: hardcover_config.lua is INSIDE the archive. Remove it and rebuild."
  exit 1
fi
echo "  no credential file in the archive"

# Dev directories must be absent. They are gitignored or untracked, so a
# -x pattern that forgets one ships it silently.
for unwanted in spec .git .github; do
  if [ -e "$EXTRACTED/$unwanted" ]; then
    echo "ERROR: $unwanted/ is in the archive. A release must not ship tests."
    exit 1
  fi
done
echo "  no dev directories in the archive"

# The shipped code must be byte-identical to what was staged, which is in turn
# a copy of the working tree. Diffed against the stage, not $ROOT: the working
# tree legitimately contains spec/ and .git/, which the archive must not, so
# diffing against it would always "fail".
if ! diff -r "$STAGE/$PLUGIN_DIR" "$EXTRACTED" >/dev/null 2>&1; then
  echo "ERROR: the archive does not match what was staged:"
  diff -r "$STAGE/$PLUGIN_DIR" "$EXTRACTED" 2>&1 | head -20
  exit 1
fi
echo "  archive matches the staged tree"

# ...and the staged tree must match the live working tree, so a stale stage
# cannot ship code the repo no longer has.
if ! diff -r "$ROOT/hardcover" "$STAGE/$PLUGIN_DIR/hardcover" >/dev/null 2>&1; then
  echo "ERROR: the staged code differs from the working tree:"
  diff -r "$ROOT/hardcover" "$STAGE/$PLUGIN_DIR/hardcover" | head -20
  exit 1
fi
echo "  staged code matches the working tree"

# Every shipped .lua must parse. A syntax error caught here is a broken zip;
# caught on the device it is a plugin that does not load, with no error the
# reader can reach.
PARSE_LUA="${LUA:-}"
if [ -z "$PARSE_LUA" ]; then
  for candidate in luajit lua5.1 lua; do
    command -v "$candidate" >/dev/null 2>&1 && { PARSE_LUA="$candidate"; break; }
  done
fi
if [ -n "$PARSE_LUA" ]; then
  parse_status=0
  while IFS= read -r f; do
    "$PARSE_LUA" -e "assert(loadfile([[$f]]))" 2>/dev/null || {
      echo "    SYNTAX ERROR in archive: ${f#$VERIFY_DIR/}"
      parse_status=1
    }
  done < <(find "$VERIFY_DIR" -name '*.lua')
  if [ "$parse_status" -ne 0 ]; then
    echo "ERROR: a shipped Lua file does not parse."
    exit 1
  fi
  echo "  all shipped lua parses under $("$PARSE_LUA" -v 2>&1 | head -1)"
else
  echo "  NOTE: no lua interpreter; skipped the parse check"
fi

# Every internal require must resolve inside the archive. The one expected miss
# is the user-created config module, which is why hardcover_config.example.lua
# has to ship.
#
# The require path is already relative to the plugin root ("hardcover/lib/x"),
# so it maps onto the archive as $EXTRACTED/<path>.lua -- no prefix stripping.
# Stripping "hardcover/" here pointed every lookup one directory too deep and
# reported all 38 modules missing.
missing=""
while IFS= read -r req; do
  target="$EXTRACTED/${req%.lua}"
  if [ ! -e "$target.lua" ] && [ ! -e "$target/init.lua" ]; then
    case "$req" in
      hardcover_config) continue ;;  # created by the user, not shipped
      *) missing="$missing $req" ;;
    esac
  fi
done < <(grep -rhoE 'require\("hardcover/[^"]+"\)' "$EXTRACTED" --include='*.lua' 2>/dev/null \
         | sed 's/require("//; s/")//' | sort -u)
if [ -n "$missing" ]; then
  echo "ERROR: internal requires do not resolve inside the archive:$missing"
  exit 1
fi
echo "  every internal require resolves"

# Icons are loaded by file path, so a zip without them fails silently on the device
# (KOReader draws its "icon not found" glyph). Every one in the tree must be in the zip.
if ! diff -r "$ROOT/icons" "$EXTRACTED/icons" >/dev/null 2>&1; then
  echo "ERROR: icons/ is missing from the archive or differs from the working tree."
  exit 1
fi
echo "  icons ship ($(ls "$EXTRACTED/icons" | wc -l | tr -d ' ') files)"

if [ -f "$EXTRACTED/hardcover_config.example.lua" ]; then
  echo "  config example ships, so a user has a template"
else
  echo "  NOTE: hardcover_config.example.lua is not in the archive"
fi

echo
echo "VERIFIED: $ZIP"
rm -rf "$STAGE"