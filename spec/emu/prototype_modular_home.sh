#!/usr/bin/env bash
# PROTOTYPE -- throwaway. Renders the modular-Home variants (A Stack, B Dashboard,
# C Tabs) at Kindle Paperwhite size into spec/emu/.out/home_proto_*.png.
KO_EMU_W="${KO_EMU_W:-1072}" KO_EMU_H="${KO_EMU_H:-1448}" KO_EMU_DPI="${KO_EMU_DPI:-300}" \
  exec "$(dirname "$0")/run.sh" home_modular_prototype
