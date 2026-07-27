#!/bin/sh
# Engine-seam lock. MoonBit has no visibility between `priv` (this package) and
# `pub` (anyone), so a kernel two public packages share has to be `pub`. The
# repository's answer is a pair of attributes — `#internal(engine, …)`, which
# alerts a *downstream* caller, and `#doc(hidden)`, which keeps the symbol out
# of the generated `.mbti` — and that second attribute is exactly why no other
# guard can see these symbols: the facade lock reads `.mbti` files, so the seam
# surface is invisible to it. What is invisible grows.
#
# This reads the sources instead and pins every `pub` declaration in a public
# package that carries either attribute, with its normalised signature and the
# packages that call it:
#
#   series | doc_hidden internal_engine |
#     pub fn mask_true_indices(mask : Series) -> Array[Int]? | used by: frame
#
# Signature and not just the name, because the risk here is a seam quietly
# widening — one that used to return a `Series` starting to return the column's
# own `Array`, say, which hands another package the ability to mutate a value
# that is supposed to be immutable. That shows up as a diff.
#
# Callers, because the question worth asking about a seam is not only whether
# its signature moved but whether anything outside its own package still needs
# it: two storage-taking constructors turned out to have no such caller and
# stopped being `pub` at all, and three backend-forcing helpers that only tests
# ever called were deleted rather than kept. A seam with no such caller is not
# a seam — it is a symbol the compiler lets anyone reach for no reason the
# architecture can state.
#
# So that case is a failure, not a note. The exceptions are named in
# `engine_seams.allowlist`, each with the reason it is one, and that file is
# the one part of this guard `--write` cannot touch: adding a seam that nothing
# outside its package calls means editing it, in a diff of its own, where it
# can be argued with. The entries today are all symbols whose whole purpose is
# to be asserted, by tests that live in another package and have no other way
# to see what they check. Being convenient for a test is not
# on the list. Note what the alternative is not: making such a symbol private
# does not work here, because `unused_value` counts production callers only, so
# the strict warning gate rejects a private function that only tests call —
# correctly. A symbol no production code calls and no other package has to
# assert is dead weight in a production source file, and the fix is to delete
# it and write the test against what production does use.
#
# The list is derived rather than maintained by hand, which keeps it in step
# with the code, but it is not a resolved call graph. Two filters do the real
# work: only packages that *import* the declaring one are searched (nothing else
# can name its symbols), and declaration and comment lines are dropped. What
# remains is a lexical match on the short name, so a dependent package calling
# a same-named method on a different receiver still counts — read a caller list
# as "this package mentions the name", not as proof of a call.
#
# One rule is checked outright rather than snapshotted: the two attributes come
# as a pair, in both directions. `#internal(engine)` without `#doc(hidden)`
# would sit in the public interface as a compatibility promise while alerting
# anyone who used it. `#doc(hidden)` without `#internal(engine)` is the quieter
# mistake and the more dangerous one — hiding a symbol from the `.mbti` does
# not stop a downstream caller reaching it, it only stops anyone *noticing*:
# no alert, no entry in the generated reference, and invisible to the facade
# lock. A symbol like that is public API by accident.
#
# Nothing here upgrades a seam into a compatibility promise. The point is that
# adding one, or widening one, is a decision someone made on purpose:
#
#   sh .github/scripts/check_engine_seams.sh --write
#
# Usage: .github/scripts/check_engine_seams.sh [repo-root] [--write]
# Exit 0 when the seams match the snapshot, 1 on drift (or a missing one).

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

snapshot=".github/scripts/engine_seams.snapshot"

# Seams no production code outside the declaring package calls, and the reason
# each is allowed to stay `pub` anyway: one `pkg/Symbol — reason` per line, `#`
# for comments. A separate file rather than a constant here, so that adding an
# exception is a line in a diff of its own; nothing writes it, `--write`
# included.
allowlist=".github/scripts/engine_seams.allowlist"
allowed_no_production_callers=$(
  [ -f "$allowlist" ] && grep -v '^[[:space:]]*#' "$allowlist" || true
)

# Public packages only: the root facade and the six re-exported ones. An
# `internal/` package is unimportable downstream, so a `pub` inside it promises
# nothing and needs no lock. Test files are not the surface — both spellings:
# a `_wbtest.mbt` compiles *inside* its package, so a `pub` helper declared
# there is even less of an external symbol than a blackbox one.
files=$(git ls-files '*.mbt' |
  grep -vE '_(test|wbtest)\.mbt$' |
  grep -v '^internal/' | grep -v '/internal/' |
  grep -v '^examples/' || true)

extract() {
  printf '%s\n' "$files" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    # `git ls-files` still lists a file deleted in the working tree but not yet
    # staged; reading it would abort the scan and silently drop every seam
    # after it.
    [ -f "$f" ] || continue
    pkg=$(dirname "$f")
    [ "$pkg" != "." ] || pkg=root
    awk -v pkg="$pkg" '
      function flush_attrs() { hidden = 0; internal = 0 }
      # A block separator ends whatever attribute run preceded it.
      /^\/\/\/\|/ { flush_attrs(); next }
      /^#doc\(hidden\)/ { hidden = 1; next }
      /^#internal\(engine/ { internal = 1; next }
      # Any other attribute (`#alias`, `#deprecated`, …) rides along.
      /^#/ { next }
      # A declaration consumes the run. Only `pub` ones are seams; a private
      # one still clears the attributes so they cannot leak onto a later
      # declaration.
      /^(pub|fn|let|const|struct|enum|impl|type|test|suberror|extern)/ {
        if ($0 !~ /^pub/ || (hidden == 0 && internal == 0)) {
          flush_attrs()
          next
        }
        # Join a wrapped signature into one line: keep appending until the
        # header closes with `{` (every fn / struct / enum body opens one) or,
        # for `pub extend T with Trait::{…}`, with `}`. A top-level value has
        # no body to open, so it is taken as it stands — without this it would
        # swallow every declaration up to the next brace.
        decl = $0
        while (decl !~ /[{}][ \t]*$/ && decl !~ /^pub (let|const) /) {
          if ((getline nextline) <= 0) break
          sub(/^[ \t]+/, "", nextline)
          decl = decl " " nextline
        }
        sub(/[ \t]*\{[ \t]*$/, "", decl)
        gsub(/[ \t]+/, " ", decl)
        sub(/[ \t]+$/, "", decl)
        attrs = ""
        if (hidden) attrs = "doc_hidden"
        if (internal) attrs = (attrs == "" ? "" : attrs " ") "internal_engine"
        print pkg " | " attrs " | " decl
        # A hidden `pub(all)` enum is matchable and constructible by the
        # packages that share it, so its variant set is part of the seam the
        # same way a signature is — and it reaches no `.mbti`, so the
        # enum-surface lock cannot see it either. Record each variant.
        if (decl ~ /^pub\(all\) (enum|suberror) /) {
          ename = decl
          sub(/^pub\(all\) (enum|suberror) /, "", ename)
          sub(/ .*/, "", ename)
          while ((getline vline) > 0) {
            if (vline ~ /^\}/) break
            v = vline
            sub(/^[ \t]+/, "", v)
            sub(/[ \t]+$/, "", v)
            if (v != "") print pkg " | " attrs " | variant " ename "::" v
          }
        }
        flush_attrs()
      }
    ' "$f"
  done | LC_ALL=C sort -u
}

# Production sources and production import edges, read once. The edges are what
# keeps a same-named method elsewhere from being read as a call: `Series` and
# `ColumnStorage` both have a `to_builtin`, and only `io` and `lazy` import
# `frame`, so only they can be calling `DataFrame::to_builtin`.
production_files=$(git ls-files '*.mbt' | grep -vE '_(test|wbtest)\.mbt$' || true)

production_edges=$(git ls-files '*moon.pkg' | grep -v '^examples/' |
  while IFS= read -r manifest; do
    pkg=$(dirname "$manifest")
    [ "$pkg" != "." ] || pkg=root
    awk -v pkg="$pkg" '
      /^import \{/ { inblock = 1; n = 0; next }
      inblock && /^\}/ {
        if ($0 !~ /for "test"/) for (i = 1; i <= n; i++) print pkg " " dep[i]
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

dependents_of() {
  printf '%s\n' "$production_edges" | awk -v want="$1" '$2 == want { print $1 }'
}

consumers_of() {
  # consumers_of <declaring-pkg> <symbol>
  short=${2##*::}
  case "$short" in
    "" | *[!A-Za-z0-9_]*) printf '%s' "-"; return ;;
  esac
  candidates=$(dependents_of "$1" | grep -v "^$1$" || true)
  [ -n "$candidates" ] || { printf '(no production caller outside %s)' "$1"; return; }
  found=$(printf '%s\n' "$candidates" | while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if [ "$cand" = root ]; then
      files=$(printf '%s\n' "$production_files" | grep -v '/' || true)
    else
      files=$(printf '%s\n' "$production_files" | grep "^$cand/[^/]*\$" || true)
    fi
    [ -n "$files" ] || continue
    # Line-level, so a comment or a same-named *declaration* in the dependent
    # package does not read as a call.
    hits=$(printf '%s\n' "$files" | tr '\n' '\0' |
      xargs -0 grep -nE "(^|[^A-Za-z0-9_])${short}\(" 2>/dev/null |
      grep -vE '^([^:]*:)?[0-9]+:[[:space:]]*//' |
      grep -vE '^([^:]*:)?[0-9]+:[[:space:]]*(pub )?fn(\[[^]]*\])? ' || true)
    [ -z "$hits" ] || printf '%s\n' "$cand"
  done | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//')
  [ -n "$found" ] || found="(no production caller outside $1)"
  printf '%s' "$found"
}

current=$(extract | while IFS= read -r line; do
  [ -n "$line" ] || continue
  pkg=${line%% | *}
  decl=${line##* | }
  case "$decl" in
    "pub fn "* | "pub fn["*)
      # `pub fn[T] name(...)` is a function too: matching only the ungenerified
      # spelling left generic seams with no caller line at all.
      sym=${decl#pub fn}
      sym=${sym# }
      case "$sym" in
        \[*) sym=${sym#*\] } ;;
      esac
      sym=${sym%%(*}
      printf '%s | used by: %s\n' "$line" "$(consumers_of "$pkg" "$sym")"
      ;;
    *) printf '%s\n' "$line" ;;
  esac
done)
count() { printf '%s\n' "$1" | grep -c ' | ' || true; }

# The attributes come as a pair. Either alone leaves a symbol that is public in
# practice but unaccounted for in one direction or the other.
half_marked=$(printf '%s\n' "$current" |
  grep -E ' \| (internal_engine|doc_hidden) \| ' || true)
if [ -n "$half_marked" ]; then
  printf 'engine seams: a seam carrying only one of the two attributes:\n'
  printf '%s\n' "$half_marked" | sed 's/^/  /'
  printf '  #internal(engine) alone says "not for downstream" while the\n'
  printf '  generated interface still publishes it. #doc(hidden) alone hides\n'
  printf '  the symbol from the reference and from every guard that reads a\n'
  printf '  .mbti, without stopping anyone calling it — public API by\n'
  printf '  accident. Add the missing attribute, or drop both and accept the\n'
  printf '  symbol as public API.\n'
  exit 1
fi

# A seam nothing outside its package calls has to be argued for by name. This
# runs before `--write` on purpose: regenerating the snapshot must not be a way
# to accept one.
seam_key() {
  # seam_key <line> → `pkg/Symbol` for a `pub fn` seam, empty for anything else.
  line=$1
  pkg=${line%% | *}
  rest=${line#* | * | }
  decl=${rest%% | used by:*}
  case "$decl" in
    "pub fn "* | "pub fn["*) ;;
    *) return ;;
  esac
  sym=${decl#pub fn}
  sym=${sym# }
  case "$sym" in
    \[*) sym=${sym#*\] } ;;
  esac
  printf '%s/%s' "$pkg" "${sym%%(*}"
}

allowed_entry() {
  printf '%s\n' "$allowed_no_production_callers" | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      "$1 — "*) printf '%s' "$entry" ;;
    esac
  done
}

caller_less=$(printf '%s\n' "$current" |
  grep -F '| used by: (no production caller outside' || true)

unlisted=$(printf '%s\n' "$caller_less" | while IFS= read -r line; do
  [ -n "$line" ] || continue
  key=$(seam_key "$line")
  [ -n "$key" ] || continue
  [ -n "$(allowed_entry "$key")" ] || printf '%s\n' "$key"
done)
if [ -n "$unlisted" ]; then
  printf 'engine seams: a seam with no production caller outside its package:\n'
  printf '%s\n' "$unlisted" | sed 's/^/  /'
  printf '  Nothing but tests reaches these, so `pub` buys the architecture\n'
  printf '  nothing: delete the symbol and assert through what production does\n'
  printf '  use, or — if another package genuinely has to assert it and has no\n'
  printf '  other way to see it — add it with its reason to\n'
  printf '  %s, in a reviewable diff.\n' "$allowlist"
  exit 1
fi

# And the list stays honest in the other direction: an entry whose seam gained a
# caller, changed name, or went away is one nobody has re-read since.
stale=$(printf '%s\n' "$allowed_no_production_callers" | while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  key=${entry%% — *}
  # `if`, not `&&`: a final iteration whose test fails would make the loop —
  # and so the substitution, and so this `set -e` script — exit non-zero.
  hit=$(printf '%s\n' "$caller_less" | while IFS= read -r line; do
    if [ "$(seam_key "$line")" = "$key" ]; then printf 'yes'; fi
  done)
  [ -n "$hit" ] || printf '%s\n' "$key"
done)
if [ -n "$stale" ]; then
  printf 'engine seams: an exception that is no longer needed:\n'
  printf '%s\n' "$stale" | sed 's/^/  /'
  printf '  It has a production caller now, was renamed, or is gone. Drop the\n'
  printf '  entry from %s —\n' "$allowlist"
  printf '  an exception nobody re-reads is how the list grows.\n'
  exit 1
fi

if [ "$write" -eq 1 ]; then
  printf '%s\n' "$current" >"$snapshot"
  printf 'engine seams: wrote %s (%s seams)\n' "$snapshot" "$(count "$current")"
  exit 0
fi

if [ ! -f "$snapshot" ]; then
  printf 'engine seams: snapshot %s missing — run with --write to create it\n' \
    "$snapshot"
  exit 1
fi

if ! diff_out=$(printf '%s\n' "$current" | diff -u "$snapshot" - 2>&1); then
  printf 'engine seams: the hidden cross-package surface changed.\n'
  printf '  A `pub` symbol carrying #internal(engine) / #doc(hidden) was\n'
  printf '  added, removed, or changed signature. These are invisible to the\n'
  printf '  facade lock (they never reach a .mbti), so this is where widening\n'
  printf '  one — a seam that starts handing out a mutable buffer, say — has\n'
  printf '  to be noticed. If the change is intended, regenerate:\n'
  printf '    sh .github/scripts/check_engine_seams.sh --write\n'
  printf '%s\n' "$diff_out" | sed 's/^/    /'
  exit 1
fi

printf 'engine seams: %s seams match the snapshot\n' "$(count "$current")"
