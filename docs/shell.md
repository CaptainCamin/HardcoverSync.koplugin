# The shell

`hardcover/lib/ui/shell.lua`: Home, Library, Goals and Stats as tabs of one screen with a navigation bar
(`components/nav_bar.lua`), behind Settings > "New navigation bar (beta)". With the setting off,
`DialogManager:showHome` opens the old Home as before.

- **Bodies.** Each tab is a plain screen of the plugin built *hosted*: `shell`, `width`, `height` (and
  `parent` inside the Library) passed to its constructor, no title bar, no close, repaints through the
  shell (`ui/hosted.lua`). Built on first use and kept, so a tab keeps its scroll position and any answer
  that arrived while it was hidden.
- **Liveness.** A hosted body is not on KOReader's window stack. Every "is it still there?" check goes
  through `ui/live.lua` (`Live.shown`), which says yes while the body's shell is shown.
- **Registry.** `screens():open(kind)` / `discard(kind)` work on hosted bodies (`discard` unmounts one from
  the shell instead of closing it). Field names (`manager.home_dialog`, ...) are unchanged.
- **Pushed screens.** A shelf's books, book details, a goal, Settings are separate windows above the shell;
  closing one reveals the shell as it was.
- **Back.** On any tab but Home it goes to Home; on Home it leaves.
- **Home** (`ui/home_body.lua`) never scrolls: cards first, as many as fit (three at most); with fewer than
  one card's room the shelves go, then the sync line. Never the nav bar.
- **Library** (`ui/library_body.lua`): Shelves (`ui/shelves_body.lua`) | Lists | Vibes (with "For you" first).
- One tab switch is one full-screen refresh (`perf_screens` budgets it).
