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
#   fn <sig> <- <pkg>               free function (`<- root` = the facade's own)
#   type <Name> <- <pkg>            public type the facade re-exports by name
#   intermediate <Name> <- <pkg>    public type the facade deliberately does
#                                   not name: a fluent-chain step (`WhenThen`,
#                                   `GroupedDataFrame`, …) reached only by
#                                   chaining off the previous return value
#   ctor <sig> <- <pkg>             canonical constructor
#   method <sig> <- <pkg>           inherent or extension-exposed method
#   alias <Type>::<name> <- <pkg>   second callable spelling (`#alias`); the
#                                   signature is pinned on the method it renames
#   impl <Trait> for <Type> <- <pkg>
#   field <Type>.<name> : <ty> <- <pkg>   public struct field
#
# Signatures, not names. Half of what breaks a caller leaves every name in
# place: `head(Self, Int)` becoming `head(Self, Int64)`, an optional parameter
# becoming required, a `raise` appearing on a verb that was total, a public
# field widening from `Bool` to `Bool?`. `moon info` does not catch those
# either — it only checks that the committed interface matches the source,
# which it does the moment both are changed together. `moon info` writes one
# line per signature, so the interface line *is* the normalised form to pin.
#
# Any addition, removal, rename, signature change, reclassification (a
# re-exported type becoming an intermediate, or the reverse), or source-package
# change fails until the snapshot is regenerated deliberately:
#
#   sh .github/scripts/check_facade_surface.sh --write
#
# One thing a regenerable snapshot cannot express is a rule, and the
# intermediates are one: a public type the facade does not name exists only
# because the verb returning it must be `pub`, and there are exactly four.
# `--write` would happily bless a fifth — a helper type that leaked out of an
# implementation — as "intermediate" and, from then on, as part of the shipped
# surface. So the allowlist below is checked *before* the snapshot, and an
# unexpected non-facade public type fails whatever the snapshot says.
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
facade_source="moonframe.mbt"

# The public types the facade deliberately does not name: each is a step in a
# fluent chain (`when(c).then(a).otherwise(b)`, `group_by(k).agg(e)`), `pub`
# only because the verb returning it must be, and reached by chaining off that
# verb's return value rather than by name. Widen this only alongside the facade
# comment that explains why the type is unnameable — never to make a guard pass.
#
# Package-qualified, because a bare name is a weaker claim than it looks: the
# allowlist says *this* type in *this* package is chained through, and `io`
# growing its own `WhenThen` is a different symbol that nothing chains to.
intermediates="expr/WhenThen expr/WhenThenElse frame/GroupedDataFrame lazy/LazyGroupBy"

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
        # The whole declaration, not just the name: a caller breaks on
        # `head(Self, Int) -> head(Self, Int64)`, on an optional parameter
        # becoming required, and on a `raise` appearing, none of which changes
        # a name. `moon info` writes one line per signature, so the line *is*
        # the normalised form.
        decl = $0
        sub(/^pub fn /, "", decl)
        sub(/^\[[^]]*\] */, "", decl)
        name = decl
        sub(/\(.*/, "", name)
        if (name ~ /::/) {
          split(name, part, "::")
          print (part[1] == part[2] ? "ctor " : "method ") decl " <- " pkg
          if (alias != "") print "alias " part[1] "::" alias " <- " pkg
        } else {
          print "fn " decl " <- " pkg
          if (alias != "") print "alias " alias " <- " pkg
        }
        alias = ""
        next
      }
      # A public top-level value is as reachable as a function and as breaking
      # to change: `pub let` / `pub const` carry a type, and a constant whose
      # value or type moves is a caller-visible change. None exist today; the
      # extractor covers them so the first one is a decision, not an omission.
      /^pub (let|const) / {
        decl = $0
        sub(/^pub /, "", decl)
        print "value " decl " <- " pkg
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
      # genuinely public fields land here. The type rides along for the same
      # reason a signature does — `Bool` widening to `Bool?` is a break that
      # leaves the field name untouched.
      /^  [A-Za-z_][A-Za-z0-9_]* : / && tname != "" {
        fdecl = $0
        sub(/^ +/, "", fdecl)
        print "field " tname "." fdecl " <- " pkg
      }
    ' "$f"
  done | LC_ALL=C sort -u
}

current=$(extract)
count() { printf '%s\n' "$1" | grep -cE ' <- ' || true; }

# The rule, checked ahead of — and independently of — the snapshot, so
# regenerating cannot turn a leaked helper type into a shipped one. Every
# public type the facade does not name must be one of the known chain steps.
unexpected=$(printf '%s\n' "$current" | sed -n 's/^intermediate \([A-Za-z0-9_]*\) <- \(.*\)/\1 \2/p' |
  while read -r name pkg; do
    for allowed in $intermediates; do
      [ "$allowed" != "$pkg/$name" ] || continue 2
    done
    printf '  %s (in %s)\n' "$name" "$pkg"
  done)
if [ -n "$unexpected" ]; then
  printf 'facade surface: a public type the facade does not re-export:\n'
  printf '%s\n' "$unexpected"
  printf '  A public type the facade does not name is reachable-but-unnamed:\n'
  printf '  callable through whatever returns it, yet impossible to annotate.\n'
  printf '  That is deliberate for the fluent chain steps and an accident\n'
  printf '  otherwise — make the type `priv`, or re-export it and say why.\n'
  printf '  Allowed: %s\n' "$intermediates"
  exit 1
fi

# The second rule the snapshot cannot express. Reading a public field gives the
# caller the value *itself*, which for a mutable container means a shared,
# writable handle — enough to change a value someone else is holding, including
# one a `LazyFrame` captured into a built plan. Both cases the repository has
# had (`CsvReadOptions.null_values`, `JoinOptions`' key lists) were exactly
# this, so the shape is banned rather than snapshotted: keep the field `priv`
# and hand out a copy from an accessor. (`Bytes` and `String` are immutable in
# MoonBit, so a field holding one is a value like any other.)
# Which package each facade free function is re-exported *from*, read off the
# `pub using @pkg { … }` blocks. The generated root interface records that
# provenance for types and not for functions, and matching on the bare name
# would let `frame` publish its own `col` and ride on the one `expr` already
# put on the facade.
facade_fns=$(awk '
  /^pub using @[a-z_]+ \{/ { pkg = $3; sub(/^@/, "", pkg); sub(/\{.*/, "", pkg); inblock = 1 }
  inblock {
    line = $0
    sub(/^pub using @[a-z_]+ \{/, "", line)
    sub(/\}.*/, "", line)
    n = split(line, items, ",")
    for (i = 1; i <= n; i++) {
      item = items[i]
      gsub(/[ \t]/, "", item)
      if (item == "" || item ~ /^type/) continue
      print item " " pkg
    }
  }
  inblock && /\}/ { inblock = 0 }
' "$facade_source" | LC_ALL=C sort -u)

unexported_fns=$(printf '%s\n' "$current" |
  sed -n -e 's/^fn \(.*\) <- \(.*\)$/\2 \1/p' \
    -e 's/^value \(let\|const\) \([A-Za-z_][A-Za-z0-9_]*\).* <- \(.*\)$/\3 \2/p' |
  sed 's/(.*//' | LC_ALL=C sort -u |
  grep -v '^root ' |
  while read -r pkg name; do
    printf '%s\n' "$facade_fns" | grep -qx "$name $pkg" && continue
    printf '  %s (in %s)\n' "$name" "$pkg"
  done)
if [ -n "$unexported_fns" ]; then
  printf 'facade surface: a public symbol the facade does not re-export:\n'
  printf '%s\n' "$unexported_fns"
  printf '  Types can be reachable-but-unnamed (the fluent chain steps); a\n'
  printf '  free function or a top-level value cannot — nothing chains to one,\n'
  printf '  so one the facade omits is either an under-export a caller cannot\n'
  printf '  reach through the supported surface, or a helper that should not\n'
  printf '  be `pub` at all. (A same-named symbol on the facade does not count\n'
  printf '  unless it is re-exported from this package.) Re-export it, or make\n'
  printf '  it `priv` / an engine seam.\n'
  exit 1
fi

mutable_fields=$(printf '%s\n' "$current" |
  grep -E '^(field|value) [^:]*: .*((Array|FixedArray|Map|Set|Ref|ArrayView)\[|\b(StringBuilder|Buffer)\b)' ||
  true)
if [ -n "$mutable_fields" ]; then
  printf 'facade surface: a public field or value holding a mutable container:\n'
  printf '%s\n' "$mutable_fields" | sed 's/^/  /'
  printf '  Reading it hands the container itself to the caller, who can then\n'
  printf '  write through it — into a value already captured elsewhere. Make\n'
  printf '  the field `priv` and add an accessor that returns a copy, as\n'
  printf '  `CsvReadOptions::null_values` and `JoinOptions::on_keys` do.\n'
  exit 1
fi

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
