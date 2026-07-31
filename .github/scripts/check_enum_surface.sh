#!/bin/sh
# Public matchable-enum surface lock. A `pub(all) enum` — or `pub(all)
# suberror` — is exhaustively matchable by a downstream caller, so ADDING a
# variant is a source-breaking change: an existing `match` without a wildcard
# arm stops compiling, even though the change reads as a pure addition.
#
# `moon info` already forces the generated `.mbti` to be committed when a
# variant set changes; this guard is the deliberate speed-bump on top. It pins
# the exact variant set of every public matchable enum into a committed
# snapshot, so a change to that set cannot land without regenerating the
# snapshot — and, with it, consciously acknowledging the compatibility impact
# (see docs/api.md, "API stability & compatibility": such a change rides the
# minor version).
#
# Scope. Every tracked `pkg.generated.mbti` outside `internal/` — the public
# packages, and the `examples/` programs alongside them, which publish an
# interface like any other package. Internal packages carry no compatibility
# promise, so their enums are not locked. Only `pub(all)` enums/suberrors are
# matchable from outside; a
# plain `pub enum` exposes no variants and is skipped.
#
# Adding, removing, or renaming a variant — or adding a whole public enum —
# trips this until the snapshot is regenerated deliberately:
#
#   sh .github/scripts/check_enum_surface.sh --write
#
# Usage: .github/scripts/check_enum_surface.sh [repo-root] [--write]
# Exit 0 when the surface matches the snapshot, 1 on drift (or a missing one).

set -eu

root="."
write=0
for arg in "$@"; do
  case "$arg" in
    --write) write=1 ;;
    *) root="$arg" ;;
  esac
done
cd "$root"

snapshot=".github/scripts/enum_surface.snapshot"

# Tracked public interfaces only: `git ls-files` never lists a `_build` copy,
# and `internal/` (at any depth) is dropped as non-public.
files=$(git ls-files '*pkg.generated.mbti' |
  grep -v '^internal/' | grep -v '/internal/' || true)

extract() {
  # "<Enum> | <kind> | <variant>" for every variant of every public pub(all)
  # enum / suberror, sorted for a stable, declaration-order-independent set.
  printf '%s\n' "$files" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk '
      /^pub\(all\) (enum|suberror) / { kind=$2; name=$3; inblock=1; next }
      inblock && /^}/ { inblock=0; next }
      inblock {
        v=$0; gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v)
        if (v != "") print name " | " kind " | " v
      }
    ' "$f"
  done | LC_ALL=C sort -u
}

current=$(extract)

count() { printf '%s\n' "$1" | grep -c '|' || true; }

if [ "$write" -eq 1 ]; then
  printf '%s\n' "$current" >"$snapshot"
  printf 'enum surface: wrote %s (%s variants)\n' "$snapshot" "$(count "$current")"
  exit 0
fi

if [ ! -f "$snapshot" ]; then
  printf 'enum surface: snapshot %s missing — run with --write to create it\n' \
    "$snapshot"
  exit 1
fi

if ! diff_out=$(printf '%s\n' "$current" | diff -u "$snapshot" - 2>&1); then
  printf 'enum surface: the public matchable-enum surface changed.\n'
  printf '  A pub(all) enum / suberror variant was added, removed, or renamed.\n'
  printf '  Adding a variant is source-breaking under exhaustive match, so the\n'
  printf '  change rides the minor version (docs/api.md). If it is intended,\n'
  printf '  regenerate: sh .github/scripts/check_enum_surface.sh --write\n'
  printf '%s\n' "$diff_out" | sed 's/^/    /'
  exit 1
fi

printf 'enum surface: %s variants match the snapshot\n' "$(count "$current")"
