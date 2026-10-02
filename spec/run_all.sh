#!/usr/bin/env bash
# Runs every check in spec/ and reports what failed.
#
# Kept as a script rather than a make target because the release workflow and
# the README both invoke it, and because it has to work on a stock Lua with no
# busted or luarocks installed -- which is the situation on a fresh machine.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Prefer LuaJIT when it is available, because that is what the device runs.
#
# This is not a nicety. The plugin ships to KOReader, which is LuaJIT (Lua 5.1
# semantics), and CI pins luaVersion 5.1 -- but a developer's `lua` on a modern
# machine is 5.4 or 5.5. Code that parses and runs under 5.5 can still be a
# syntax error under 5.1, so a green run on the wrong Lua proves nothing about
# the device. Set LUA= to override, e.g. LUA=lua5.1 ./spec/run_all.sh
LUA="${LUA:-}"
if [ -z "$LUA" ]; then
  for candidate in luajit lua5.1 lua; do
    if command -v "$candidate" >/dev/null 2>&1; then
      LUA="$candidate"
      break
    fi
  done
fi

# When neither luajit nor lua5.1 is installed, say so rather than silently
# testing on whatever `lua` happens to be.
LUA_IS_51=0
if [ -n "$LUA" ]; then
  case "$("$LUA" -v 2>&1)" in
    *LuaJIT*|*"5.1"*) LUA_IS_51=1 ;;
  esac
fi

FAILED=0
FAILED_LIST=()

echo "== interpreter =="
if [ -z "$LUA" ]; then
  echo "  no lua interpreter found"
  FAILED=1
else
  echo "  $LUA ($("$LUA" -v 2>&1 | head -1))"
  if [ "$LUA_IS_51" -eq 0 ]; then
    # Not fatal -- the run is still useful -- but the reader should know the
    # result does not speak for the device.
    echo "  WARNING: this is not Lua 5.1 / LuaJIT. The plugin targets LuaJIT, so"
    echo "           a green run here does not prove the device can load this."
    echo "           Install luajit (macOS: brew install luajit) and re-run."
  fi
fi

echo
echo "== syntax ="
# Every Lua file must at least parse. Cheap, and it catches the single most
# common way a plugin ships broken.
while IFS= read -r f; do
  if ! "$LUA" -e "assert(loadfile([[$f]]))" 2>/dev/null; then
    echo "  SYNTAX ERROR: $f"
    "$LUA" -e "assert(loadfile([[$f]]))" 2>&1 | head -3
    FAILED=1
    FAILED_LIST+=("syntax: $f")
  fi
# -type f and the -not -path lines: CI installs Lua into a `.lua` directory in the
# workspace, which -name '*.lua' also matches, and it is not source. Nor is .claude/
# (agent worktrees: another checkout, possibly mid-edit, that must not fail this run).
done < <(find . -name '*.lua' -type f -not -path './.git/*' -not -path './.lua/*' -not -path './.luarocks/*' -not -path './.claude/*')
if [ "$FAILED" -eq 0 ]; then
  echo "  all files parse"
fi

echo
echo "== harnesses =="
for h in spec/*_harness.lua; do
  [ -e "$h" ] || continue
  printf '  %s\n' "$h"
  # Capture output rather than streaming it: a harness that dies mid-run leaves a
  # truncated last line, and "FAILURES" with no `[FAIL]` anywhere reads like a
  # broken script instead of a broken harness. Naming the culprit is the whole
  # point of this loop.
  if ! out="$("$LUA" "$h" "$ROOT" 2>&1)"; then
    FAILED=1
    FAILED_LIST+=("$h")
    echo "$out" | sed 's/^/    /'
    # Surface a failing assertion if there is one, so the summary below and the
    # detail here agree.
    echo "$out" | grep -E '^\s*\[FAIL\]' | sed 's/^/  /' || true
  else
    echo "$out" | tail -1 | sed 's/^/    /'
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK"
else
  echo "FAILURES"
  # Always name what failed. A bare "FAILURES" with no list is the failure mode
  # this script used to have: a harness exited non-zero without printing a
  # [FAIL] line, and the output gave no clue which one.
  echo
  echo "failed:"
  for item in "${FAILED_LIST[@]}"; do
    echo "  - $item"
  done
fi
exit "$FAILED"