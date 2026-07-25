#!/bin/sh
# Root facade surface lock. The root package `ihb2032/MoonFrame` is the one
# supported stable compatibility surface, so every symbol it re-exports is a
# promise. `moon info` keeps the generated `pkg.generated.mbti` in sync with the
# code, and the downstream fixture proves a caller can still name what it needs
# — but neither flags an *over-export*: a `type` or `fn` accidentally added to
# the facade compiles green, and once published, retracting it is a breaking
# change.
#
# This guard pins the facade's exact export set — the re-exported free functions
# and the re-exported types with their source package — into a committed
# snapshot, so any addition, removal, or source-package change fails until the
# snapshot is regenerated deliberately:
#
#   sh .github/scripts/check_facade_surface.sh --write
#
# It complements the enum-surface lock (variant sets), the downstream fixture
# (necessary calls still compile), and the `moon info` drift check (interface
# matches source): together they pin that the facade surface cannot silently
# grow, shrink, or move.
#
# Usage: .github/scripts/check_facade_surface.sh [repo-root] [--write]
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

snapshot=".github/scripts/facade_surface.snapshot"
mbti="pkg.generated.mbti"

extract() {
  # "fn <name>" for each re-exported free function, and
  # "type <Name> <- <pkg>" for each re-exported type (source package included so
  # a type moving between packages is caught). Sorted for a stable set.
  {
    sed -n 's/^pub fn \([A-Za-z_][A-Za-z0-9_]*\)(.*/fn \1/p' "$mbti"
    sed -n \
      's/^pub using @\([a-z_]*\) {type \([A-Za-z0-9_]*\)}.*/type \2 <- \1/p' \
      "$mbti"
  } | LC_ALL=C sort -u
}

current=$(extract)
count() { printf '%s\n' "$1" | grep -cE '^(fn|type) ' || true; }

if [ "$write" -eq 1 ]; then
  printf '%s\n' "$current" >"$snapshot"
  printf 'facade surface: wrote %s (%s symbols)\n' "$snapshot" "$(count "$current")"
  exit 0
fi

if [ ! -f "$snapshot" ]; then
  printf 'facade surface: snapshot %s missing — run with --write to create it\n' \
    "$snapshot"
  exit 1
fi

if ! diff_out=$(printf '%s\n' "$current" | diff -u "$snapshot" - 2>&1); then
  printf 'facade surface: the root facade export set changed.\n'
  printf '  A type or free function was added to, removed from, or moved on the\n'
  printf '  facade. The facade is the supported stable surface, so an accidental\n'
  printf '  over-export becomes a breaking change once published. If the change\n'
  printf '  is intended, regenerate:\n'
  printf '    sh .github/scripts/check_facade_surface.sh --write\n'
  printf '%s\n' "$diff_out" | sed 's/^/    /'
  exit 1
fi

printf 'facade surface: %s symbols match the snapshot\n' "$(count "$current")"
