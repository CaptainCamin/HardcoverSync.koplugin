#!/usr/bin/env bash
#
# Build the installable plugin zip.
#
# Produces hardcoverapp.koplugin.zip containing a single top-level
# hardcoverapp.koplugin/ directory, which is what KOReader's plugin loader
# expects. Dev-only files (specs, harnesses, CI config, git metadata) are
# excluded so the release stays small.
#
# Used by both local packaging and .github/workflows/release.yml, so the two
# can never disagree about what ships.
#
# Usage:  ./spec/package_release.sh [output-dir]

set -euo pipefail

# run from the plugin root regardless of where this was invoked from
cd "$(dirname "$0")/.." || exit 1

PLUGIN_DIR="$(basename "$PWD")"
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
# Hardcover API token. Only checks tracked source, and skips the public client
# id (hc_pat_ is the credential prefix; client ids are not secrets).
if grep -rlE 'hc_pat_[A-Za-z0-9]{20,}' --include='*.lua' --include='*.sh' . 2>/dev/null | grep -q .; then
  echo "ERROR: a file appears to contain a Hardcover API token. Refusing to package."
  exit 1
fi

rm -f "$ZIP"

# Run from OUT_DIR so the archive holds "hardcoverapp.koplugin/..." rather than
# an extra parent directory in the path.
(
  cd "$OUT_DIR" || exit 1
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