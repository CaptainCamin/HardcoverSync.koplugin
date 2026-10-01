#!/usr/bin/env bash
# Runs every check in spec/ and fails on the first broken one.
#
# Kept as a script rather than a make target because the release workflow and
# the README both invoke it, and because it has to work on a stock Lua with no
# busted or luarocks installed -- which is the situation on a fresh machine.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LUA="${LUA:-lua}"
FAILED=0

echo "== syntax =="
# Every Lua file must at least parse. Cheap, and it catches the single most
# common way a plugin ships broken.
while IFS= read -r f; do
  if ! "$LUA" -e "assert(loadfile([[$f]]))" 2>/dev/null; then
    echo "  SYNTAX ERROR: $f"
    "$LUA" -e "assert(loadfile([[$f]]))" 2>&1 | head -3
    FAILED=1
  fi
done < <(find . -name '*.lua' -not -path './.git/*')
if [ "$FAILED" -eq 0 ]; then
  echo "  all files parse"
fi

echo
echo "== harnesses =="
for h in spec/*_harness.lua; do
  [ -e "$h" ] || continue
  printf '  %s\n' "$h"
  if ! "$LUA" "$h" "$ROOT"; then
    FAILED=1
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK"
else
  echo "FAILURES"
fi
exit "$FAILED"
