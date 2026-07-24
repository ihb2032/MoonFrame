#!/bin/sh
# Facade documentation coverage: every symbol the root package re-exports must
# be listed in the reference's facade section, and nothing may be listed there
# that the root package no longer re-exports.
#
# The two sides:
#   pkg.generated.mbti   `pub using @pkg {type T}` and `pub fn name(...)`
#   docs/api.md          the "- From `@pkg`: `A` · `B` · …" bullets
#
# api.md opens by promising that every user-visible symbol appears in the
# reference, and the facade list is the only place the re-exports are
# enumerated by hand — so it is the one that silently falls behind when a type
# is added. Types are compared *with* their source package, so moving a type
# between packages (as v0.6 moved `SortOrder` into `types`) shows up too. Free
# functions are compared by name only: the interface does not record which
# package a facade wrapper forwards to, so the grouping in the document is
# checked by eye, not here.
#
# Usage: .github/scripts/check_facade_docs.sh [repo-root]
# Exit 0 when they agree, 1 otherwise.

set -eu

root="${1:-.}"
cd "$root"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

# ── the interface side ────────────────────────────────────────────────────
sed -n 's/^pub using @\([a-z_]*\) *{ *type \([A-Za-z_][A-Za-z_0-9]*\) *}.*/\1 \2/p' \
  pkg.generated.mbti | sort >"$work/mbti_types"
sed -n 's/^pub fn \([a-z_][A-Za-z_0-9]*\)(.*/\1/p' \
  pkg.generated.mbti | sort -u >"$work/mbti_fns"

# ── the document side ─────────────────────────────────────────────────────
# The facade block runs from the first "- From `@pkg`:" bullet to the blank
# line that ends the list. Each backticked token on a bullet (or on its
# continuation lines) belongs to the package named by the most recent bullet.
awk '
  /^- From `@[a-z_]+`:/ { started = 1 }
  started && /^[[:space:]]*$/ { exit }
  started {
    line = $0
    if (match(line, /^- From `@[a-z_]+`:/)) {
      pkg = substr(line, RSTART + 9, RLENGTH - 11)
      line = substr(line, RSTART + RLENGTH)
    }
    while (match(line, /`[A-Za-z_][A-Za-z_0-9]*`/)) {
      print pkg, substr(line, RSTART + 1, RLENGTH - 2)
      line = substr(line, RSTART + RLENGTH)
    }
  }
' docs/api.md | sort >"$work/doc_pairs"
awk '{ print $2 }' "$work/doc_pairs" | sort -u >"$work/doc_symbols"

if [ ! -s "$work/doc_pairs" ]; then
  printf 'facade docs: could not find the "- From `@pkg`:" list in docs/api.md\n'
  exit 1
fi

fail=0
report() {
  # $1 = the lines, $2 = the message; prints nothing when there are none.
  [ -n "$1" ] || return 0
  printf '  %s\n' "$2"
  printf '%s\n' "$1" | sed 's/^/    /'
  fail=1
}

report "$(comm -23 "$work/mbti_types" "$work/doc_pairs")" \
  're-exported but not in the facade list (pkg type):'
report "$(comm -13 "$work/mbti_types" "$work/doc_pairs" |
  while read -r pkg sym; do
    grep -qx "$sym" "$work/mbti_fns" || printf '%s %s\n' "$pkg" "$sym"
  done)" \
  'in the facade list but not re-exported under that package (pkg symbol):'
report "$(comm -23 "$work/mbti_fns" "$work/doc_symbols")" \
  're-exported as a free function but not in the facade list:'

if [ "$fail" -ne 0 ]; then
  printf 'facade docs: out of sync with pkg.generated.mbti\n'
  exit 1
fi
printf 'facade docs: %s types + %s free functions, all listed\n' \
  "$(wc -l <"$work/mbti_types" | tr -d ' ')" \
  "$(wc -l <"$work/mbti_fns" | tr -d ' ')"
