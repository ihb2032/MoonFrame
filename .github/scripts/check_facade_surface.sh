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
# because the verb returning it must be `pub`, and every one of them is a
# chain step. `--write` would happily bless a new one — a helper type that
# leaked out of an implementation — as "intermediate" and, from then on, as
# part of the shipped surface. So the allowlist below is checked *before*
# the snapshot, and an unexpected non-facade public type fails whatever the
# snapshot says.
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
# fluent chain (`when(c).then(a).otherwise(b)`, `group_by(k).agg(e)`,
# `plot(df).bar(x=, y=)` and the refinement chain off the mark), `pub`
# only because the verb returning it must be, and reached by chaining off that
# verb's return value rather than by name. This list is what decides the
# intermediate tag for a type the facade does not re-export — ahead of the
# chart bucketing below, so a chain step in `chart` is an intermediate (which
# it is: `FramePlot` / `Plot` chain exactly the way `WhenThen` does), not a
# deep-mirror type. Widen this only alongside the facade
# comment that explains why the type is unnameable — never to make a guard
# pass.
#
# Package-qualified, because a bare name is a weaker claim than it looks: the
# allowlist says *this* type in *this* package is chained through, and `io`
# growing its own `WhenThen` is a different symbol that nothing chains to.
intermediates="expr/WhenThen expr/WhenThenElse frame/GroupedDataFrame frame/LazyGroupBy chart/FramePlot chart/Plot"

# The public free functions the facade deliberately does not re-export: the
# string-level serialiser family. Building a frame from in-memory text is a
# slice of the surface reached through the `io` package itself
# (`@io.parse_csv_str`) — the way `read_csv(StringIO(...))` is in pandas — so
# the facade's first-contact face keeps the file-level verbs alone. Their
# signatures stay pinned by the snapshot below like any other public symbol;
# only the re-export requirement is lifted for these six. Widen this only
# alongside the facade comment that explains why a function is left off the
# facade — never to make a guard pass.
#
# Package-qualified for the same reason as the intermediates list.
qualified_reach="io/format_csv io/format_json io/format_ndjson io/parse_csv_str io/parse_json_str io/parse_ndjson_str"

# The chart package's mirror of the Vega-Lite spec is two surfaces at once:
# a main face a first-contact caller builds a chart from (the spec type, the
# mark enum, the channel builder and the enums its parameters name), and a
# deep family of spec-object trees (scales, axes, legends, transforms,
# config …) that only a caller already speaking `@chart` reaches — the same
# deliberate package-qualification as the io serialiser family, scoped to a
# package because the family grows with every mirror PR. The pin is two-way:
# a name on this list must be on the facade (and must still exist), and a
# chart symbol not on it must NOT be on the facade — `@chart.VegaScale`, not
# a bare `VegaScale` nobody promised. Shrink or grow the list only alongside
# the facade comment that draws the same line.
chart_main="chart/Chart chart/ChartSpec chart/ChartKind chart/VegaAggregate chart/VegaAutoSize chart/VegaBin chart/VegaBinParams chart/VegaChannel chart/VegaChannelSort chart/VegaExtent chart/VegaPadding chart/VegaRepeatRef chart/VegaSort chart/VegaSortChannel chart/VegaStack chart/VegaTimeUnit chart/VegaType chart/constant chart/datum chart/field chart/format_vega_html chart/format_vega_lite chart/plot chart/write_vega_html chart/write_vega_lite"

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
    NAMED="$named" CHART_MAIN="$chart_main" INTERMEDIATES="$intermediates" \
      awk -v pkg="$pkg" '
      BEGIN {
        n = split(ENVIRON["NAMED"], line, "\n")
        for (i = 1; i <= n; i++) if (line[i] != "") reexported[line[i]] = 1
        n = split(ENVIRON["CHART_MAIN"], entry, "\n")
        for (i = 1; i <= n; i++) if (entry[i] != "") {
          split(entry[i], pair, "/")
          chartmain[pair[2]] = 1
        }
        n = split(ENVIRON["INTERMEDIATES"], entry, " ")
        for (i = 1; i <= n; i++) if (entry[i] != "") chainstep[entry[i]] = 1
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
      # `pub impl Trait for Type`, and `pub impl[T] Trait for Type[T]` — the
      # generic form shifts every field, so the trait and the type are found by
      # locating `for` rather than by counting words. Reading `$3` and `$5`
      # turned a generic impl into `impl [T] for for`, and two different ones
      # into the same line, which `sort -u` then merged out of the snapshot.
      /^pub impl / {
        rest = $0
        sub(/^pub impl/, "", rest)
        sub(/^(\[[^]]*\])?[ \t]*/, "", rest)
        idx = index(rest, " for ")
        if (idx > 0) {
          trait_name = substr(rest, 1, idx - 1)
          target = substr(rest, idx + 5)
          print "impl " trait_name " for " target " <- " pkg
        } else {
          print "impl " rest " <- " pkg
        }
        alias = ""
        next
      }
      /^pub(\([a-z]+\))? (struct|enum|type|suberror|trait) / {
        # The visibility qualifiers MoonBit spells on a type — `pub`,
        # `pub(all)`, `pub(open)`, `pub(abstract)`, `pub(sealed)` — all
        # publish the type, so all of them are read here. Anything else in
        # the parentheses is refused outright (the whitelist rule above).
        if (match($0, /^pub\([a-z]+\)/)) {
          qual = substr($0, 5, RLENGTH - 5)
          if (qual != "all" && qual != "open" && qual != "abstract" &&
              qual != "sealed")
            print "refused " $0 " <- " pkg
        }
        tname = $3
        sub(/[{].*/, "", tname)
        key = tname " " pkg
        # The intermediates list decides first: a type on it is a chain
        # step whatever package it lives in — the chart `FramePlot` /
        # `Plot` chain exactly the way `WhenThen` does, and the chart
        # bucketing below must not sweep a chain step into the deep
        # mirror. Off the list, a chart type the facade does not name is a
        # member of the deep mirror family (reached through `@chart`
        # qualification) when it is off the `chart_main` list, and a
        # main-surface type that lost its re-export when it is on it — the
        # two-way pin below settles which.
        tag = "intermediate "
        if (!(key in reexported) && pkg == "chart" &&
            !(tname in chartmain) && !((pkg "/" tname) in chainstep))
          tag = "qualified "
        print (key in reexported ? "type " : tag) tname " <- " pkg
        alias = ""
        next
      }
      # A struct body line: `  <name> : <type>`, or `  mut <name> : <type>`.
      # Enum variants never carry a `:`, and an opaque struct says
      # `// private fields` instead, so only genuinely public fields land here.
      # The type rides along for the same reason a signature does — `Bool`
      # widening to `Bool?` is a break that leaves the field name untouched — and
      # so does `mut`, which the rule below rejects outright. Matching it here is
      # what makes that possible: a pattern without the optional `mut` skips such
      # a field entirely, leaving it out of the snapshot *and* out of reach of
      # every rule, which is the quietest way for one to appear.
      /^  (mut )?[A-Za-z_][A-Za-z0-9_]* : / && tname != "" {
        fdecl = $0
        sub(/^ +/, "", fdecl)
        print "field " tname "." fdecl " <- " pkg
      }
    ' "$f"
  done | LC_ALL=C sort -u
}

current=$(extract)
count() { printf '%s\n' "$1" | grep -cE ' <- ' || true; }

# A visibility qualifier the extractor does not know is a type this lock
# cannot classify, and the old pattern — `pub(\(all\))?` — let it fall out of
# the snapshot silently: `pub(open)` arriving with the language would have
# dropped every type carrying it from the pin in one release. The set is a
# whitelist, so a new qualifier fails here and is taught deliberately.
refused=$(printf '%s\n' "$current" | sed -n 's/^refused //p' || true)
if [ -n "$refused" ]; then
  printf 'facade surface: a visibility qualifier the extractor does not know:\n'
  printf '%s\n' "$refused" | sed 's/^/  /'
  printf '  The extractor reads pub, pub(all), pub(open), pub(abstract) and\n'
  printf '  pub(sealed). Add the new qualifier to the whitelist — so every\n'
  printf '  type carrying it is classified as re-exported / intermediate /\n'
  printf '  qualified — rather than widening the pattern to any `pub(…)`\n'
  printf '  spelling, which could not fail and so could not be taught.\n'
  exit 1
fi

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
  printf '  That is deliberate for the fluent chain steps, deliberate for the\n'
  printf '  chart deep mirror family (off the chart_main list, reached through\n'
  printf '  `@chart` qualification), and an accident otherwise — make the type\n'
  printf '  `priv`, re-export it and say why, or add it to no list by reflex.\n'
  printf '  Allowed chain steps: %s\n' "$intermediates"
  printf '  Chart main surface (these must be ON the facade): %s\n' "$chart_main"
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
    for allowed in $qualified_reach; do
      [ "$allowed" != "$pkg/$name" ] || continue 2
    done
    # A chart free function off the main-surface list is deep-family reach,
    # the same deliberate package-qualification as the io serialisers.
    if [ "$pkg" = "chart" ]; then
      printf '%s\n' $chart_main | grep -qx "chart/$name" || continue
    fi
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
  printf '  unless it is re-exported from this package.) Re-export it, reach\n'
  printf '  it through its package deliberately (the string-level serialiser\n'
  printf '  family does), or make it `priv` / an engine seam.\n'
  printf '  Deliberately package-qualified: %s\n' "$qualified_reach"
  printf '  Chart main surface (these must be ON the facade): %s\n' "$chart_main"
  exit 1
fi

# The chart pin's other direction: every name on the main-surface list must
# be a live public chart symbol and must be on the facade. A symbol renamed
# out from under the list, or a re-export dropped while the list kept the
# name, leaves a line that lies in both directions — so both halves fail
# here rather than only wherever they happened to surface above. The pin
# only speaks where a chart interface is tracked at all; a fixture (or a
# fork) without the package has nothing to pin.
chart_tracked=$(printf '%s\n' "$files" | grep -qx 'chart/pkg.generated.mbti' &&
  echo yes || echo no)
chart_live=$(printf '%s\n' "$current" |
  sed -n -e 's/^\(type\|intermediate\|qualified\) \([A-Za-z0-9_]*\) <- chart$/\2/p' \
    -e 's/^fn \([A-Za-z0-9_]*\)(.* <- chart$/\1/p' | LC_ALL=C sort -u)
chart_on_facade="$(
  printf '%s\n' "$current" | sed -n 's/^type \([A-Za-z0-9_]*\) <- chart$/\1/p'
  printf '%s\n' "$facade_fns" | sed -n 's/^\([A-Za-z0-9_]*\) chart$/\1/p'
)"
chart_missing=""
if [ "$chart_tracked" = yes ]; then
  for entry in $chart_main; do
    name=${entry#chart/}
    if ! printf '%s\n' "$chart_live" | grep -qx "$name"; then
      chart_missing="$chart_missing
  $name (no public chart symbol carries this name)"
    elif ! printf '%s\n' "$chart_on_facade" | grep -qx "$name"; then
      chart_missing="$chart_missing
  $name (on the list, not on the facade)"
    fi
  done
fi
if [ -n "$chart_missing" ]; then
  printf 'facade surface: a stale or unexported chart main-surface entry:\n'
  printf '%s\n' "$chart_missing"
  printf '  The chart_main list is a two-way pin: its names ride the facade\n'
  printf '  and must stay live chart symbols; everything else in chart stays\n'
  printf '  deliberately `@chart`-qualified. Reconcile the list, the facade\n'
  printf '  block, and the package together.\n'
  exit 1
fi

# And the direction nothing else catches: a chart symbol on the facade but
# off the main-surface list. The facade is the first-contact promise, and a
# deep mirror type re-exported bare promises `VegaScale` as a supported name
# the chart_main line never drew — the quiet way the qualified family erodes
# into the facade one symbol at a time.
chart_bare="$(
  printf '%s\n' "$current" | sed -n 's/^type \([A-Za-z0-9_]*\) <- chart$/\1/p'
  printf '%s\n' "$facade_fns" | sed -n 's/^\([A-Za-z0-9_]*\) chart$/\1/p'
)"
chart_unpinned=""
if [ "$chart_tracked" = yes ]; then
  chart_unpinned=$(printf '%s\n' "$chart_bare" |
    while read -r name; do
      printf '%s\n' $chart_main | grep -qx "chart/$name" || printf '  %s\n' "$name"
    done)
fi
if [ -n "$chart_unpinned" ]; then
  printf 'facade surface: a chart symbol on the facade but off the main list:\n'
  printf '%s\n' "$chart_unpinned"
  printf '  The deep mirror family reaches callers through `@chart`\n'
  printf '  qualification, and the facade re-exporting one of its names bare\n'
  printf '  is a promise the chart_main line never made. Grow the list (and\n'
  printf '  the facade comment) or take the re-export back out.\n'
  exit 1
fi

# `\b` is a GNU extension rather than POSIX ERE, so whether a bare
# `StringBuilder` field matched depended on which grep ran. The bracketed
# container types carry their own delimiter (`[`); the two that do not are
# matched with a trailing non-identifier character or the line end. The
# delimiter is deliberately only on the trailing side: a leading
# `[^[:alnum:]_]` directly after `.*` inside an alternation is mis-handled by
# at least one grep in use here, and a type merely *ending* in one of these
# names is worth the same look anyway.
# The container names are enumerated from the interfaces the bundled core
# ships — builtin's Array / FixedArray / ArrayView / MutArrayView /
# ReadOnlyArray / UninitializedArray / Map / Set / StringBuilder, buffer's
# Buffer, deque's Deque, hashmap / hashset, queue / priority_queue, sorted_map
# / sorted_set — rather than named from memory, and the read-only views are
# held to the same rule as the writable containers: reading one hands the
# caller a live alias into state someone else is holding.
mutable_fields=$(printf '%s\n' "$current" |
  grep -E '^(field|value) [^:]*: .*((Array|FixedArray|MutArrayView|ReadOnlyArray|UninitializedArray|ArrayView|Map|HashMap|SortedMap|Set|HashSet|SortedSet|Deque|Queue|PriorityQueue|Ref)\[|(StringBuilder|Buffer)([^[:alnum:]_]|$))' ||
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

# The same leak one step earlier, and for any type at all: `mut` on a public
# field lets a caller *assign* into a value it merely read, so every holder of
# that value — a captured plan, an options struct passed to two readers — sees
# the change. No type here has one; the rule is what keeps that true, now that
# the extractor above can see one.
mutable_field_decls=$(printf '%s\n' "$current" |
  grep -E '^field [A-Za-z0-9_]+\.mut ' || true)
if [ -n "$mutable_field_decls" ]; then
  printf 'facade surface: a public `mut` field:\n'
  printf '%s\n' "$mutable_field_decls" | sed 's/^/  /'
  printf '  A caller that can read the value can now write into it, and every\n'
  printf '  other holder of that value sees the write. Every public type here is\n'
  printf '  immutable once built: keep the field `priv` behind a constructor, and\n'
  printf '  return a modified copy where a setter was wanted.\n'
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
