-- Display preferences the UI reads while drawing, kept apart from the Theme so that
-- loading the plugin does not load any widgets. HardcoverSettings sets these when it
-- opens the settings file and again when the setting changes.
return {
  -- Secondary text (author lines, captions, hints) in pure black instead of dark grey.
  -- A beta setting: DARK_GREY stays the default.
  pure_black_text = false,
}
