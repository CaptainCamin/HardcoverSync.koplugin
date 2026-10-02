#!/usr/bin/env bash
#
# Headless KOReader emulator runner.
#
# Renders plugin screens to PNGs using the real KOReader frontend, so a change
# can be checked without porting it to a device. Run from anywhere:
#
#   spec/emu/run.sh                 # every scenario
#   spec/emu/run.sh shelf journal   # just these
#   spec/emu/run.sh --list
#
# Environment:
#   KO_EMU_APP   KOReader install (default /Applications/KOReader.app)
#   KO_EMU_OUT   output dir       (default spec/emu/.out)
#   KO_EMU_W/H   screen size      (default 1200x1600)
#   KO_EMU_DPI   screen density   (default: KOReader's own, which is NOT a device's;
#                set it to match, e.g. 300 for a Kindle Paperwhite)
set -uo pipefail

EMU_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$EMU_DIR/../.." && pwd)"

KO_EMU_APP="${KO_EMU_APP:-/Applications/KOReader.app}"
KOREADER_DIR=""
for c in "$KO_EMU_APP/Contents/koreader" "$KO_EMU_APP"; do
  if [ -f "$c/setupkoenv.lua" ] && [ -d "$c/frontend" ]; then
    KOREADER_DIR="$c"
    break
  fi
done
if [ -z "$KOREADER_DIR" ]; then
  echo "no KOReader install at $KO_EMU_APP -- set KO_EMU_APP" >&2
  exit 1
fi

# A private data dir. KOReader's KO_HOME redirects everything: settings,
# library, plugins, cache. A run here cannot touch a real installation.
export KO_HOME="${KO_EMU_HOME:-$EMU_DIR/.home}"
mkdir -p "$KO_HOME/settings" "$KO_HOME/fonts" "$KO_HOME/cache" "$KO_HOME/books"

# No window, no focus stealing, no real key input. Everything is driven from
# Lua against the real widget stack.
export SDL_VIDEODRIVER=dummy
export DISABLE_TOUCH=1

SCREEN_W="${KO_EMU_W:-1200}"
SCREEN_H="${KO_EMU_H:-1600}"
SCREEN_DPI="${KO_EMU_DPI:-}"
# built here, not inside the heredoc: bash drops the quotes around the key when
# it sits in a ${var:+...} expansion there, which wrote an unloadable file
DPI_LINE=""
if [ -n "$SCREEN_DPI" ]; then
  DPI_LINE="  [\"screen_dpi\"] = $SCREEN_DPI,"
fi

# Screen geometry is read from this setting by frontend/device/sdl/device.lua,
# which is the only supported way to size the emulated panel.
cat > "$KO_HOME/settings.reader.lua" <<EOF
return {
  ["sdl_window"] = { width = $SCREEN_W, height = $SCREEN_H, left = 0, top = 0 },
  ["device_id"] = "koreader-emu-harness",
  ["dev_no_c_blitter"] = true,
  ["language"] = "en",
$DPI_LINE
}
EOF

# cwd must be the KOReader install: setupkoenv's ffi.loadlib resolves libs/
# relative to it, and resources/ and fonts/ are read relative to it too.
cd "$KOREADER_DIR"

SCENARIOS=()
for f in "$EMU_DIR"/scenarios/*.lua; do
  [ -e "$f" ] || continue
  SCENARIOS+=("$(basename "$f" .lua)")
done

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "${SCENARIOS[@]}"
  exit 0
fi

SELECTED=()
if [ "$#" -gt 0 ]; then
  for want in "$@"; do
    found=0
    for s in "${SCENARIOS[@]}"; do
      [ "$s" = "$want" ] && found=1
    done
    if [ "$found" -eq 0 ]; then
      echo "unknown scenario: $want" >&2
      echo "available: ${SCENARIOS[*]}" >&2
      exit 1
    fi
    SELECTED+=("$want")
  done
else
  SELECTED=("${SCENARIOS[@]}")
fi

# The plugin under test is loaded straight from the working tree via a symlink
# into the emulated plugins dir. No copy, no re-zip: a harness run tests the
# files as they are, including uncommitted ones.
mkdir -p "$KO_HOME/plugins"
ln -sfn "$PLUGIN_ROOT" "$KO_HOME/plugins/hardcoverapp.koplugin"

FAILED=0
for s in "${SELECTED[@]}"; do
  echo "== $s =="
  if ! SDL_VIDEO_WINDOW_POS="0,0" \
       "$KOREADER_DIR/luajit" "$EMU_DIR/run_scenario.lua" "$EMU_DIR/scenarios/$s.lua" 2>&1 \
       | grep -v -e '^ffi\.findlib' -e '^ffi\.load' -e 'dlopen' \
                 -e '^lib_search_path' -e '^lib_basic_format' -e '^lib_version_format' \
                 -e '^has monolibtic'
  then
    FAILED=1
  fi
  echo
done

if [ "$FAILED" -eq 0 ]; then
  echo "OK"
else
  echo "FAILURES"
fi
exit "$FAILED"
