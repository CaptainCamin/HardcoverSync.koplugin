#!/usr/bin/env bash
# Runs every reproduction in spec/known_bugs/ and lists which bugs still reproduce.
# Exits 0 only when every bug is fixed. Not part of spec/run_all.sh.
cd "$(dirname "$0")/../.."
LUA="${LUA:-luajit}"
command -v "$LUA" >/dev/null 2>&1 || LUA=lua5.1
rc=0
for f in spec/known_bugs/[0-9]*.lua; do
  if "$LUA" "$f" . >/dev/null 2>&1; then
    echo "fixed        $f"
  else
    echo "REPRODUCES   $f"
    rc=1
  fi
done
exit $rc
