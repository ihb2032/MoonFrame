#!/bin/sh
# Production layering guard. The package graph is the one architectural
# invariant that prose alone has never been able to hold: `frame` reached into
# the physical column layer for three releases while every document said it
# should not, and the document that finally described the rule contradicted the
# manifests within one commit. This reads the manifests instead.
#
# The rule, in the form the build can check — who may name the physical column:
#
#   internal/column   how a column is laid out: data buffers + validity bitmap
#   series            what a column is: dtype, validity, backend convergence
#   internal/kernel   how a column is computed: one vectorized pass per operator
#   frame and above   what a verb means: row sets, scheduling, schema, errors
#
# `series` and `internal/kernel` import `internal/column`; nothing else does.
# `internal/kernel` sits *beside* `series` rather than above it — it needs the
# representation to keep the numeric fast paths — which is precisely the nuance
# a layer diagram loses and an import list does not.
#
# Four checks:
#   1. `internal/column` is imported only by `series` and `internal/kernel`.
#   2. No `internal/*` package imports `frame` / `io` / `lazy` — the internal
#      layers stay below the verbs, never circling back.
#   3. The root facade imports exactly the six public packages.
#   4. No public package's generated interface names an `internal/` package:
#      an internal type reaching a public signature is the leak all of this
#      exists to prevent.
#
# Production imports only. A `import { ... } for "test"` block is the test
# configuration and is deliberately allowed to reach further — `frame`'s tests
# name `StorageKind` to assert which backend an operator's output lands on,
# which is behaviour worth pinning and not a layering violation.
#
# Usage: .github/scripts/check_layering.sh [repo-root]
# Exit 0 when the manifests obey the rule, 1 on a violation.

set -eu

root="${1:-.}"
cd "$root"

module="ihb2032/MoonFrame"
column_importers="series internal/kernel"
public_packages="expr frame io lazy series types"
verb_packages="frame io lazy"

fail=0
report() {
  printf 'layering: %s\n' "$1"
  fail=1
}

# One `<pkg> -> <dep>` edge per production import of a package in this module.
# `git ls-files` never lists a `_build` copy; `examples/` are programs built on
# the facade, not layers of it.
edges=$(git ls-files '*moon.pkg' | grep -v '^examples/' |
  while IFS= read -r manifest; do
    pkg=$(dirname "$manifest")
    [ "$pkg" != "." ] || pkg=root
    awk -v pkg="$pkg" -v module="$module" '
      /^import \{/ { inblock = 1; n = 0; next }
      # A block closed by `} for "test"` is the test configuration: buffered
      # and dropped, so only production edges are emitted.
      inblock && /^\}/ {
        if ($0 !~ /for "test"/) {
          for (i = 1; i <= n; i++) print pkg " -> " dep[i]
        }
        inblock = 0
        next
      }
      inblock {
        want = "\"" module "/"
        if (index($0, want) > 0) {
          d = substr($0, index($0, want) + length(want))
          sub(/".*/, "", d)
          dep[++n] = d
        }
      }
    ' "$manifest"
  done | LC_ALL=C sort -u)

in_list() {
  # in_list <needle> <space-separated haystack>
  for item in $2; do
    [ "$item" != "$1" ] || return 0
  done
  return 1
}

# 1 + 2: every production edge, checked against the two structural rules. The
# loop runs in a pipeline — a subshell — so it reports by *printing* its
# findings and the verdict is taken from the collected text out here.
edge_violations=$(printf '%s\n' "$edges" | while IFS= read -r edge; do
  [ -n "$edge" ] || continue
  from=${edge%% -> *}
  to=${edge##* -> }
  if [ "$to" = "internal/column" ] && ! in_list "$from" "$column_importers"; then
    printf '%s imports internal/column; only [%s] may\n' \
      "$from" "$column_importers"
  fi
  case "$from" in
    internal/*)
      if in_list "$to" "$verb_packages"; then
        printf '%s imports %s — an internal layer stays below the verbs\n' \
          "$from" "$to"
      fi
      ;;
  esac
done)
if [ -n "$edge_violations" ]; then
  printf '%s\n' "$edge_violations" | while IFS= read -r line; do
    printf 'layering: %s\n' "$line"
  done
  fail=1
fi

# 3: the facade's own dependencies are the public surface it re-exports.
root_deps=$(printf '%s\n' "$edges" | sed -n 's/^root -> //p' | LC_ALL=C sort -u |
  tr '\n' ' ' | sed 's/ *$//')
expected_root=$(printf '%s\n' $public_packages | LC_ALL=C sort -u |
  tr '\n' ' ' | sed 's/ *$//')
if [ "$root_deps" != "$expected_root" ]; then
  report "the root facade imports [$root_deps]; expected exactly [$expected_root]"
fi

# 4: an internal type in a public interface is the leak, whatever the manifests
# say. `moon info` regenerates these, so this reads the committed result.
for pkg in $public_packages; do
  mbti="$pkg/pkg.generated.mbti"
  [ -f "$mbti" ] || continue
  if grep -q "$module/internal/" "$mbti"; then
    report "$mbti names an internal package in the public interface"
  fi
done
if [ -f pkg.generated.mbti ] && grep -q "$module/internal/" pkg.generated.mbti; then
  report "the root facade interface names an internal package"
fi

if [ "$fail" -ne 0 ]; then
  printf '  The package graph left the shape the architecture docs describe\n'
  printf '  (README, "Contributing"; docs/api.md, "Packages"). Move the code,\n'
  printf '  or — if the layering itself should change — change it here first,\n'
  printf '  in the rule, and then in both documents.\n'
  exit 1
fi

printf 'layering: %s production edges obey the rule\n' \
  "$(printf '%s\n' "$edges" | grep -c ' -> ')"
