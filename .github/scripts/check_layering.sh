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
# Note the two relations that the four-line stack above blurs together:
# `internal/kernel` *depends on* `series` — it takes and returns columns — but
# is its *peer in storage access*, because a vectorized pass needs the
# representation to keep the numeric fast paths. Which is precisely the nuance
# a layer diagram loses and an import list does not.
#
# Five checks:
#   1. `internal/column` is imported only by `series` and `internal/kernel`.
#   2. `internal/kernel` is imported only by `frame`. It is the execution
#      engine's private machinery; `io` or `lazy` reaching past `frame` for it
#      would route computation around the layer that owns what a verb means.
#   3. No `internal/*` package imports `frame` / `io` / `lazy` — the internal
#      layers stay below the verbs, never circling back.
#   4. The root facade imports exactly the six public packages.
#   5. No public package's generated interface names an `internal/` package:
#      an internal type reaching a public signature is the leak all of this
#      exists to prevent.
#
# Those five are rules: they hold for reasons, and changing one means changing
# the reason. Every *other* production edge is pinned in a snapshot instead —
# a new dependency between two packages is not wrong on its face, but it is a
# structural decision, and this is where it gets made deliberately:
#
#   sh .github/scripts/check_layering.sh --write
#
# Production imports only. A `import { ... } for "test"` block is the test
# configuration and is deliberately allowed to reach further — `frame`'s tests
# name `StorageKind` to assert which backend an operator's output lands on,
# which is behaviour worth pinning and not a layering violation.
#
# Usage: .github/scripts/check_layering.sh [repo-root] [--write]
# Exit 0 when the manifests obey the rules and match the snapshot, 1 otherwise.

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

snapshot=".github/scripts/layering.snapshot"
module="ihb2032/MoonFrame"
column_importers="series internal/kernel"
kernel_importers="frame"
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
  if [ "$to" = "internal/kernel" ] && ! in_list "$from" "$kernel_importers"; then
    printf '%s imports internal/kernel; only [%s] may\n' \
      "$from" "$kernel_importers"
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

# 4: the facade's own dependencies are the public surface it re-exports.
root_deps=$(printf '%s\n' "$edges" | sed -n 's/^root -> //p' | LC_ALL=C sort -u |
  tr '\n' ' ' | sed 's/ *$//')
expected_root=$(printf '%s\n' $public_packages | LC_ALL=C sort -u |
  tr '\n' ' ' | sed 's/ *$//')
if [ "$root_deps" != "$expected_root" ]; then
  report "the root facade imports [$root_deps]; expected exactly [$expected_root]"
fi

# 5: an internal type in a public interface is the leak, whatever the manifests
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

# The rules above cover the edges that must never appear. The snapshot covers
# the rest: every production edge, so a new dependency anywhere in the module
# is a diff rather than a silent widening of who knows about whom.
if [ "$write" -eq 1 ]; then
  printf '%s\n' "$edges" >"$snapshot"
  printf 'layering: wrote %s (%s edges)\n' \
    "$snapshot" "$(printf '%s\n' "$edges" | grep -c ' -> ')"
  exit 0
fi

if [ ! -f "$snapshot" ]; then
  printf 'layering: snapshot %s missing — run with --write to create it\n' \
    "$snapshot"
  exit 1
fi

if ! diff_out=$(printf '%s\n' "$edges" | diff -u "$snapshot" - 2>&1); then
  printf 'layering: the production dependency graph changed.\n'
  printf '  A package started (or stopped) depending on another. That is a\n'
  printf '  structural decision — which layer may know about which — so it\n'
  printf '  lands deliberately. If it is intended, regenerate:\n'
  printf '    sh .github/scripts/check_layering.sh --write\n'
  printf '%s\n' "$diff_out" | sed 's/^/    /'
  exit 1
fi

printf 'layering: %s production edges obey the rules and match the snapshot\n' \
  "$(printf '%s\n' "$edges" | grep -c ' -> ')"
