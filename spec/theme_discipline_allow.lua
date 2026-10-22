-- Counts of hard-coded sizes, fonts and colours that existed in hardcover/lib/ui when
-- spec/theme_discipline_harness.lua was added. This table may only shrink: fix an offender, then lower
-- its count here (THEME_ALLOW_PRINT=1 prints a fresh table). Never raise a number; use Theme.* instead.
--   scaleBySize / Size / getFace: sizes and fonts that belong in Theme.px, Theme.space, Theme.type.
--   color: Blitbuffer.COLOR_* named directly instead of Theme.BLACK / Theme.WHITE / Theme.DARK_GREY.
--   hex: raw grey levels. chart_widgets.lua keeps its greys until the grey policy is decided
--        (docs/e-ink-design.md), so its entries stay.
return {
  ["hardcover/lib/ui/book_detail_dialog.lua"] = { scaleBySize = 2, color = 2 },
  ["hardcover/lib/ui/chart_widgets.lua"] = { hex = 8, color = 2 },
  ["hardcover/lib/ui/components/button.lua"] = { color = 2 },
  ["hardcover/lib/ui/components/checkbox.lua"] = { color = 2 },
  ["hardcover/lib/ui/components/draw.lua"] = { color = 1 },
  ["hardcover/lib/ui/components/fab.lua"] = { color = 1 },
  ["hardcover/lib/ui/components/input_dialog.lua"] = { Size = 3 },
  ["hardcover/lib/ui/components/nav_bar.lua"] = { color = 1 },
  ["hardcover/lib/ui/components/note.lua"] = { color = 2 },
  ["hardcover/lib/ui/components/progress_bar.lua"] = { color = 2 },
  ["hardcover/lib/ui/components/radio.lua"] = { color = 1 },
  ["hardcover/lib/ui/components/scroll_control.lua"] = { scaleBySize = 1 },
  ["hardcover/lib/ui/components/search_field.lua"] = { color = 1 },
  ["hardcover/lib/ui/components/switch.lua"] = { color = 2 },
  ["hardcover/lib/ui/components/tabs.lua"] = { color = 1 },
  ["hardcover/lib/ui/components/top_bar.lua"] = { color = 1 },
  ["hardcover/lib/ui/cover_box.lua"] = { Size = 1 },
  ["hardcover/lib/ui/details_screen.lua"] = { color = 1 },
  ["hardcover/lib/ui/goal_dialog.lua"] = { color = 2 },
  ["hardcover/lib/ui/goal_form_dialog.lua"] = { color = 1 },
  ["hardcover/lib/ui/goals_dialog.lua"] = { color = 2 },
  ["hardcover/lib/ui/home_body.lua"] = { color = 1 },
  ["hardcover/lib/ui/icon_list_body.lua"] = { color = 1 },
  ["hardcover/lib/ui/journal_dialog.lua"] = { Size = 6, getFace = 4 },
  ["hardcover/lib/ui/library_body.lua"] = { color = 1 },
  ["hardcover/lib/ui/lists_dialog.lua"] = { scaleBySize = 1, color = 1 },
  ["hardcover/lib/ui/reader_panel.lua"] = { color = 1 },
  ["hardcover/lib/ui/reviews_dialog.lua"] = { scaleBySize = 5, color = 1 },
  ["hardcover/lib/ui/series_carousel.lua"] = { Size = 2 },
  ["hardcover/lib/ui/settings_dialog.lua"] = { color = 1 },
  ["hardcover/lib/ui/shelf_dialog.lua"] = { color = 1 },
  ["hardcover/lib/ui/shell.lua"] = { color = 1 },
  ["hardcover/lib/ui/shelves_body.lua"] = { color = 1 },
  ["hardcover/lib/ui/signin_dialog.lua"] = { scaleBySize = 2, color = 1 },
  ["hardcover/lib/ui/stats_dialog.lua"] = { color = 2 },
  ["hardcover/lib/ui/text_screen.lua"] = { color = 1 },
}
