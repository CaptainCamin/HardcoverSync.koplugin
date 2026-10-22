# Hardcover API: journals, reviews and activity

What the plugin can rely on for writing journal entries and reviews and for reading a feed of recent activity. Everything here was checked against the live API by `spec/live/hardcover_live.lua` (run on 2026-10-21 from the `live` workflow, on the throwaway test account), not taken from documentation, which was not reachable. Names and shapes can change; the live check is how to find out.

OAuth journal reads require `read:journal` explicitly; `read:library` does not imply it. This was confirmed by Hardcover's `403` response on the Kindle on 2026-10-22. The registered app accepts the sign-in scope set with `read:journal` added (device authorization returned HTTP 200). Existing users must update the plugin, then sign out and back in to grant it. Journal writes still use `write:library`; social reads also need `read:social` and names need `read:users`. A successful check with the repository test token alone does not verify the OAuth grants requested by the plugin.

## Journal entries (notes and quotes)

Table `reading_journals`. Fields read back: `id` (bigint), `event`, `entry`, `privacy_setting_id`, `book_id`, `edition_id`, `metadata` (jsonb), `action_at`, `created_at`, `journal_date`, `custom`, `likes_count`, plus `book` and `user` objects.

**Create** (`insert_reading_journal(object: ReadingJournalCreateType!)`, already used by `HardcoverApi:createJournalEntry`): `book_id` (Int, required), `event` (String, required: `"note"` or `"quote"`), `privacy_setting_id` (Int, required: 1 public, 2 followers, 3 private), `tags` (list of `BasicTag`, required, may be empty), `entry`, `edition_id`, `action_at` (date), `metadata`, `custom`. A `BasicTag` is `{ category = "Tag", tag, spoiler }`, all three required. The page goes in `metadata = { position = { type = "pages", value = 12, possible = 400 } }`. Verified: a note and a quote with page and tags were created and read back unchanged. The answer carries `reading_journal { id }`.

**Update** `update_reading_journal(id: Int!, object: ReadingJournalUpdateType!)`: all fields optional (`entry`, `event`, `edition_id`, `privacy_setting_id`, `tags`, `metadata`, `action_at`, `custom`). Verified.

**Delete** `delete_reading_journal(id: Int!)`; also `delete_reading_journals_for_book(book_id: Int!)`. Verified.

**Read** `reading_journals(where: ..., order_by: ..., limit: ...)`. Filters by `book_id`, `user_id`, `event`, `privacy_setting_id`, `id` all work, with `_eq` and `_in`. `me { reading_journals }` does not exist; filter by `user_id` instead. Verified for your own entries and for the entries of readers you follow (public ones come back).

Hardcover also writes its own journal events, with other `event` values, when you change a book's status or progress (`rated`, `user_book_read_started`, `user_book_read_finished`, with `metadata` such as `started_at`, `finished_at`, `user_book_read_id`). A journal screen has to decide whether to show them (see the plan).

Ids in the API are `Int` in mutation arguments and `bigint` in the table. Variables declared `Int!` work for mutation arguments; for a `where: { id: ... }` on `reading_journals` put the number in the query text.

**Reading right after writing can miss the new row.** It happened once in five runs (the live check now looks again for up to eight seconds). A screen that adds an entry should show it from the queue or the response, and not rely on a re-read at once.

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

- Paging the merged feed (offset or cursor across three sources) and how many requests a screen needs against the 60-a-minute limit.
- Likes and comments on entries.
- What the followed users' activity looks like at scale: the test account follows two readers.
