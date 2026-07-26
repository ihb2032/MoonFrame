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
# package that carries either attribute, with its normalised signature:
#
#   <pkg> | <attrs> | pub fn mask_true_indices(mask : Series) -> Array[Int]?
#
# Signature and not just the name, because the risk here is a seam quietly
# widening — one that used to return a `Series` starting to return the column's
# own `Array`, say, which hands another package the ability to mutate a value
# that is supposed to be immutable. That shows up as a diff.
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

current=$(extract)
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
