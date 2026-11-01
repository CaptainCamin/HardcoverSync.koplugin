# Plan: one queue for a book's library state

Status: done. Steps 1 to 3 are in PR #275, step 4 in #276 and step 5 in the PR that follows them. This is kept for the reasoning. Steps 1 to 3 of the original plan are done (PR #275): the status-sending rules
live once in `status_sender.lua`, every queued change carries `at` and sends it as `action_at`, and
`pending_status.lua` reads both queues as one list. This covers what is left: steps 4 and 5.

## Why

A book's status, finish date, pages, re-read and removal are one ordered stream: Hardcover decides what a
page means from the status it sees. They are kept in two queues today.

- `SyncQueue` (`pending`): keyed by **file path**. Holds `mapped_page`, `page_days`, `status_id`,
  `finished_date`, `passed_reading`, `reread`, `conflict`, `force_page`, `book_id`, `edition_id`,
  `user_book_id`, `read_id`, `started_at`, `from_status_id`, `user_id`.
- `ShelfQueue` (`shelf_ops`): keyed by **Hardcover book id**. Holds `kind` (status or remove), `status_id`,
  `user_book_id`, `edition_id`, `from_status_id`, `passed_reading`, `finished_date`, `at`, `held`.
- `ShelfQueue:settleWith` exists only to reconcile the two at flush time.
- Since #275 a book with a file keeps its offline details-screen status in `SyncQueue`; the shelf queue is
  left for books with no file and for removals.

What is left to gain: delete `settleWith` and the shelf queue's flush, and let `PendingStatus` read one place.

## Target

One book-state queue, keyed by Hardcover book id (`book_id`), one record per book:

| field | from |
|---|---|
| `status_id`, `status_at`, `finished_date`, `passed_reading`, `from_status_id` | both queues |
| `remove` (with `user_book_id`) | shelf queue; replaces the status when set, as `queueRemove` does |
| `mapped_page`, `page_at`, `page_days`, `force_page`, `reread`, `conflict` | SyncQueue |
| `edition_id`, `user_book_id`, `read_id`, `started_at`, `privacy_setting_id`, `title`, `user_id` | both |
| `file` (optional) | the key SyncQueue uses today |

Goals, lists, journal, reviews and ratings stay separate queues on `OfflineQueue`. They do not interact
with a book's reading order.

## Where the file key is used

Callers that pass a file path into `SyncQueue` (grep `sync_queue:` outside `sync_queue.lua`):

- `cache.lua`: `get` (3), `enqueuePage` (2), `enqueueStatus`, plus `queueMeta`
- `main.lua`: `takeResumePage`, `get`, `filepaths`, and the flush call with `current_file`
- `ui/hardcover_menu.lua`: `get` (4), `startReread`
- `ui/book_flows.lua`: `enqueueStatus` (from #275), `statusFor`
- `pending_changes.lua`, `pending_status.lua`, `sync_conflicts.lua`, `ui/sync_conflict_dialog.lua`,
  `ui/pending_changes_dialog.lua`: `filepaths`, `get`, `cancelPage`, `cancelStatus`, `resolve`

The reader always has a file and a book id once the book is linked. A change for a book with no `book_id`
cannot be keyed by one and is dropped (decided).

## Steps

### 4. Re-key the progress queue by book id

1. Add `SyncQueue:key(filepath_or_book_id)` and make every public method take the book id. Keep the file
   as `entry.file`. Callers that only have a file resolve the id with one helper
   (`Cache:queueMeta(filename).book_id`).
2. Migrate on load: for each saved `pending` entry with a `book_id`, move it to the new key (when two files
   share a book, keep the one with the newest `page_updated_at`, and say so in the log). An entry with no
   `book_id` is dropped in the migration: it cannot be sent today either (`_flushEntry` counts a rejection
   for it until it is held), and nothing found in the code queues a page for an unlinked book.
3. New specs: the migration (one file, two files for one book, an entry with no book id, an entry from
   another user), and two files linked to one book queueing pages.
4. Run `spec/emu` offline scenarios (`offline_book_changes`, `reader_panel`).

Ship alone. Nothing else changes behaviour.

### 5. Move shelf-queue ops in

1. `book_flows.lua` `saveShelfOffline` and `removeFromShelf` call the book-state queue for every book, with
   or without a file; delete the `deviceFile` branch added in #275.
2. `SyncQueue:enqueueStatus` accepts a book that is not on the device (no `file`); `queueRemove` becomes a
   record state (`remove = true`), dropped when the book was only ever put on a shelf offline.
3. Flush: one pass per book, in the order the stamps give (`orderedOps`); a remove goes after everything
   before it and clears the rest of the record.
4. Read the old `shelf_ops` key once at start-up, convert it, and clear it. Keep reading it for one
   release, so a downgrade or a half-synced device does not lose entries.
5. Delete `ShelfQueue`, `settleWith`, the `_flushShelves` call in `main.lua`, and fold
   `shelf_queue_harness` / `offline_shelf_harness` cases into the sync queue specs. `PendingStatus`
   becomes a thin reader of the one queue (or goes away).

## Decisions needed

- ~~**Unlinked books.**~~ Decided: drop entries with no `book_id` in the migration; no new refusal code.
- **Two files, one book:** newest wins by timestamp, page and status each (recommended), or ask the user?
- **Keep the old `shelf_ops` key for one release or two?** One is recommended: step 5 converts and clears it.

## Risks

- `sync_queue.lua` is 831 lines and holds the conflict and re-read rules. Step 4 touches every public
  method; the 29 `sync_regressions` are the safety net and should pass unchanged.
- Saved data: both migrations are one-way. A downgrade after step 5 loses nothing only if the old key is
  still read and written back (hence the extra release).
- Held entries (`failures`, `conflict`) must survive the move with their counts.
