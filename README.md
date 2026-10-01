# Hardcover.app for KOReader

A KOReader plugin to update your [Hardcover.app](https://hardcover.app) reading status

## Installation

1. Download and extract the latest release: https://github.com/Billiam/hardcoverapp.koplugin/releases/latest
2. Rename `hardcover_config.example.lua` to `hardcover_config.lua` and set it up as described below
3. Copy the `hardcoverapp.koplugin` folder to the KOReader plugins folder on your device
4. Restart KOReader

## Signing in

### With a Hardcover account (recommended)

1. Register an app at https://hardcover.app/account/developer-apps/new
2. Set the application type to **Mobile, desktop, or CLI**, leave **Device
   Authorization Grant** enabled, and allow these scopes:
   `read:catalog read:catalog:search read:me:content read:library
   write:library`
3. Copy the **client id** into `hardcover_config.lua`:

   ```lua
   return {
     client_id = 'your-client-id',
   }
   ```

4. In KOReader, open the Hardcover menu and choose `Account` → `Sign in to
   Hardcover`. The plugin shows a short code and a web address. Open that
   address on a phone or computer, enter the code, and approve. The plugin
   signs itself in and keeps the connection fresh from then on.

There is no secret to store: this is a public client using the device flow,
which is why no browser is needed on the reader.

### With a personal access token

If you would rather use a token, get one from
https://hardcover.app/account/api and put it in `hardcover_config.lua`:

```lua
return {
  token = 'abcde...fghij'
}
```

The `token` field is only used when `client_id` is empty. Note that tokens now
carry an expiration and a scope list, so choose permissions that cover what the
plugin uses, and expect to replace an expired token.

## Usage

The Hardcover plugin's menu can be found in the Bookmark top menu when a document is active.

![Hardcover plugin main menu with the following menu items: the currently linked book (Frankenstein), an option to change the edition specific edition, a checkbox to Automatically track progress, Update status (which opens a submenu), Settings (which opens a submenu), and About](https://github.com/user-attachments/assets/0fd8f6fb-3a61-471f-9450-9a0b3dadc9d1)

### Linking a book

Before updates can be sent to Hardcover, the plugin needs to know which Hardcover book and/or edition your current
document represents.

You can search for a book by selecting `Link book` from the Hardcover menu. If any books can be found based
on your book's metadata, these will be displayed.

![A dismissable window titled "Select book" with a search button displayed as a magnifying glass in the upper left corner, and a close button on the right. A list of 14 possible books is displayed below this, with buttons to change result pages. The book title ande author are displayed if available, as well as the number of reads by hardcover users and the number of pages if available. Some books display cover images](https://github.com/user-attachments/assets/99d16ef0-6dda-41d8-bfdc-32c97ae09d87)

If you cannot find the book you're looking for, you can tap the magnifying glass icon in the upper left corner and
begin a manual search.

![An input dialog titled "New Search" with the text "Frankenstein Mary Shelley". Behind the dialog, a recent book search result dialog appears with two books](https://github.com/user-attachments/assets/73619448-9821-410a-901f-d8fc61185dd3)

Selecting a Hardcover book or edition will link it to your current document, but will not automatically update your
reading status on Hardcover. This can be done manually from the [update status](#updating-reading-status) menu, or using
the [track progress](#automatically-track-progress) option.

To clear the currently linked book, tap and hold to the `Linked book` menu item for a moment.

After selecting a book, you can set a specific edition using the `Change edition` menu item. This will present a list
of available editions for the currently linked book. No manual edition search is available

### Updating reading status

![A menu to update book status containing: a set of radio buttons for the current book status (Want to read, currently reading, read and did not finish), an item to unset the current status. The following section has an item to update the current page (displaying page 154 of 353), add a note, update rating (displaying the current rating of 4.5 stars), and an item to update the status privacy settings which open in a submenu](https://github.com/user-attachments/assets/55b33a0a-bda8-4ec9-918d-0409266abe3b)

To change your book status (Want To Read, Currently Reading, Read, Did Not Finish) on Hardcover, you open the
`Update status` menu after [linking your book](#linking-a-book). You can also remove the book from your Hardcover
library using the `Remove` menu item.

From this menu you can also update your current page and book rating, and add a new journal entry

Tap and hold the book rating menu item to clear your current rating.

### Add a journal entry quote

Selecting text to quote:

![Book text with two sentences highlighted. KOReader's highlight menu popup is displayed in the center with an option at the end for Hardcover quote](https://github.com/user-attachments/assets/5dba19a4-f72a-4894-820c-0cfdcc55bf68)

![A form window titled "Create journal entry". The previously selected text appears in an input field at the top. Below that is a toggle for whether the journal entry should be a note or a quote. A button to change the journal edition follows, and one to change the current page. Below those, a toggle to change the journal entry privay with the options Public, Follows and Private. Lastly are two input fields to set journal entry tags and spoiler tags respectively, and then buttons to save the entry or close the window](https://github.com/user-attachments/assets/c386f153-330f-4e1f-afa1-12fdf48a1216)

After selecting document text in a linked document, choose `Hardcover quote` from the highlight menu to display the
journal entry form, prefilled with the selected text and page.

### Automatically track progress

Automatic progress tracking is optional: book status and reading progress can instead be
[updated manually](#update-reading-status) from the `Update status` menu.

When track progress is enabled for a book which has been linked ([manually](#linking-a-book)
or [automatically](#automatic-linking)),
page and status updates will automatically be sent to Hardcover for some reading events:

* Your current read will be updated when paging through the document, no more than once per minute. This frequency
  [can be configured](#track-progress-frequency).
* When marking a book as finished from the file browser, the book will be marked as finished in Hardcover
* When reaching the end of the document, if the KOReader settings automatically mark the document as finished, the
  book will be marked as finished in Hardcover. If the KOReader setting instead opens a popup, the book status will be
  checked
  ten seconds later, and if the book has been marked finished, it will be marked as finish in Hardcover.

For all documents, but in particular for reflowable documents (like epubs), the current page in your reader may not
match that of the original published book.

Some documents contain information allowing the current page to map to the published book's pages. For these documents,
the mapped page will be sent to Hardcover if possible.

For documents without these, your progress will be converted to a percentage of the number of pages in the original
published book, with a calculation like:
`round((document_page_number / document_total_pages) * hardcover_edition_total_pages)`.

In both cases, this may not exactly match the page of the published document, and can even be far off if there
are large differences in the total pages.

### Reading offline

Progress tracking keeps working without a connection. After each successful sync the plugin saves a local copy of
the book's status and position, so opening a linked book with no network rebuilds your position from that copy and
keeps recording from there. Page turns and status changes made while offline are held in a queue and pushed to
Hardcover as soon as a connection is available — including when you reconnect, resume the device, or close the
document.

The menu shows how many changes are waiting:

* `Sync now` — no changes waiting. Select it to sync on demand.
* `Sync pending changes (n)` — `n` changes are queued. Select it to sync now, or when offline it will tell you
  they will sync later.
* Tap and hold either to discard everything queued, after confirming.

If a sync fails, the changes stay queued and are retried later rather than dropped.

### Book details

`Book details` shows everything Hardcover knows about the currently linked book: author, series, format,
publisher, page count, language, publication year, ISBN, community rating, reader counts and the description,
alongside your own status and rating.

### Browsing your lists

`Want to Read list` and `Currently Reading list` open your Hardcover shelves, with cover images where available.
Select a book to open its details. The whole shelf is loaded: the first books appear straight away and the rest
arrive in the background. If loading is interrupted (for example by tapping the screen while it loads, or by losing
your connection), a reload icon appears in the upper left so you can carry on from where the list stops.

Lists you have opened are saved on the device, so they also open with no connection, showing the saved copy.

Both list items work whether or not a book is currently open.

## Settings

![A settings menu containing the following options: Checkboxes for Automatically link by ISBN, Automatically link by Hardcover identifiers and Automatically link by title and author. Below that is an item to change the Track progress frequency showing the current setting (1 minute), and a checkbox to Always track progress by default.](https://github.com/user-attachments/assets/dc8a397b-f36d-49da-b880-d04d47219ed0)

### Automatic linking

With automatic linking enabled, the plugin will attempt to find the matching book and/or edition on Hardcover
when a new document is opened, if no book has been linked already. These options are off by default.

* **Automatically link by ISBN**: If the document contains ISBN or ISBN13 metadata, try to find a matching edition for
  that ISBN
* **Automatically link by Hardcover**: If the document metadata contains a `hardcover` identifier (with a URL slug for
  the book)
  or a `hardcover-edition` with an edition ID, try to find the matching book or edition.
  (see: [RobBrazier/calibre-plugins](https://github.com/RobBrazier/calibre-plugins/tree/main/plugins/hardcover))
* **Automatically link by title**: If the document metadata contains a title, choose the first book returned from
  hardcover search results for that title and document author (if available).

### Track progress settings

By default, (when enabled) updates will be sent to hardcover at a frequency you can select, no more often than once per
minute. If you don't need updates this frequently, and to preserve battery, you can decrease this frequency further.

You can also choose to update based on your percentage progress through a book. With this option, an update will be sent
when you cross a percentage threshold (for example, every 10% completed).

### Always track progress by default

When always track progress is enabled, new documents will have the [track progress](#automatically-track-progress)
option enabled automatically. You can still turn off `Track progress` on a per-document basis when this setting is
enabled.

Books still must be linked (manually or automatically) to send updates to Hardcover.

### Enable wifi on demand

On some devices, wifi can be enabled on demand without interruption. When this feature is enabled, wifi will be enabled
automatically before some types of background API requests (namely updating the initial application cache, and updating
your reading progress), and then disabled afterward.

This can improve battery life significantly on some devices, particularly with infrequent page updates.

This feature is not used for all network requests. If wifi has not been manually enabled the following will not work:

* fetching or updating your reading status manually
* manually updating your reading progress from the menu

### Confirm changes to book read status

By default, changes to a book's read status (Want to Read, Did Not Finish, etc) will immediately update in Hardcover as
soon as you press them. Enable this setting to display a confirmation prompt before those changes are sent.

### Compatibility mode

When enabled, book and edition searches will be displayed in a simplified list with minimal data. This mode is the
default for KOReader versions prior to v2024.07

## Development

Everything except the live API calls can be checked without a device or an API token:

```bash
./spec/run_all.sh
```

That runs, in order: a Lua 5.1 syntax check over every file, the pure-module specs, a structural check of the
generated GraphQL, and the dialog, menu, and app harnesses (the last three load the real plugin code against
stubbed KOReader widgets and drive it).

Individually:

| Command | What it covers |
|---|---|
| `lua spec/runner.lua` | pure-module specs (`spec/lib/*_spec.lua`) |
| `lua spec/graphql_syntax_check.lua` | generated queries are well formed |
| `lua spec/ui_harness.lua` | the shelf and book detail dialogs |
| `lua spec/menu_harness.lua` | menu items and their callbacks |
| `lua spec/oauth_client_harness.lua` | OAuth HTTP layer, form encoding, error decoding |
| `lua spec/auth_harness.lua` | OAuth token lifecycle and refresh safety |
| `lua spec/app_harness.lua` | offline tracking and sync lifecycle |

`spec/verify_live.sh` is separate because it needs a real API token. It runs the new queries against Hardcover
and reports which fields are actually present — useful for catching schema changes that documentation has not
caught up with yet.
