#!/bin/sh
# Advisory: flag absolute wording in added prose so a reviewer checks it.
#
# "all", "every", "never", "total", "only" are the words this repository's
# documentation drifts on, because each is a claim that one new exception
# silently falsifies — and the exception is usually added by someone who never
# reads the sentence. Recent examples: "all are total" (the regex string ops
# raise), "every library package carries a bench_test.mbt" (four do), "the one
# deliberate difference" (three), "reverse and with_row_index are both total"
# (one is).
#
# This **never fails the build**. Absolute wording is often correct and is
# stronger than a hedge when it is; the point is that a human confirms it. Hits
# are printed, and on GitHub Actions emitted as `::warning` annotations so they
# land on the diff.
#
# Scope: lines *added* by the branch (`git diff BASE...HEAD`) in a comment or a
# Markdown file — not the whole repository, which would print thousands of
# lines and be ignored.
#
# Usage: .github/scripts/review_absolute_wording.sh [base-ref]
#        base-ref defaults to origin/main, then main.
# Always exits 0.

set -eu

base="${1:-}"
if [ -z "$base" ]; then
  if git rev-parse --verify --quiet origin/main >/dev/null; then
    base=origin/main
  else
    base=main
  fi
fi

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
  printf 'absolute wording: no base ref "%s" to diff against, skipping\n' "$base"
  exit 0
fi

# Prefer the three-dot form (what the branch added since it diverged). A CI
# checkout is shallow, so the merge base may not be present — fall back to a
# plain two-tree diff against whatever base commit was fetched.
if git merge-base --is-ancestor "$base" HEAD 2>/dev/null ||
  git merge-base "$base" HEAD >/dev/null 2>&1; then
  range="$base...HEAD"
else
  range="$base HEAD"
fi

# Added lines only, with the file and line number they landed on. `git diff
# -U0` keeps the hunk headers that carry the new line numbers.
# shellcheck disable=SC2086 # $range is deliberately two words in the fallback
added=$(git diff -U0 $range -- '*.md' '*.mbt' 2>/dev/null |
  awk '
    /^\+\+\+ b\// { file = substr($0, 7); next }
    /^@@/ {
      # @@ -old,n +new,n @@ → the first line number of the added side.
      split($3, a, ",")
      line = a[1] + 0
      next
    }
    /^\+/ && file != "" {
      text = substr($0, 2)
      # Comments and Markdown prose only: code is where "all" is a variable.
      if (file ~ /\.md$/ || text ~ /^[[:space:]]*(\/\/|\/\/\/)/) {
        if (text ~ /(^|[^A-Za-z])([Aa]ll|[Ee]very|[Nn]ever|[Aa]lways|[Oo]nly|total|full surface)([^A-Za-z]|$)/) {
          printf "%s:%d:%s\n", file, line, text
        }
      }
      line++
    }
  ')

if [ -z "$added" ]; then
  printf 'absolute wording: nothing to review in the added prose\n'
  exit 0
fi

count=$(printf '%s\n' "$added" | wc -l | tr -d ' ')
printf 'absolute wording: %s added line(s) claim something absolute — confirm each still holds:\n' "$count"
printf '%s\n' "$added" | sed 's/^/  /'

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  printf '%s\n' "$added" | while IFS=: read -r file line text; do
    printf '::warning file=%s,line=%s::absolute wording — confirm it holds: %s\n' \
      "$file" "$line" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
  done
fi
exit 0
