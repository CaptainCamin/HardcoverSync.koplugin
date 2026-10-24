# Hardcover API: journals, reviews and activity

What the plugin can rely on for writing journal entries and reviews and for reading a feed of recent activity. Everything here was checked against the live API by `spec/live/hardcover_live.lua` (run on 2026-10-21 from the `live` workflow, on the throwaway test account), not taken from documentation, which was not reachable. Names and shapes can change; the live check is how to find out.

OAuth journal reads require `read:journal` explicitly; `read:library` does not imply it. This was confirmed by Hardcover's `403` response on the Kindle on 2026-10-22. The registered app accepts the sign-in scope set with `read:journal` added (device authorization returned HTTP 200). Existing users must update the plugin, then sign out and back in to grant it. Journal writes still use `write:library`; social reads also need `read:social` and names need `read:users`. A successful check with the repository test token alone does not verify the OAuth grants requested by the plugin.

## Journal entries (notes and quotes)

Table `reading_journals`. Fields read back: `id` (bigint), `event`, `entry`, `privacy_setting_id`, `book_id`, `edition_id`, `metadata` (jsonb), `action_at`, `created_at`, `journal_date`, `custom`, `likes_count`, plus `book` and `user` objects.

**Create** (`insert_reading_journal(object: ReadingJournalCreateType!)`, already used by `HardcoverApi:createJournalEntry`): `book_id` (Int, required), `event` (String, required: `"note"` or `"quote"`), `privacy_setting_id` (Int, required: 1 public, 2 followers, 3 private), `tags` (list of `BasicTag`, required, may be empty), `entry`, `edition_id`, `action_at` (date), `metadata`, `custom`. A `BasicTag` is `{ category = "Tag", tag, spoiler }`, all three required. The page goes in `metadata = { position = { type = "pages", value = 12, possible = 400 } }`. Verified: a note and a quote with page and tags were created and read back unchanged. The answer carries `reading_journal { id }`.

**Update** `update_reading_journal(id: Int!, object: ReadingJournalUpdateType!)`: all fields optional (`entry`, `event`, `edition_id`, `privacy_setting_id`, `tags`, `metadata`, `action_at`, `custom`). Verified.

**Delete** `delete_reading_journal(id: Int!)`; also `delete_reading_journals_for_book(book_id: Int!)`. Verified.

**Read** `reading_journals(where: ..., order_by: ..., limit: ...)`. Filters by `book_id`, `user_id`, `event`, `privacy_setting_id`, `id` all work, with `_eq` and `_in`. `me { reading_journals }` does not exist; filter by `user_id` instead. Verified for your own entries and for the entries of readers you follow (public ones come back).

Hardcover also writes its own journal entries, with other `event` values, whenever you do something with a book. They are what the Journal tab lists; see "The journal page" below.

Ids in the API are `Int` in mutation arguments and `bigint` in the table. Variables declared `Int!` work for mutation arguments; for a `where: { id: ... }` on `reading_journals` put the number in the query text.

**Reading right after writing can miss the new row.** It happened once in five runs (the live check now looks again for up to eight seconds). A screen that adds an entry should show it from the queue or the response, and not rely on a re-read at once.

## The journal page (the Journal tab)

Hardcover's web Journals page is your `reading_journals`, every `event`, newest first. Checked on 2026-10-22 (live run 39818328460) for the test account and two followed readers, 100 rows each:

| `event` | what happened | `entry` | `metadata` |
|---|---|---|---|
| `note`, `quote` | you wrote it | the text | `{}`; a quote's `position` `{ type: "pages", value, possible }` |
| `reviewed` | you reviewed the book | null | `user_book_id`, and sometimes `review`, `review_raw`, `review_slate` (the text when written) |
| `rated` | you rated it | null | `rating` as a string (`"4.0"`), or `{}` |
| `progress_updated` | progress moved | null | `progress`, `progress_was` (percent), `progress_pages`, `progress_pages_was`, `pages_delta`, `percent_delta`, `seconds_delta`, `completion_pages_delta`, `completion_seconds_delta`, `source`, `user_book_read_id` |
| `user_book_read_started` | started a read | null | `started_at`, `user_book_read_id` |
| `user_book_read_finished` | finished a read | null | `started_at`, `finished_at`, `user_book_read_id` |
| `status_want_to_read`, `status_read`, `status_stopped` | status changed (stopped is did not finish) | null | `{}` |
| `list_book` | added to a list | null | `list_id`, `list_name`, `slug`, `username` (the list's owner) |
| `prompt_book` | added to a prompt | null | `prompt`, `prompt_id`, `slug` |
| `referral_to` | referred another reader (not about a book you read) | null | `referred_user_id`, `referred_username` |

- `book { id title cached_image contributions: cached_contributors }` gives each row its cover (`cached_image.url`) and authors (`cached_contributors` is a list of `{ author { name }, contribution, primary }`).
- `action_at` (timestamptz, with a zone) is when it happened; a start or a finish is stamped at the reader's local midnight. `created_at` is when the row was written.
- `order_by: [{ action_at: desc }, { id: desc }]` with `offset` and `limit` pages it. `event: { _in: [...] }` and `_nin` filter it.
- **No total.** `reading_journals_aggregate` is refused to API tokens (HTTP 403, "Not available to API tokens"), so a page that comes back full is taken to have more.
- A `reviewed` entry stays after the review is cleared and after the book leaves the library. The tab shows your review as it is now, from `book { reviews: user_books(where: { user_id: { _eq: me }, has_review: { _eq: true } }, limit: 1) { id review_raw review_has_spoilers } }`, and says only "Reviewed" when there is none.

## Reviews

A review is part of your library record (`user_books`), not a journal entry. Fields on `UserBookUpdateInput` (`update_user_book(id: Int!, object: ...)`): `review_markdown` (String), `review_slate` (jsonb), `review_has_spoilers` (Boolean), `reviewed_at` (date), `rating`, `privacy_setting_id`, `private_notes`, `sponsored_review`, among others. There is no `review_raw` input; `review_raw` is only readable.

Verified on the test account:
- `review_markdown = "text"` sets the review. A later `review_markdown` with other text replaces it. Read back as `review_raw`, with `has_review = true`.
- `review_slate` with a Slate document (`document.children[]` of `{ object = "block", type = "paragraph", children = { { object = "text", text = "...", marks = {} } } }`) also sets and replaces it, and `review_raw` follows the text.
- **Clearing:** an empty or blank `review_markdown` does nothing, and `review_slate = null` does nothing. A `review_slate` with one empty paragraph (text `""`), or a document with no children, clears it (`review_raw = ""`, `has_review = false`).
- `review_has_spoilers` is set per call and went back to false when a call left it out, so send it every time.
- `reviewed_at` is stamped on the first review and was not moved by later edits.

Reading the reviews of readers you follow works: `user_books(where: { user_id: { _in: $ids }, has_review: { _eq: true } }, order_by: { reviewed_at: desc_nulls_last })` with `rating`, `review_raw`, `review_has_spoilers`, `reviewed_at`, `user { username name }`, `book { title slug }`.

## Activity (status updates)

Table `activities`, queried as `activities(where: ..., order_by: { id: desc }, limit: N)` with `id`, `event`, `object_type`, `user_id`, `book_id`, `created_at`, `privacy_setting_id`, `data` (jsonb) and `user` / `book` objects. Filters on `user_id`, `event`, `book_id`, `created_at`, `id` work. `activity_feed` does not exist (HTTP 403 `unsupported_operation`).

The events seen, for you and for followed readers: `UserBookActivity` (a book changed status, got progress or a rating; `data.userBook` has `id`, `statusId`, `rating`, `progress` (a percentage), `reviewHasSpoilers` and an `edition` with title, contributors, cover image, pages, format), `ListActivity` (`data.list`) and `GoalActivity` (`data.goal`). **Notes, quotes and reviews are not activities.** A feed that shows them has to merge three sources: `activities`, public `reading_journals` (`event` in `quote`, `note`) and `user_books` with a review, each filtered to the readers followed.

Who you follow: `me { followed_users { followed_user_id } }` returns the ids (then `user_id: { _in: $ids }`). Roots such as `following_user_books` and `followed_user_books` also exist and were not explored.

## Not yet verified

- Likes and comments on entries.
- Event names for Currently Reading and Paused were not seen; the tab guesses `status_currently_reading` and `status_paused`, and says "Changed the status" for any other `status_` event.
- What the followed users' activity looks like at scale: the test account follows two readers.

## Progress entries and `action_at` (checked 2026-10-24)

Sending a page with `update_user_book_read` makes Hardcover write a `progress_updated` journal row for the user, within a few seconds, with `pages_delta`, `percent_delta`, `progress_was`, `progress_pages_was` and `seconds_delta` (0 unless a time is sent) worked out by the server. The row's `action_at` is the time the page arrived, unless the mutation's `object` carries `action_at` (`timestamptz`, ISO 8601 UTC): then the row has that exact time (a time five days back came back unchanged, to the second) and `journal_date` follows. The plugin sends it from the sync queue (`SyncQueue:_pageSteps`). Hand-written `progress_updated` rows through `insert_reading_journal` are accepted but keep only `progress_pages` and `progress_pages_was`, so they are not used.

**Back-dated entries are not reliable.** The page itself is always saved, but Hardcover does not always write a progress row for it. A second live check (run 40133810783, `progress-live.yml`, dispatch it to repeat) sent bursts through `updatePage` with `action_at`: six writes one day apart, oldest first, made 3 rows (the first three); a plain write followed by writes 3 and 5 days back made 1 row (the plain one); six writes 30 minutes apart made none. Each row that did appear carried the exact `action_at` and the right `progress_pages_was`. The pattern is not explained (it is not simply age, order or timing), so a trail of many back-dated pages can lose entries. Plain (undated) writes made a row every time they were tried (three of three).

A third check (run 40134464480; the API also timed out twice in it) points at merging: six fast undated writes made one row covering pages 25 to 50 (stamped with the first write's time); undated writes 15 s apart for three minutes made none (folded into that row); dated writes 30 minutes apart made none; dated writes a day apart, 15 s apart, made 3 of 6; sent fast, 0 of 6. Working theory: Hardcover folds successive updates of one read into its latest progress row within a window of a few minutes, so a dated write may be folded into an older row and its `action_at` not used. The window and the rule that lets some dated writes start a new row are not known.
