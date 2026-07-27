#!/bin/sh
# Least privilege inside the module. An `internal/` package cannot be imported
# downstream, so nothing in it is a compatibility promise and the seam lock
# (`check_engine_seams.sh`) skips it entirely — which left its `pub` surface
# the one part of the repository nothing governed. `pub` still means something
# there: it is the difference between a symbol `series` and `internal/kernel`
# can reach and one only its own package can. A helper that is `pub` because a
# test found it convenient hands the packages above it capability nobody chose
# to give them, and capability that exists gets used.
#
# The rule: a `pub fn` in an `internal/` package must have a production caller
# in another package. Otherwise make it package-private — visible across every
# file of its own package, which is all its own code needs — or delete it if
# nothing calls it at all.
#
# Where that collides with the test suite, the answer is the test suite: an
# internal package's tests belong *inside* it, as `_wbtest.mbt`, where they can
# assert what the package actually holds. `internal/column`'s suite moved there
# when the typed readers it was keeping alive were deleted.
#
# Exceptions live in `internal_surface.allowlist`, one `pkg/Symbol — reason`
# per line, for the case the rule cannot cover: a symbol with no production
# caller anywhere, which therefore cannot be private either, because
# `unused_value` counts production callers only and the strict warning gate
# turns that into an error. An invariant predicate is the honest example — it
# exists to be asserted and nothing else.
#
# What this cannot see, and it is worth knowing: callers are matched by how the
# symbol can be spelled, so a method whose short name is shared with a
# cross-package one — `data`, `len`, `get` — reads as called wherever that name
# is called. The guard therefore under-reports rather than over-reports: what
# it flags is genuinely unreachable from outside, and a clean run is not proof
# that everything left is needed.
#
# Usage: .github/scripts/check_internal_surface.sh [repo-root]
# Exit 0 when every internal `pub fn` is reachable or listed, 1 otherwise.

set -eu

root="${1:-.}"
cd "$root"

allowlist=".github/scripts/internal_surface.allowlist"
allowed=$([ -f "$allowlist" ] && grep -v '^[[:space:]]*#' "$allowlist" || true)

production_files=$(git ls-files '*.mbt' | grep -vE '_(test|wbtest)\.mbt$' |
  grep -v '^examples/' || true)

# `<pkg> <dep>` per production import, so only a package that can actually name
# a symbol is searched for calls to it.
edges=$(git ls-files '*moon.pkg' | grep -v '^examples/' |
  while IFS= read -r manifest; do
    pkg=$(dirname "$manifest")
    [ "$pkg" != "." ] || pkg=root
    awk -v pkg="$pkg" '
      /^import \{/ { inblock = 1; n = 0; next }
      inblock && /^\}/ {
        if ($0 !~ /for "(wb)?test"/) for (i = 1; i <= n; i++) print pkg " " dep[i]
        inblock = 0
        next
      }
      inblock {
        want = "\"ihb2032/MoonFrame/"
        if (index($0, want) > 0) {
          d = substr($0, index($0, want) + length(want))
          sub(/".*/, "", d)
          dep[++n] = d
        }
      }
    ' "$manifest"
  done | LC_ALL=C sort -u)

has_outside_caller() {
  # has_outside_caller <declaring-pkg> <symbol>
  short=${2##*::}
  case "$2" in
    *::*)
      owner=${2%::*}
      pattern="(\.[[:space:]]*${short}\(|${owner}::${short}\()"
      ;;
    # No `\(` for a free function: it can be *passed* rather than called —
    # `@kernel.sign_i64` handed to a higher-order kernel is a use, and
    # requiring the parenthesis reported two such helpers as unreachable.
    *)
      pattern="((^|[^A-Za-z0-9_.])${short}([^A-Za-z0-9_]|\$)"
      pattern="$pattern|@[A-Za-z0-9_]+\.${short}([^A-Za-z0-9_]|\$))"
      ;;
  esac
  importers=$(printf '%s\n' "$edges" | awk -v want="$1" '$2 == want { print $1 }' |
    grep -v "^$1$" || true)
  [ -n "$importers" ] || return 1
  for imp in $importers; do
    if [ "$imp" = root ]; then
      files=$(printf '%s\n' "$production_files" | grep -v '/' || true)
    else
      files=$(printf '%s\n' "$production_files" | grep "^$imp/[^/]*\$" || true)
    fi
    [ -n "$files" ] || continue
    hits=$(printf '%s\n' "$files" | tr '\n' '\0' |
      xargs -0 grep -nE "$pattern" 2>/dev/null |
      grep -vE '^([^:]*:)?[0-9]+:[[:space:]]*//' |
      grep -vE '^([^:]*:)?[0-9]+:[[:space:]]*(pub )?fn(\[[^]]*\])? ' || true)
    [ -z "$hits" ] || return 0
  done
  return 1
}

is_allowed() {
  found=$(printf '%s\n' "$allowed" | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      "$1 — "*) printf 'yes' ;;
    esac
  done)
  [ -n "$found" ]
}

unreachable=""
checked=0
for pkg in $(git ls-files 'internal/*/moon.pkg' | while IFS= read -r m; do
  dirname "$m"
done); do
  syms=$(printf '%s\n' "$production_files" | grep "^$pkg/[^/]*\$" |
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      grep -h '^pub fn ' "$f" || true
    done | sed 's/^pub fn //; s/(.*//; s/\[.*//' | LC_ALL=C sort -u)
  for sym in $syms; do
    checked=$((checked + 1))
    if ! has_outside_caller "$pkg" "$sym"; then
      is_allowed "$pkg/$sym" ||
        unreachable="$unreachable$pkg/$sym
"
    fi
  done
done

# The other direction: an entry whose symbol gained a caller, was renamed, or
# is gone is an exception nobody has re-read.
stale=$(printf '%s\n' "$allowed" | while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  key=${entry%% — *}
  pkg=$(printf '%s' "$key" | sed 's|/[^/]*$||')
  sym=${key##*/}
  if ! grep -q "^pub fn $sym(" $(printf '%s\n' "$production_files" |
    grep "^$pkg/[^/]*\$" | tr '\n' ' ') 2>/dev/null; then
    printf '%s (no such `pub fn`)\n' "$key"
  elif has_outside_caller "$pkg" "$sym"; then
    printf '%s (has a caller now)\n' "$key"
  fi
done)

if [ -n "$unreachable" ]; then
  printf 'internal surface: a `pub` nothing outside its package calls:\n'
  printf '%s' "$unreachable" | sed 's/^/  /'
  printf '  `pub` in an internal package buys reach into it from `series` and\n'
  printf '  `internal/kernel`, nothing else — so one nobody calls is capability\n'
  printf '  handed over for no reason. Make it a plain `fn` (still visible to\n'
  printf '  every file of its own package, with its tests as `_wbtest.mbt`), or\n'
  printf '  delete it if nothing calls it at all. If it cannot be private\n'
  printf '  because only tests call it, add it with its reason to\n'
  printf '  %s.\n' "$allowlist"
  exit 1
fi

if [ -n "$stale" ]; then
  printf 'internal surface: an exception that is no longer needed:\n'
  printf '%s\n' "$stale" | sed 's/^/  /'
  printf '  Drop the entry from %s.\n' "$allowlist"
  exit 1
fi

printf 'internal surface: %s internal `pub fn` are reachable or listed\n' \
  "$checked"
