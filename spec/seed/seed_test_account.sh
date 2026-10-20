#!/usr/bin/env bash
# One-off seed for the throwaway Hardcover test account: about a dozen books across the shelves,
# one list and a reading goal. Idempotent: a re-run adds only what is missing. The token comes
# from HARDCOVER_DEV_KEY and is never printed. Run by .github/workflows/seed-test-account.yml.
set -euo pipefail

API=https://api.hardcover.app/v1/graphql
YEAR=$(date -u +%Y)

TOKEN=$(printf '%s' "${HARDCOVER_DEV_KEY:-}" | sed 's/^[[:space:]]*[Bb]earer[[:space:]]*//' | tr -d '[:space:]"')
if [ -z "$TOKEN" ]; then
  echo "HARDCOVER_DEV_KEY is not set" >&2
  exit 2
fi

# gql QUERY VARIABLES_JSON: prints the "data" object, or fails with the first GraphQL error
gql() {
  local payload out code body
  payload=$(jq -cn --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')
  out=$(printf '%s' "$payload" | curl -sS --max-time 30 -w '\n%{http_code}' \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    --data-binary @- "$API")
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  if [[ $code != 2* ]]; then
    echo "HTTP $code from the API" >&2
    return 1
  fi
  if jq -e '.errors' <<<"$body" >/dev/null; then
    echo "GraphQL error: $(jq -c '.errors[0].message' <<<"$body")" >&2
    return 1
  fi
  jq -c '.data' <<<"$body"
}

ME=$(gql 'query { me { id account_privacy_setting_id } }' '{}')
USER_ID=$(jq -r '.me[0].id // empty' <<<"$ME")
PRIVACY=$(jq -r '.me[0].account_privacy_setting_id // 1' <<<"$ME")
if [ -z "$USER_ID" ]; then
  echo "the token has no user (is it valid?)" >&2
  exit 1
fi

# title|author|status_id (1 want, 2 reading, 3 read, 5 did not finish)|rating|started|finished|pages
BOOKS=(
  'Pride and Prejudice|Jane Austen|3|4|2025-11-01|2025-11-20|'
  'The Left Hand of Darkness|Ursula K. Le Guin|3|4|2026-05-28|2026-06-14|'
  'Project Hail Mary|Andy Weir|3|5|2026-07-30|2026-08-08|'
  'The Hobbit|J.R.R. Tolkien|3|4|2026-01-03|2026-01-12|'
  'The Name of the Wind|Patrick Rothfuss|2||2026-10-02||120'
  'Piranesi|Susanna Clarke|2||2026-10-14||40'
  'Mistborn: The Final Empire|Brandon Sanderson|2||2026-09-20||75'
  'Neuromancer|William Gibson|1||||'
  'The Fifth Season|N. K. Jemisin|1||||'
  'Circe|Madeline Miller|1||||'
  'Anathem|Neal Stephenson|1||||'
  'Moby-Dick|Herman Melville|5||2026-03-01||180'
)
LIST_NAME="Seed: favourite classics"
LIST_TITLES=('Pride and Prejudice' 'The Left Hand of Darkness' 'Project Hail Mary')

declare -A BOOK_IDS=()

for entry in "${BOOKS[@]}"; do
  IFS='|' read -r title author status rating started finished pages <<<"$entry"

  found=$(gql 'query ($q: String!) { search(query: $q, per_page: 1, page: 1, query_type: "Book") { ids } }' \
    "$(jq -cn --arg q "$title $author" '{q: $q}')")
  book_id=$(jq -r '.search.ids[0] // empty' <<<"$found")
  if [ -z "$book_id" ]; then
    echo "no Hardcover book found for $title" >&2
    exit 1
  fi
  BOOK_IDS[$title]=$book_id

  mine=$(gql 'query ($b: Int!, $u: Int!) { user_books(where: { book_id: { _eq: $b }, user_id: { _eq: $u } }) { id status_id rating user_book_reads { id } } }' \
    "$(jq -cn --argjson b "$book_id" --argjson u "$USER_ID" '{b: $b, u: $u}')")
  ub_id=$(jq -r '.user_books[0].id // empty' <<<"$mine")
  reads=0
  rating_now=
  if [ -z "$ub_id" ]; then
    added=$(gql 'mutation ($object: UserBookCreateInput!) { insert_user_book(object: $object) { error user_book { id } } }' \
      "$(jq -cn --argjson b "$book_id" --argjson s "$status" --argjson p "$PRIVACY" '{object: {book_id: $b, status_id: $s, privacy_setting_id: $p}}')")
    if [ -n "$(jq -r '.insert_user_book.error // empty' <<<"$added")" ]; then
      echo "could not add $title: $(jq -c '.insert_user_book.error' <<<"$added")" >&2
      exit 1
    fi
    ub_id=$(jq -r '.insert_user_book.user_book.id' <<<"$added")
    echo "added $title"
  else
    reads=$(jq '.user_books[0].user_book_reads | length' <<<"$mine")
    rating_now=$(jq -r '.user_books[0].rating // empty' <<<"$mine")
    echo "$title already on the account"
  fi

  if [ "$status" != 1 ] && [ "$reads" -eq 0 ]; then
    gql 'mutation ($id: Int!, $started: date, $finished: date, $pages: Int) { insert_user_book_read(user_book_id: $id, user_book_read: { started_at: $started, finished_at: $finished, progress_pages: $pages }) { error } }' \
      "$(jq -cn --argjson id "$ub_id" --arg s "$started" --arg f "$finished" --argjson p "${pages:-null}" \
        '{id: $id, started: $s, finished: (if $f == "" then null else $f end), pages: $p}')" >/dev/null
  fi

  if [ -n "$rating" ] && [ -z "$rating_now" ]; then
    gql 'mutation ($id: Int!, $rating: numeric) { update_user_book(id: $id, object: { rating: $rating }) { user_book { id } } }' \
      "$(jq -cn --argjson id "$ub_id" --argjson r "$rating" '{id: $id, rating: $r}')" >/dev/null
  fi
done

LISTS=$(gql 'query { me { lists { id name list_books { book_id } } } }' '{}')
LIST_ID=$(jq -r --arg n "$LIST_NAME" '.me[0].lists[] | select(.name == $n) | .id' <<<"$LISTS" | head -1)
if [ -z "$LIST_ID" ]; then
  created=$(gql 'mutation ($object: ListInput!) { insert_list(object: $object) { id errors } }' \
    "$(jq -cn --arg n "$LIST_NAME" --argjson p "$PRIVACY" '{object: {name: $n, privacy_setting_id: $p}}')")
  LIST_ID=$(jq -r '.insert_list.id // empty' <<<"$created")
  echo "created the list $LIST_NAME"
fi
have=$(jq -r --arg id "$LIST_ID" '.me[0].lists[] | select((.id | tostring) == $id) | [.list_books[].book_id | tostring] | join(" ")' <<<"$LISTS")
for title in "${LIST_TITLES[@]}"; do
  bid=${BOOK_IDS[$title]}
  case " $have " in *" $bid "*) continue ;; esac
  gql 'mutation ($object: ListBookInput!) { insert_list_book(object: $object) { id } }' \
    "$(jq -cn --argjson b "$bid" --argjson l "$LIST_ID" '{object: {book_id: $b, list_id: $l}}')" >/dev/null
done

GOAL="Seed: $YEAR reading goal"
GOALS=$(gql 'query { me { goals { id description } } }' '{}')
if jq -e --arg d "$GOAL" '.me[0].goals[] | select(.description == $d)' <<<"$GOALS" >/dev/null; then
  echo "goal already there"
else
  gql 'mutation ($object: GoalInput!) { insert_goal(object: $object) { id errors } }' \
    "$(jq -cn --arg d "$GOAL" --arg y "$YEAR" --argjson p "$PRIVACY" '{object: {description: $d, metric: "book", goal: 12, start_date: ($y + "-01-01"), end_date: ($y + "-12-31"), privacy_setting_id: $p, conditions: {}}}')" >/dev/null
  echo "added the $YEAR goal"
fi

echo "seed done"
