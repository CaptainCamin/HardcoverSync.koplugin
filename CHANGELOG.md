# Changelog

## 1.7.1-beta.8

### Fixed

- Covers now appear on Hardcover shelf and list sources in Bookshelf. Fetch-mode sources bypassed Bookshelf's documented cover hook, so Hardcover now attaches covers to the visible page itself.

### Added

- Hardcover shelf and list sources now offer a sort picker in the Bookshelf shelf editor, with the existing Hardcover sort choices.

### Changed

- Hardcover shelves request up to 250 books per page while filling the local cache, reducing round trips for large shelves such as Read.

## 1.7.0

### Added

- **Hardcover sources in Bookshelf.** Add one Hardcover shelf and choose Want to Read, Currently Reading, Read or Did Not Finish; or add one Hardcover list and choose which list. Books load a page at a time, and tapping a remote book opens its Hardcover details.
- **A library on your device.** Until now most screens downloaded everything again each time they opened, even when nothing had changed, and lists did not work offline at all. The plugin now keeps your lists, your shelves and every book on them on the device, and asks Hardcover only what changed. What has not changed opens from the device with no download at all.
- **Every list and every shelf is kept on the device**, yours and the lists you follow, whether or not you have opened them. Home checks them each time it opens, in the requests it already makes for the shelf counts and the "More lists" tile, and downloads only what changed.
- **Lists work offline.** The lists screen, each list and every book on them open at once from the device, offline too, with a note saying when they are from. A book on any list or shelf opens offline with its whole synopsis (the old saved shelves kept only the first 600 characters), and a book you opened online opens offline with everything its details showed.
- **A book's details open at once.** A book you have opened before, that is out and has a synopsis, a cover and a page count, opens from the device with no loading message and no request for the book. Your shelf and rating on it come from your saved shelves, and are brought up to date by the request the "Similar to" strip makes anyway. A book still to come is asked for again once a week. The series is kept for a week, and shown offline.
- **Settings > Download covers for offline** keeps the cover of every book on your shelves and lists on the device, so a shelf browsed offline is not a page of blank boxes. It says first how many covers and about how much it will download, shows its progress with a Stop button, keeps the device from standby while it runs, and turns Wi-Fi on the way Sync does. Running it again carries on where it stopped. The item says how many covers are missing.
- **Refresh** in a shelf's and a list's menu (top left), and a reload icon on a book's details, download them again in full if anything looks out of date.

### Fixed

- Hardcover could fail to initialize when Bookshelf was installed while registering its source pickers. The source helper now resolves the shared remote-book hooks correctly.

### Changed

- **A shelf or list that has not changed costs nothing to open**: no request at all when Home checked a moment ago, or one small request otherwise. One that changed downloads only which books it holds and the books the device does not have yet. Finishing a book no longer reloads your whole Read shelf; a book added to a 25-book list costs about 3 KB instead of 32 KB. Each book is kept once, however many lists and shelves it is on.
- **Covers are fetched at the size they are drawn**, from Hardcover's image service (as hardcover.app does), instead of as uploaded: a cover uploaded at 1.9 MB now comes as 30 KB in a list and 165 KB on its details screen. Twelve covers from a real shelf came to 327 KB instead of 6.2 MB. If the service fails, the cover as uploaded is used. Covers are kept in 30 MB of space rather than as 300 files, so the large covers earlier versions saved are the first to go.
- A book's details fetch its cover at exactly the size it is shown, at JPEG quality 90 instead of 75, and covers are drawn with e-ink dithering, so photos no longer band into flat patches.
- A fresher look: buttons are rounded pills, section headings and the big figures (Stats, a book's numbers) are set in a bold serif, and progress bars are solid black.
- Moving a book to another shelf, rating it or removing it changes the saved shelf at once, instead of throwing both shelves away to be downloaded again.
- **Stats** loads again only when your Read shelf changed, after a change made on this device, or once a week. **For you** is made again only when your ratings or shelves changed, or once a week. Otherwise both open from the device with nothing downloaded.
- Measured on a real account (9 lists, 4 shelves, 758 books):
  - the first Home open after updating saves everything in the background, about 1.1 MB in under half a minute, waiting when Hardcover asks it to slow down;
  - each later check with nothing changed is one request of about 1 KB;
  - opening the 611-book Read shelf reads it from the device in 8 ms, with no request;
  - when Read changes, its update is 51 KB instead of 840 KB;
  - everything opens offline with no request, and the whole library takes 1.5 MB on the device.
- The book count under a list is now counted rather than taken from the number Hardcover stores, which can be off by one.
- Lists, shelves and their books are kept in a small database (`hardcoversync_library.sqlite3` in KOReader's settings folder), using the SQLite that KOReader already includes. The shelves an earlier version saved are carried over the first time Home or a shelf opens. Signing out clears it.

## 1.6.3

### Fixed

- "Check for updates" could say "Couldn't reach GitHub" while online: the whole check was given 5 seconds, too little for the list of releases (over 50 KB, asked for when beta updates are on) on a slow e-reader connection. It now waits up to 30 seconds, asks for fewer releases, and says what happened when it fails: no answer, GitHub refusing requests from this address for a while (its limit is 60 an hour per address), or an answer that is not a release list. The daily check that runs by itself when Home opens still waits only 5 seconds, and when it fails it tries again in a few hours instead of at every Home screen (a refused address stays refused for a while, and each try was a wait on screen).
- A rating set offline could be sent twice when two syncs overlapped (a second sync started while the first was waiting on the connection). A sync that is already running is now waited for.
- Goal changes made offline could stop syncing until KOReader was restarted if one sync ended in an error. The sync is now always released.
- Going to sleep, or losing the connection, did not cancel the book-linking retry that runs while a book is open, so it could fire later against a book that was no longer being tracked. It is now cancelled.

### Changed

- Under the hood, most of what Home, the shelves, Goals, Lists, Vibes, the book details and the request code decide is now in small separate pieces with tests of their own, and the screens only show the result. **Nothing should look or behave differently**; if a screen does, that is a bug worth reporting.

## 1.6.2

### Fixed

- Home's goal card said "No current goal" when the goals had not been saved yet (after signing in again, say): the request for them is the last of four Home makes, and touching the screen while they ran (to scroll down to the card) cancelled it. Those four requests are no longer cancelled by a touch, and a refused goals request is tried once more after a moment.
- Wifi that the plugin switched on for a sync or a screen was switched off the moment the work started, which could cut its requests off. It is now switched off 15 seconds later, and not at all if more work asks for wifi in the meantime. (Not yet tried on a device.)
- Choosing an option in the journal entry dialog (privacy, edition) redrew the whole screen; it now redraws the dialog.

## 1.6.1

### Added

- More in a book's **Details**: the edition's release day and when the book was first published, an audiobook's length ("8h 41m"), everyone else who worked on it by role (illustrator, translator, narrator...), and how many written reviews, lists and editions it has. Reads now has thousands separators.

### Fixed

- Genres, moods, content warnings and the ratings breakdown (1.6.0) were missing for a book opened without a chosen edition: only the request used when an edition is linked asked for them. Both requests now do, and a test checks it.

### Changed

- The ratings breakdown (how many readers gave each rating, with the average marked) moved from the book's details to the top of the **Reviews** screen, under the rating figure. The details keep the genres, moods and content warnings.

## 1.6.0

### Added

- **What readers say, on a book's details**: below About, the breakdown of the ratings the book has had (a histogram from 0.5 to 5 stars with the average marked) and its genres, moods and content warnings as labels, most-used first (tags that many readers marked as spoilers are left out). It comes with the details, so there is no extra loading.
- **Stats**: a tile on Home that opens your reading as a page of charts. The headline numbers (books, pages, average rating), then books per year (or per month for one year), a histogram of how you rate with your average marked, a genre donut with its legend, your most read authors, a breakdown of book lengths with the longest and shortest, and listening time for audiobooks. A **Period** button picks all time or any one year. Books with no finish date (imports) are counted in all time and say so under the chart instead of being guessed into a year; a finish known only to the month or year is never placed on a made-up day. The charts are drawn for e-ink: black and a few well-separated greys, no colour needed. Your finished books are saved on the device, so it opens at once and works offline with a note saying when the copy is from.

## 1.5.0

### Added

- **For you**: a tile on Home that opens books suggested from the ones you rated 4 or more stars. Worked out on the device from Hardcover's own "readers also liked" lists for your favourites (a book high on several of them scores best, one you rated 4.5 or more counts double, and anything already in your library is left out), with the reason under each ("Because you liked ..."). It needs no new permission. The last picks are kept for offline, with the date they are from. Settings > "Show 'For you' on Home" turns the tile off.

- **Vibes**: a tile on Home that opens Hardcover's own recommendation lists for your account: Top Picks, Recommendations and the "Based on ..." ones Hardcover makes for you, then any vibes you made yourself, each with its first covers. Tap one for its books in Hardcover's ranking, 20 at a time. It asks for a new permission (read:vibes): **sign out and back in once** (Settings > Account) to see them; until then the screen says so. It needs a connection.
- **Pending changes** (the Hardcover menu, and Settings on Home): every change still waiting to be sent, one row each, with what it is ("Dune: page 120", "Kindred: mark as Read", "Solaris: rating 4.5", "New goal ..."), and why when one is stuck. Tap a row to cancel just that change (Hardcover keeps what it has); "Send them now" sends the rest. Before, the only choices were send everything or discard everything.

- The account tile in Settings says who is signed in: "Signed in as <username>" instead of "Signed in to Hardcover". The name is kept on the device, so it is shown offline too (an account signed in before this learns it the next time Home opens online).

### Fixed

- The book's panel in the reader (Hardcover button) opens at once. It used to ask Hardcover for the book's record first and show nothing until the answer came, which on a slow connection was seconds of a frozen screen. It now opens from what the device already knows and refreshes in the background, redrawing only if the answer changed something.
- A "Similar to" strip filling in no longer redraws the whole details screen: the loading placeholder is swapped for the books in place, redrawing just the strip.

## 1.4.1

### Added

- The "Similar to …" strip is on the details screen as soon as the book is: its heading says "Loading…" over empty covers where the books will be, so nothing jumps or appears out of nowhere. With no ranking for the book, or if it cannot be loaded, the empty strip goes away.
- **Include beta versions** (Settings > Updates): the update check also offers pre-release builds, newest first. Off by default; the check then looks only at stable releases, as before. A beta knows which beta it is, so you are offered the next beta and then the stable release of it, never an older build.
- One button for both places: **Hardcover** in the main menu now opens the Home screen in the file browser and the open book's panel while reading (it used to open a long menu in the reader). Everything the old reader menu held (link, unlink, change edition, sync now, settings...) is behind the panel's new **More** button. A gesture action, "Hardcover: Home or this book" (Settings > Taps and gestures), does the same from a tap or swipe.

### Fixed

- Home's Currently Reading shows what you read offline: a page past the saved one, a book you finished or dropped offline gone from the list, and a book you started offline at the top. (It used to show the list as it was when last online until the sync went through.)

- Setting the page by hand (reader menu > Update page) while offline no longer fails with "Page could not be saved". The page is shown, kept on the device and sent when you are back online, as it already was when you simply read on. A page you type in is sent even if Hardcover is further along, rather than turning into a sync question.
- The same for a rating set from the reader menu: kept and sent later instead of an error. (Rating from a book's details screen already worked offline.)

## 1.4.0

### Added

- Swipe the "More in …" and "Similar to …" strips left or right to turn their page, the same as the arrows. Swiping up or down on a strip still scrolls the page.
- An **On device** button on a book's details screen opens KOReader's file search with the book's title filled in (a subtitle and the author are left off, so the search finds more), so you can see whether you already have the book. You pick the folder to search in. It is in the file manager and in the reader.

## 1.3.4

### Fixed

- Touching the screen (scrolling the details page, say) no longer cancels the series and "Similar to" strips while they load: KOReader cancels any request in flight on a touch, so those two background requests are now exempt.
- A long book title in the "Similar to" heading is cut short instead of running past the page edge and pushing the book count off it.

### Changed

- In the "Similar to" strip, the bold line under each cover is now the title and the author is under it (it was the other way round).

## 1.3.3

### Fixed

- "Similar to <title>" could go missing on the details screen while the series strip showed. It now loads after the series strip instead of alongside it, is tried again if the request fails (twice) or is cut off by touching the screen (up to eight times, two seconds apart, so scrolling straight away no longer loses it), and says "Couldn't load similar books." if it still can't, so it is never silently absent. A book Hardcover has no ranking for still shows nothing.

## 1.3.2

### Changed

- On a book in a series, the series strip now comes first and "Similar to <title>" below it.

## 1.3.1

### Changed

- Similar books is now a "Similar to <title>" strip of covers on the book's details screen, between About and the series strip, paged with arrows like the series one, instead of a Similar button. It loads after the screen is up, shows nothing if Hardcover has no ranking for the book (or the request fails), and costs two requests per book you open.

## 1.3.0

### Added

- Similar books: a **Similar** button on a book's details screen opens Hardcover's own "readers also liked" ranking for that book (up to 20 books, in Hardcover's order). Tap one to see its details, and add it to a shelf from there. It needs no new permission, so there is nothing to sign in again for. It needs a connection and says so when offline.

## 1.2.2

### Fixed

Found by sending real goal requests to Hardcover for the first time:

- Making a goal works. Hardcover requires a `conditions` field on every goal request, and the plugin never sent one, so a new goal was refused.
- Archiving a goal works. Hardcover wants the whole goal sent with the archive flag, not just the flag.
- Editing a goal no longer shows 0 progress until the next refresh: Hardcover answers a change without the goal, so the plugin now reads the goal back. A goal's own filters (set on the website) are kept when you edit it.

## 1.2.1

### Added

- Tap "your rating" on a book's details screen to rate it. It works offline: the rating shows straight away, is kept on the device, and is sent when you reconnect (or with Sync now). Setting it to 0 clears it. The book needs to be on one of your shelves.

## 1.2.0

### Added

- Goals work offline. Making a goal, changing one, or archiving one with no connection is kept on the device, shows straight away on Home and the Goals screens marked "Waiting to sync", and is sent when the sync runs (when you reconnect, or with Sync now). A goal made offline gets its real identity from Hardcover when it is sent. Editing the same goal twice keeps the newest edit. If Hardcover refuses a change three times it is marked "Not sent" and waits; Sync now tries it again. The pending count in the Sync item includes goal changes.

## 1.1.5

### Changed

- Home redraws once for the numbers and books that arrive together when it opens (the counts, the reading list, the list count and the goals), waiting about a second and a half for the last of them, instead of redrawing for each. Fewer screen flashes on e-ink.

## 1.1.4

### Fixed

- Goals (and every other screen) no longer decide you are offline just because the device's connection check lags: right after waking, or while wifi settles, it can say "no" for a moment with wifi on and joined, which showed "Offline. Showing your goals as of ..." at once and stopped the refresh. The plugin now also trusts KOReader's own record of the connection.

## 1.1.3

### Removed

- Home: the "Page X of Y" bar is gone; the page scrolls by swiping, with the scroll bar at the side.

### Fixed

- Home: the Goals heading is always shown under the Library, even with no current goal (or before goals have loaded), so the Goals screen and "New goal" are always reachable.

## 1.1.2

### Added

- Sync conflicts. If you read on this device offline and Hardcover is already well ahead (5 pages or more, say you carried on on another device), you are asked which to keep: Hardcover's page or this device's. If Hardcover has the book as Read or Did Not Finish but you have new progress here, you are asked whether you are re-reading it; yes starts a NEW read (the old one is never changed) and sets the book to Currently Reading. The questions come up after a sync, when you open the book, and under Settings > Sync > Resolve sync conflicts. "Decide later" keeps your change queued. Choosing Hardcover's page offers to jump there next time you open the book. If Hardcover is only a few pages ahead it quietly wins.

### Fixed

Offline sync (found by an audit of the queue):

- Replaying queued progress no longer moves Hardcover back when you have read further on another device, and the book you have open never shows as further back than the cloud.
- A failed lookup, an unknown user, or a CDN error page (502/503/429) no longer creates or overwrites a book, throws, or loses the page; the change stays queued.
- The last page before "Finished" is now sent before the book is marked Finished.
- Changes made while a sync is running are no longer erased when it finishes.
- A book Hardcover keeps refusing is held after 3 tries instead of blocking every book behind it.
- A failed sync is retried (30 s, 2 min, 10 min, 30 min) while you stay online, and closing a book or suspending syncs when you are already online.
- Opening a book offline with no saved data no longer wakes the device every minute to look for the network; it waits for the network to return.
- Closing or suspending records the page on screen, not the last one counted.
- Reads started offline keep the day you began reading.
- Re-linking a file to another book, removing a book, or setting the page by hand drops the queued changes they replace.
- Ambiguous token-refresh failures (5xx, garbled reply) no longer re-send a refresh token that may already be spent.
- A malformed queue file no longer breaks every sync check.

### Changed

- Fewer and smaller screen refreshes on e-ink. A cover arriving, the counts and reading list landing on Home, the
  sign-in progress bar stepping, a tick in Settings and the reader panel opening or closing now redraw only the part
  of the screen that changed instead of the whole panel (opening Home went from five full-screen refreshes to one),
  covers already decoded are reused when a screen rebuilds, Settings keeps its scroll position when you tick an
  option, and Home no longer rewrites (or reads) the saved shelves just to save its counts. Page turns while
  reading are unchanged: they cost nothing.

## 1.1.1

### Fixed

- Home: scrolling is easier to find and no longer jumps back to the top. A "Page X of Y" bar with ‹ › buttons sits under the scrolling content, and the position is kept when Home refreshes (for example after goals load).

## 1.1.0

### Changed

* Home scrolls when it is taller than the screen, so new sections (goals, and more to come) have room.
  Home shows the first three books you are reading; the "Currently reading" heading, which now says how many
  you are reading, opens the rest.

### Added

* Reading goals. Home shows a "Goals" card under the Library tiles for the goal that is nearest to ending (a
  book goal before a page goal; one that is already done is passed over); the heading opens the Goals screen
  (current goals as cards with a progress bar and a tick where you should be today, then past goals) and the
  card opens that goal (you against pace, what finishing takes). Pace, days left and "books a week to finish"
  are worked out on the device, so goals read the same offline from the saved copy ("Offline. Showing your
  goals as of ..."), and a book you finish offline is counted straight away ("+1 finished offline").
* Make, change and archive goals. The Goals screen has a "New goal" button and a goal's own screen has "Edit
  goal": a form of five rows (name, books or pages, the target, the period -- this year, next year, this month
  or two dates you choose -- and who can see it). Save checks it first and says what to fix; a new goal takes
  your account's visibility unless you choose one. "Archive this goal" hides it (it stays on Hardcover). It needs
  a new sign-in permission (write:goals): if yours predates it, the form says to sign out and back in
  (Settings > Account). Saving needs a connection; offline the form keeps what you typed and says so.
* Add a book to your lists from its details screen: a Lists button opens your lists with a tick box each; tap to
  add or remove, and the details name the lists the book is on. It needs a new sign-in permission (write:lists):
  if yours predates it, the button says to sign out and back in (Settings > Account). Online only.

## 1.0.5

### Added

* Lists. Home has a "More lists" tile (with how many lists you have, yours plus the ones you follow) that opens
  your lists: each with the covers of its first books, its name, how many books it holds, and whether it is
  ranked, private or someone else's. Choosing one opens its books in the shelf screen, in the list's own
  order; a ranked list numbers them #1, #2, and so on. Needs no new permission, and no new sign-in.
* Home: the "Currently reading" heading opens that shelf, the books you are reading are all the same size, and
  the Currently Reading tile is replaced by the lists tile.
* Book details: the series pill, the status pill and the author's name are tappable. The series and the author
  (the first one) open a search for that name; the status opens that shelf. Closing it comes back to the details.
  The author is underlined to show it can be tapped.

## 1.0.3

### Fixed

* Reviews show the reviewer's name. Hardcover only names reviewers to apps granted the `read:users` scope, so
  sign-in now asks for it. If you signed in before this version, reviews still say "A reader" and the Reviews
  screen tells you to sign out and back in (Settings > Account) once to get the names.

## 1.0.2

### Added

* A panel for the open book: a sheet from the bottom of the reading screen showing the title, status, page and
  rating, an "Update Hardcover as I read" tick, and big buttons for Status, Set page, Rating, Add a note,
  Details, Reviews, Change edition and Settings (or just "Link this book" when the book isn't linked). Open it
  from a gesture: Settings > Taps and gestures > pick a gesture > General > "Hardcover: This book".

## 1.0.1

### Added

* Update checker: Settings has "Check for updates" (shows "Update available: vX" once one is known) and a
  "Check for updates automatically" tick. When on, Home asks GitHub at most once a day and mentions a new
  version once. "Install" downloads the release zip, checks it, swaps it in for the installed folder (the old
  copy is kept until the new one is in place) and offers to restart KOReader. Needs `unzip`, which KOReader
  devices ship.

## 1.0.0

### Changed

* Every screen redesigned in one "studio" style: a shared title bar, section headings with a firm rule,
  pills for status and series, boxed buttons, one type scale and one set of rules (`hardcover/lib/ui/theme.lua`).
* Home: a search field, the first book you are reading as a hero card (the rest as compact rows), and the
  four shelves as count tiles.
* Book details: pills for series and shelf, a community rating / readers / your rating strip, and an action bar
  (Shelf, Reviews, Z-library when that plugin is installed) that adapts to two or three buttons.
* Reviews: the book's rating as a figure with stars, review cards with Read more and a spoiler bar, paged with
  Previous / Next. (Hardcover's API gives no breakdown by star, so there is no histogram.)
* Settings: Sync and Account tiles, boxed option rows with tick boxes. Sign in: numbered steps, a big code and
  a waiting bar. The sort menu and shelf picker use the same type.

## 0.9.1

### Fixed

* The About box crashed KOReader when it was online. It compares the newest GitHub release with the installed
  version, and a tag starting with "v" (this repository's releases are `v0.9.0` and so on) made that comparison
  fail. Release tags are now read tolerantly ("v0.9.0", "0.9", anything else is simply ignored), prereleases are
  not offered as updates, and a bad answer from GitHub can no longer raise out of the check.

## 0.9.0

### Added

* **Search in Z-library** on the book details screen, beside Reviews, when the Z-library plugin
  ([ZlibraryKO/zlibrary.koplugin](https://github.com/ZlibraryKO/zlibrary.koplugin)) is installed: it runs that
  plugin's own search for the book's title and first author, and its results screen opens on top. With no Z-library
  plugin there is no button. It relies on that plugin's internals (it has no public API), so a future version of it
  may need this adjusting; if its search cannot be started it opens its search screen with the text filled in
  instead.
* Read other people's reviews of a book. The book details screen has a **Reviews** button under the description. It
  opens a full-screen list, most liked first, ten to a page: the reader's name (or "A reader" when their account is
  private), their rating (like `4.5*`), the likes, and the start of the review. Long reviews end in "Read more" and
  open in full in a scrollable viewer; reviews that contain spoilers stay hidden behind "Contains spoilers - tap to
  show" until tapped; "Load more reviews" fetches the next ten. Reviews are fetched in the background and only when
  you open them (one request per page), say so when you are offline, and offer a retry when a request fails.

* Add a book to a shelf, or change its status, from its details screen. The row under the details now has a **Shelf**
  button next to Close: it says **Add to shelf** for a book that is not in your library, and **Shelf: Currently
  Reading** (or Want to Read, Read, Did Not Finish) for one that is. Tapping it lists the four shelves, plus **Remove
  from library** (after a confirmation) when the book is in it. The status line and the button update in place, keeping
  the cover and your place on the page. It works from search results, shelves and the series carousel, runs in the
  background, offers a retry if it fails, and needs a connection (offline it says so and changes nothing). Your saved
  shelves, their counts and the reading list are refreshed rather than left showing the old status.

* Sort your shelves. The button in the upper left of a shelf (Want to Read, Currently Reading, Read, Did Not Finish)
  opens a Sort by menu: date added (newest or oldest first), title, author, year published, pages (shortest or
  longest first), most readers on Hardcover, community rating, or your own rating. The order is remembered for each
  shelf, shown in the title, and works offline. If a load was interrupted, "Load the rest of the list" is at the top of
  the same menu.

## 0.8.0

### Added

* Search for books from the home screen. A **Search books** button at the top opens a box to type a title or an
  author; the results come back as a list of covers (five to a page, like the shelves), and tapping one opens that
  book's details. Closing the list returns to the home screen. It searches when you submit, not while you type, in the
  background, and says so when it is offline or the search fails (with a retry). Only the first 25 matches are shown,
  to stay within Hardcover's request limits.

### Changed

* In the file browser, choosing `Hardcover` in the menu now opens the home screen directly, instead of a menu whose
  first screen listed Home, Sync, Account, Settings and About. Sync, your account, the settings and About are now all
  in the settings screen behind the cog on the home screen. The reader's Hardcover menu is unchanged.

## 0.7.1

### Fixed

* The sign-in screen's instructions ran off both edges of the screen, cutting off the web address. They now wrap
  and are centred.

## 0.7.0

### Changed (packaging)

* The plugin now installs as `hardcoversync.koplugin` ("Hardcover Sync"), so it can be listed in KOReader's App Store
  next to the original `hardcoverapp.koplugin` instead of being mistaken for it. **Remove the old
  `hardcoverapp.koplugin` folder before installing**: the two register the same menus and actions. Settings carry
  over. The About box and update check now point at this repository.
* `spec/package_release.sh` takes the archive name from `_meta.lua`, so the release workflow's zip is
  `hardcoversync.koplugin.zip` however the repository is checked out.

### Fixed

* Long shelves no longer lose books while loading: the shelf was ordered by date added only, and many books share a
  date, so paging could skip some books and repeat others (607 of 613 books loaded against the real API). Books are
  now ordered by date added, then id.
* Loading a long shelf no longer fails when Hardcover says to slow down (HTTP 429, after 10 quick requests): it
  waits and asks again. Pages are also 100 books instead of 50, so a long shelf needs about half as many requests.

### Changed

* Shelf lists are cleaner and the covers bigger: five tall rows a page (was ten), each a cover, the title and the
  author (with the series). The status (the shelf already says it), page count and year are gone from the rows, the
  keyboard letter boxes no longer sit over the covers, and your rating shows on the right only when you have one.
  The list now fills the whole screen. Fixed a series position printed twice ("Series #3 #3").
* The Home screen has a new look: a title bar, a "Currently reading" section with a card per book (cover, title,
  author and a progress bar with "pages read / pages"), then the shelves as buttons ("Want to Read  ·  42").
  Tapping a card opens that book. The reading list is saved, so Home opens instantly and works offline, and is
  refreshed in the background (the screen only repaints if something changed).

### Removed

* Removed the `Suggest a book` feature: the menu item, the `Hardcover: Suggest a book` gesture action and the
  search-for-this-book-on-your-device dialog behind it. A gesture you had bound to that action will no longer do
  anything and can be unbound in KOReader's gesture settings.

### Performance

* Changing a book's status, removing a read, setting the page, rating, changing visibility, linking a book or
  edition, automatic linking, marking a book finished, and the "update progress" gesture
  no longer freeze KOReader while they wait on Hardcover. Saving a journal entry still waits for the reply
  (the dialog needs the result to answer), but now shows "Saving..." first so you can see the tap registered.
* Screens that load a list or details from Hardcover (shelves, search, editions, book details)
  no longer freeze KOReader while waiting for the reply. The requests now run in the background, so the
  "Loading..." message is actually drawn first, and a tap cancels the request. Previously they ran in-process
  (KOReader logged "unwrapped dismissableRunInSubprocess(), falling back to blocking in-process run") and the
  screen stayed frozen until the reply arrived or timed out.
* Faster startup: the search, shelf, book detail, journal and sign-in screens (and the list and cover widgets
  behind them, about 3,700 lines of code) now load the first time they are opened instead of every time
  KOReader starts.
* Offline page turns write the pending queue to disk once instead of twice.
* Cover images are cached on disk, so revisiting a shelf or search result no longer downloads them again.
* Covers start loading on the next tick instead of after a fixed one second delay, and a cover that appears
  in several rows is downloaded once.

### Fixed

* Book details: the page could scroll sideways by a couple of pixels, showing a heavy bar above the Close button
  whenever a cover was shown. The cover's frame border was not counted in the header's width, and the content was
  as wide as the dialog even though a scroll bar takes room off it.
* Book details: most books showed only a title. A book with no subtitle (and every book shown from the saved
  copy) lost its status, metadata and description, because a missing subtitle cut the layout short.
* Book details: the Back key now closes the screen, including the loading screen; it was bound to nothing.
* Book details: opening the details of a book linked to a specific edition looked up the wrong edition (it
  was sent the book's id), so it failed or showed another book. It now uses the edition's id.
* Book details: long titles, authors and series now wrap instead of running off the screen, the metadata
  labels line up in a fixed column, the full description is shown and scrolls (it was cut off after a few
  lines), and a book with no ratings no longer shows "0.0 (0 ratings)".
* Error messages for a failed list no longer print `table: 0x...`; they say what happened.
* Opening a list with no connection no longer tries to download covers it does not have, which each waited
  out a timeout.
* Tapping `Sync now` crashed KOReader: the menu was never given the function that sends pending changes. It
  also was never given the wifi helper, so any menu item that opens a screen crashed when wifi was off.
* The screen is now refreshed after closing the book details and sign-in screens. KOReader repaints what was
  underneath but only refreshes an e-ink panel if the closing widget asks for it, and these two never did,
  so the closed screen could stay visible until something else triggered a refresh.
* Retrying a list that failed to load (shelves, search, edition lists) no longer leaves the
  failed screen underneath the new one, which showed up again after closing the new one.
* OAuth: the access token is now resolved (and refreshed) before the request is handed to its subprocess.
  Previously a refresh ran inside the subprocess, so the new tokens reached disk but not the running
  plugin, which then refreshed again with the already-used refresh token. Hardcover treats that as a replay
  and revokes the session, so signing in would have been required again after the first weekly expiry.
* OAuth: after a refresh whose outcome is unknown (timeout, or an error thrown mid-request) the plugin no
  longer tries again with the same refresh token; it asks you to sign in. A refresh that threw also no
  longer blocks all later refreshes.
* Fixed a leaked global in the book cache retry handling that could cancel the wrong request after
  switching books.
* The sign-in "Contacting Hardcover" message is now painted before the network request starts.
* Progress read offline on a book that is Want to Read on Hardcover now moves it to Currently Reading before
  recording your page, instead of adding a reading record to a book still marked Want to Read. Progress
  queued for a Finished or Did Not Finish book is dropped rather than reopening it, matching the online
  behavior.
* One book that fails to sync no longer blocks every other book in the offline queue, and an error thrown
  during a sync no longer leaves syncing disabled until KOReader restarts.
* An empty cover list no longer triggers a request for a missing URL.

### Changed

* The Hardcover menu is now two menus. In the reader it is only about the open book: linking, tracking, status,
  rating, notes, book details, sync and the tracking settings (plus `Account`, but only while you are signed
  out). In the file browser it is about your library: `Home` first, then sync, account, settings and about.
  The `Want to Read list` and `Currently Reading list` entries are gone: choose a shelf from `Home` instead.

### Added

* Book details now shows the rest of the book's series as a carousel of covers: "More in <series>", how many
  books it has and whether it is complete, and each cover with its number, title and your own status (Read,
  Reading, Want to Read). Tapping a cover opens that book's details on top, so Close brings you back. The book on
  screen has a heavy border and is not tappable. A longer series is paged with arrows either side. The series
  is fetched in the background after the details appear, and is left out offline.
* The home screen has a settings cog in its title bar that opens the plugin's settings in a screen of their own (options show
  a tick, groups open and have a Back row), with Sync and the Hardcover account (sign in / out) at the top. The reader menu's Settings holds the account too, so you can sign out there, so they can be reached when Home is launched from another plugin.
* A generic book icon is shown where the cover goes, for a book with no cover, while a cover loads, and when it
  cannot be fetched, so every book's details have the same layout.
* A new book details layout: the cover sits beside the title, author, series and a line of facts (year, pages,
  format); under it your own status and rating, then what the community makes of the book; then the
  description under an "About" heading, and the remaining details (publisher, language, ISBN) under "Details".
  The cover comes from the cover cache, so a cover you have seen also shows offline, and is released when the
  screen closes.
* A home screen: `Hardcover` → `Home`, or the new `Hardcover: Home` action (a gesture, profile or another plugin
  can launch it). It lists your shelves (Currently Reading, Want to Read, Read, Did Not Finish) with how many
  books are on each, opens at once from the counts it last saved (so it works offline), and refreshes them in
  the background. Choosing a shelf opens it on top, so closing it comes back to the home screen.
* Your shelves work offline. Want to Read, Currently Reading and any other list are saved on the device
  after they load, so you can open them with no connection. When a saved list
  exists it appears immediately and refreshes quietly in the background; offline you are told it is the saved
  copy and when it was saved. Tapping a book offline shows the details that were saved with the list
  (author, series, rating, description), without edition fields such as publisher and ISBN. Covers you have
  already seen also show offline. Signing out clears the saved lists.
* The `Sync now` menu item is greyed out when there is nothing to sync.
* Offline progress tracking. Turning a page with no network now records where you are instead of
  dropping the update. Pending changes are queued on disk, so they survive closing the book or
  quitting KOReader, and are sent automatically once you are back online. A `Pending sync` menu
  item shows what is waiting, lets you send it by hand, and lets you discard it.
* Your shelves are now browsable: `Want to Read list` and `Currently Reading list` open as lists with
  covers, your rating, and the book's status. Tapping a row opens its details. The whole shelf is loaded, not
  just the first page: the rest arrives in the background while you browse, without moving you off the page
  you are on, and a reload icon in the title bar appears only if loading was interrupted so you can carry on.
* Sign in from the plugin using OAuth's Device Authorization Grant, which needs no browser on the
  reader: the plugin shows a short code, you approve it on a phone or computer, and it keeps the
  connection fresh. Set `client_id` in `hardcover_config.lua` to enable it.
* Added an `Account` menu item showing the current sign-in state, with `Sign in`, `Sign in again`
  and `Sign out`.
* Expiring access tokens are now refreshed automatically, so a week-old session no longer stops
  syncing. A rejected token triggers a refresh instead of disabling the plugin.

### Fixed

* Opening the Want to Read or Currently Reading list crashed KOReader. Rows in those lists were
  being drawn as folders rather than books, because the list did not mark them as files the way the
  search list does. Both lists now open normally.
* Tapping an item in the plugin menu could do nothing at all, leaving the screen unchanged until
  the device was power-cycled. Two causes, both fixed:
  * The menu was waiting on a wifi callback that never arrived in airplane mode, while a connection
    was already pending, or on a device that cannot restore wifi, so the screen was never opened.
    Menus now open straight away and the wifi prompt is layered on top; if there is no connection
    you get a message saying so instead of nothing happening.
  * The About box and the sign-in flow asked the network *before* showing anything, so a slow or
    unreachable host meant no screen at all. The release check in particular had no timeout. Both
    now put a screen up first and fill in the result afterwards.

### Notes

* Personal access tokens still work exactly as before and are used whenever `client_id` is unset,
  so existing installs keep working after upgrading.
* Refresh tokens rotate on every use and Hardcover revokes the whole chain if one is presented
  twice, so the plugin never retries a refresh whose outcome it does not know. If that happens you
  are asked to sign in again rather than being silently locked out.
* The requested scopes are `read:catalog read:catalog:search read:me:content read:library
  read:social write:library`. There is no `write:journal` scope: requesting one fails the whole authorization
  with `invalid_scope`. Reading journals and writing journal entries are both covered by the
  library scopes.
* `read:social` is what allows reading other readers' reviews. Your Hardcover app must allow it (asking for a
  scope the app does not allow fails the whole sign in), and a sign in made before this change does not have it:
  sign out and sign in again once reviews arrive. The plugin now records which scopes each sign in was
  granted, so it can tell a missing scope from a failed request.
* Signing out now clears the stored tokens from disk as well as memory. Previously they survived a
  restart, so signing out appeared not to work.

## 0.5.0

### Added

* Reading progress is now tracked while offline and synced to Hardcover once a connection is available. Book
  status is cached locally after each successful sync, so opening a linked book with no network rebuilds your
  position from that cache and keeps recording. Page updates and status changes made offline are held in a
  queue and flushed on reconnect, on resume, and when the document closes.
* Added a `Sync now` menu item. It shows how many changes are waiting (`Sync pending changes (n)`), syncs them
  on demand, and explains that queued changes will sync later when offline. Tap and hold it to discard
  queued changes after confirming.
* Added `Book details` for the currently linked book, showing author, series, format, publisher, page count,
  language, publication year, ISBN, community rating, reader counts and description, along with your own
  status and rating.
* Added `Want to Read list` and `Currently Reading list`, which browse your Hardcover shelves a page at a time
  with cover images. Selecting a book opens its details.

### Fixes

* Opening a linked book while offline no longer stalls progress tracking until the network returns.
* Disconnecting mid-session no longer stops tracking; the local cache is used until the connection is back.
* `HardcoverSettings` no longer shares one settings handle between instances, which could leak settings across
  plugin reloads.
* Fixed a crash when a cache fetch needed to be retried before its cancel handle had been assigned.

## 0.4.0 (2026-04-26)

### Added

* Added option to show a confirmation when changing a book's currently read status to reduce misclick issues

## 0.3.1 (2026-02-18)

### Added

* Added support for [Updates Manager Plugin](https://github.com/advokatb/updatesmanager.koplugin) (min: v1.4.0)

### Fixes

* Fix page change gestures causing a refresh (even when there are no pages to navigate to) of the suggest a book, and
  book/edition linking dialogs

## 0.3.0 (2026-01-24)

### Added

* Added "suggest a book" to hardcover menu. Displays 10 books from your to-read list at random.
* Plugin will now consider the `hardcover-slug` ebook identifier in addition to `hardcover` identifier (
  by [@yd4dev](https://github.com/yd4dev))

## Fixes

* Fix page map crash when loading document formats that don't support page maps (like CBR)
* Fix page map crash when document is out of range of the active page map

## 0.2.0 (2025-11-22)

### Added

* Publisher page labels will now be used for reading progress without translation
* Percentage calculation used to determine when to create new journal entries now uses the page
  label divided by edition page count. This is weird but ensures that journal reading percentage is close to the
  selected interval
* Plugin will now ignore page mapping if publisher page labels are disabled in KOReader

### Fixes

* Switch to `socket.http` implementation to better support proxy usage

### Chores

* Fix zip release directory structure

## 0.1.3 (2025-09-10)

### Added

* Register action to immediately update reading
  progress [#19](https://github.com/Billiam/hardcoverapp.koplugin/issues/19)
* Add event to open journal entry dialog [#27](https://github.com/Billiam/hardcoverapp.koplugin/issues/27)

## 0.1.2 (2025-05-13)

### Added

* Hardcover menu now visible in both reading view and file manager view
* Sort ebooks above physical books in edition list
* Support [airplane mode plugin](https://github.com/kodermike/airplanemode.koplugin)

### Fixes

* Remove 50 book limit from edition selection

## 0.1.1 (2025-04-12)

### Added

* Reduce data requested from search API endpoint

### Fixes

* Fix missing invalid API key warning after request failure

### Chores

* Remove dependency on coverbrowser plugin

## 0.1.0 (2025-03-21)

### Added

* Prompt to enable wifi if needed before opening journal dialog

### Chores

* Include user agent in requests to hardcover API

### Fixes

* Always show book format and reader count in list view
* Fix potential crash when document is no longer available when fetching book cache
* Fix crash at some font sizes when using compatibility mode and searching for books with long author names
* Fix compatibility mode not displaying authors at some font sizes
* Fix compatibility mode not displaying edition type at some font sizes

## 0.0.8 (2025-01-16)

### Added

* Display edition language and series in book searches
* Add option to turn on/off wifi automatically for background updates on some devices where possible
* Changed manual page update dialog to allow updating by document page or hardcover page with synchronized display

### Fixes

* Fix crash when navigating to previous page in search menu after images have loaded
* Fix crash related to book settings when active document has been closed
* Fall back to less specific reading format when edition format is unavailable
* Fix ISBN values with hyphens being ignored by automatic book linking
* Fix pages exceeding a document's page map being treated as lower numbers than previous page

### Chores

* Renamed lib directory and config.lua to prevent conflicts with other plugins

### ⚠️ Upgrading

The plugin now looks for `hardcover_config.lua` instead of `config.lua`. Rename this file (which contains your API key)
on your device.

## 0.0.7 (2024-12-30)

### Added

* Added option to update books by percentage completed rather than timed updates
* Display error and disable some functionality when Hardcover API indicates that API key is not valid, in preparation
  for [upcoming API key reset](https://github.com/Billiam/hardcoverapp.koplugin/issues/6)
* Allow linking books, enabling/disabling book tracking from KOReader's gesture manager

### Fixes

* Fix crash when linking book from hardcover menu
* Fix automatic book linking not working unless track progress (or always track progress) already set
* Fix manual and automatic book linking not working for hardcover identifiers
* Fix failure to mark book as read when end of book action displays a dialog
* Fix a crash when searching without an internet connection
* Fix page update tracking not working correctly when using "always track progress" setting
* Fix off-by-one page number issue when document contains a page map
* Fix unable to set edition if that edition already set in hardcover

### Chores

* Update default edition selection in journal dialog to use multiple API calls instead of one due to upcoming Hardcover
  API limits
* Fetch book authors from cached column in Hardcover API

## 0.0.6 (2024-12-10)

### Added

* Added compatibility mode with reduced detail in search dialog for incompatible versions of KOReader

### Fixes

* Fix crash when selecting specific edition in journal dialog

## 0.0.5 (2024-12-04)

### Fixes

* Fix failed identifier parsing by Hardcover slug
* Fix error when searching for books by Hardcover identifiers
* Fix note content not saving depending on last focused field
* Fix note failing to save without tags

## 0.0.4 (2024-12-01)

### Fixes

* Fix error when sorting books in Hardcover search

## 0.0.3 (2024-11-29)

### Fixes

* Fixed autolink failing for Hardcover identifiers and title
* Fixed autolink not displaying success notification

## 0.0.2 (2024-11-27)

### Fixes

* Increased default tracking frequency to every 5 minutes
* Skip book data caching if not currently viewing a document
* Fix syntax error in suspense listener
* Only eager cache book data when book tracking enabled (for page updates)
* Fix errors when device resumed without an active document

## 0.0.1 (2024-11-24)

Initial release
