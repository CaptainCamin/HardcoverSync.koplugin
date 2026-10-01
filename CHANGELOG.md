# Changelog

## 0.6.0

### Added

* Offline progress tracking. Turning a page with no network now records where you are instead of
  dropping the update. Pending changes are queued on disk, so they survive closing the book or
  quitting KOReader, and are sent automatically once you are back online. A `Pending sync` menu
  item shows what is waiting, lets you send it by hand, and lets you discard it.
* Your shelves are now browsable: `Want to Read list` and `Currently Reading list` open as paged
  lists with covers, your rating, and the book's status. Tapping a row opens its details, and the
  icon in the title bar loads the next page.
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
  write:library`. There is no `write:journal` scope: requesting one fails the whole authorization
  with `invalid_scope`. Reading journals and writing journal entries are both covered by the
  library scopes.
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
