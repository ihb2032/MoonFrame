#!/bin/sh
# Root facade surface lock. The root package `ihb2032/MoonFrame` is the one
# supported stable compatibility surface, so every symbol it re-exports is a
# promise. `moon info` keeps the generated `pkg.generated.mbti` in sync with the
# code, and the downstream fixture proves a caller can still name what it needs
# — but neither flags an *over-export*: a symbol accidentally added to the
# facade compiles green, and once published, retracting it is a breaking
# change.
#
# What the facade actually promises is wider than what the root `.mbti` lists.
# The root re-exports *types* (`pub using @frame {type DataFrame}`), and a
# re-exported type carries its whole callable surface along: its constructors,
# its inherent methods, the trait methods `pub extend` exposes, its impls,
# and its public fields all become reachable as `@moonframe.DataFrame::…`
# without another line of facade code. So locking the root file alone — the
# free functions and the type names — leaves method-level growth invisible:
# a new `pub fn DataFrame::debug_storage` would change no root symbol, ship,
# and only then be undeletable.
#
# This guard therefore pins the *whole* set, read from every public package's
# generated interface and tagged with its source package:
#
#   fn <name> <- <pkg>              free function (`<- root` = the facade's own)
#   type <Name> <- <pkg>            public type the facade re-exports by name
#   intermediate <Name> <- <pkg>    public type the facade deliberately does
#                                   not name: a fluent-chain step (`WhenThen`,
#                                   `GroupedDataFrame`, …) reached only by
#                                   chaining off the previous return value
#   ctor <Type>::<Type> <- <pkg>    canonical constructor
#   method <Type>::<name> <- <pkg>  inherent or extension-exposed method
#   alias <Type>::<name> <- <pkg>   second callable spelling (`#alias`)
#   impl <Trait> for <Type> <- <pkg>
#   field <Type>.<name> <- <pkg>    public struct field
#
# Any addition, removal, rename, reclassification (a re-exported type becoming
# an intermediate, or the reverse), or source-package change fails until the
# snapshot is regenerated deliberately:
#
#   sh .github/scripts/check_facade_surface.sh --write
#
# Scope. Every tracked `pkg.generated.mbti` outside `internal/` and
# `examples/`: the six public packages plus the root facade. Internal packages
# are unimportable downstream, and `#internal(engine)` seams carry
# `#doc(hidden)`, so neither reaches a generated interface — this guard sees
# exactly what a downstream caller can. `pub(all)` enum *variants* are the
# enum-surface guard's job (they are source-breaking under exhaustive `match`
# in a way a method addition is not); this one records the enum's existence and
# its methods, and leaves the variant set there.
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

# Tracked public interfaces only: `git ls-files` never lists a `_build` copy,
# `internal/` (at any depth) carries no compatibility promise, and `examples/`
# is programs rather than library surface.
files=$(git ls-files '*pkg.generated.mbti' |
  grep -v '^internal/' | grep -v '/internal/' | grep -v '^examples/' || true)

# "<Name> <pkg>" for every type the facade re-exports by name — what separates
# a `type` from an `intermediate` below.
named=$(sed -n \
  's/^pub using @\([a-z_]*\) {type \([A-Za-z0-9_]*\)}.*/\2 \1/p' "$mbti")

extract() {
  printf '%s\n' "$files" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    pkg=$(dirname "$f")
    [ "$pkg" != "." ] || pkg=root
    NAMED="$named" awk -v pkg="$pkg" '
      BEGIN {
        n = split(ENVIRON["NAMED"], line, "\n")
        for (i = 1; i <= n; i++) if (line[i] != "") reexported[line[i]] = 1
      }
      # `#alias(x)` gives the next method a second callable spelling, so
      # dropping the attribute is as breaking as deleting a method.
      /^#alias\(/ {
        alias = $0
        sub(/^#alias\(/, "", alias)
        sub(/\).*/, "", alias)
        next
      }
      /^pub fn / {
        sig = $3
        sub(/\(.*/, "", sig)
        if (sig ~ /::/) {
          split(sig, part, "::")
          print (part[1] == part[2] ? "ctor " : "method ") sig " <- " pkg
          if (alias != "") print "alias " part[1] "::" alias " <- " pkg
        } else {
          print "fn " sig " <- " pkg
          if (alias != "") print "alias " alias " <- " pkg
        }
        alias = ""
        next
      }
      /^pub impl / { print "impl " $3 " for " $5 " <- " pkg; alias = ""; next }
      /^pub(\(all\))? (struct|enum|suberror|trait) / {
        tname = $3
        sub(/[{].*/, "", tname)
        key = tname " " pkg
        print (key in reexported ? "type " : "intermediate ") tname " <- " pkg
        alias = ""
        next
      }
      # A struct body line: `  <name> : <type>`. Enum variants never carry a
      # `:`, and an opaque struct says `// private fields` instead, so only
      # genuinely public fields land here.
      /^  [A-Za-z_][A-Za-z0-9_]* : / && tname != "" {
        print "field " tname "." $1 " <- " pkg
      }
    ' "$f"
  done | LC_ALL=C sort -u
}

current=$(extract)
count() { printf '%s\n' "$1" | grep -cE ' <- ' || true; }

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
  printf 'facade surface: the callable surface behind the facade changed.\n'
  printf '  A symbol was added to, removed from, or moved on a public package\n'
  printf '  — including a method or field on a type the facade re-exports,\n'
  printf '  which reaches callers as @moonframe.Type::method without any\n'
  printf '  facade change. The facade is the supported stable surface, so an\n'
  printf '  accidental over-export becomes a breaking change once published.\n'
  printf '  If the change is intended, regenerate:\n'
  printf '    sh .github/scripts/check_facade_surface.sh --write\n'
  printf '%s\n' "$diff_out" | sed 's/^/    /'
  exit 1
fi

printf 'facade surface: %s symbols match the snapshot\n' "$(count "$current")"
