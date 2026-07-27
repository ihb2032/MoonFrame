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
# The checks:
#   1. `internal/column` is imported only by `series` and `internal/kernel`.
#   2. `internal/kernel` is imported only by `frame`. It is the execution
#      engine's private machinery; `io` or `lazy` reaching past `frame` for it
#      would route computation around the layer that owns what a verb means.
#   3. No `internal/*` package imports `frame` / `io` / `lazy` — the internal
#      layers stay below the verbs, never circling back.
#   4. Every package depends only on what its declared set allows: the
#      direction of the stack, package by package.
#   5. The graph is acyclic — the property that gives "direction" a meaning,
#      and the one no list of allowed edges can be trusted to imply.
#   6. The root facade imports exactly the six public packages.
#   7. No public package's generated interface names an `internal/` package:
#      an internal type reaching a public signature is the leak all of this
#      exists to prevent.
#
# Those are rules: they hold for reasons, and changing one means changing the
# reason. Every *other* production edge is pinned in a snapshot instead —
# a new dependency between two packages is not wrong on its face, but it is a
# structural decision, and this is where it gets made deliberately:
#
#   sh .github/scripts/check_layering.sh --write
#
# Production imports only. A test-configuration block — `for "test"` for the
# blackbox suite, `for "wbtest"` for the whitebox one — is deliberately allowed
# to reach further: `frame`'s tests name `StorageKind` to assert which backend
# an operator's output lands on, which is behaviour worth pinning and not a
# layering violation. Both spellings are dropped here, so a test-only
# dependency never enters the graph as a production edge.
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

# What each package is allowed to depend on. The snapshot records the edges
# that exist; this records the edges that *may* exist, which is the difference
# between noticing a change and refusing a reversal. Without it, `types`
# starting to depend on `series`, or `expr` on `frame`, is a snapshot away from
# permanent — the direction of the whole stack is exactly what should not be
# regenerable. A package absent here may depend on nothing inside the module.
allowed_root="expr frame io lazy series types"
allowed_types="internal/text"
allowed_series="types internal/column internal/text"
allowed_expr="types series internal/ir internal/literal internal/text"
allowed_frame="types series expr internal/ir internal/kernel"
allowed_io="types series frame internal/text"
allowed_lazy="types expr frame io internal/ir internal/literal internal/text"
allowed_internal_column="types internal/text"
allowed_internal_kernel="types series internal/column internal/ir internal/text"
allowed_internal_ir="types series"
allowed_internal_literal="types internal/text"
allowed_internal_text=""
verb_packages="frame io lazy"

fail=0
report() {
  printf 'layering: %s\n' "$1"
  fail=1
}

# One `<pkg> -> <dep>` edge per production import of a package in this module.
# `git ls-files` never lists a `_build` copy; `examples/` are programs built on
# the facade, not layers of it.
# Every rule below reads `moon.pkg`, so a package written with the legacy
# `moon.pkg.json` manifest would carry dependencies this guard never sees — a
# way past the whole file that costs nothing to close. One JSON manifest is
# expected: the CI fixture that builds a separate module against the published
# facade, which is deliberately not part of this module's graph.
json_manifests=$(git ls-files '*moon.pkg.json' |
  grep -v '^.github/fixtures/' || true)
if [ -n "$json_manifests" ]; then
  printf 'layering: a package using the legacy JSON manifest:\n'
  printf '%s\n' "$json_manifests" | sed 's/^/  /'
  printf '  Every rule here parses `moon.pkg`, so the imports declared in a\n'
  printf '  `moon.pkg.json` are invisible to the dependency graph, the import\n'
  printf '  allowlists, and the cycle check. Convert it to `moon.pkg`.\n'
  exit 1
fi

edges=$(git ls-files '*moon.pkg' | grep -v '^examples/' |
  while IFS= read -r manifest; do
    pkg=$(dirname "$manifest")
    [ "$pkg" != "." ] || pkg=root
    awk -v pkg="$pkg" -v module="$module" '
      /^import \{/ { inblock = 1; n = 0; next }
      # A block closed by a `for "test"` / `for "wbtest"` marker is a test
      # configuration: buffered and dropped, so only production edges are
      # emitted.
      inblock && /^\}/ {
        if ($0 !~ /for "(wb)?test"/) {
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

# 1–4: every production edge, checked against the structural rules. The
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
  # The direction of the stack, one package at a time.
  allowed_var="allowed_$(printf '%s' "$from" | tr '/-' '__')"
  eval "allowed=\${$allowed_var-UNDECLARED}"
  if [ "$allowed" = UNDECLARED ]; then
    printf '%s has no declared dependency set; add one to the layering rules\n' \
      "$from"
  elif ! in_list "$to" "$allowed"; then
    printf '%s imports %s, which is not in its allowed set [%s]\n' \
      "$from" "$to" "$allowed"
  fi
done)
if [ -n "$edge_violations" ]; then
  printf '%s\n' "$edge_violations" | while IFS= read -r line; do
    printf 'layering: %s\n' "$line"
  done
  fail=1
fi

# 5: acyclicity, by Kahn's algorithm over the production edges. The allowed
# sets above already forbid every reversal anyone has thought of; this catches
# the one nobody did, including a cycle spread across three packages. It is a
# property of the graph rather than a list, so unlike the snapshot there is
# nothing to regenerate.
cycle=$(printf '%s\n' "$edges" | awk '
  { from = $1; to = $3; edge[NR] = from " " to; node[from] = 1; node[to] = 1 }
  END {
    n = NR
    removed = 1
    while (removed) {
      removed = 0
      for (v in node) {
        if (!node[v]) continue
        # A node with no surviving outgoing edge, or none incoming, cannot sit
        # on a cycle. Peeling both ends leaves exactly the cyclic core, so the
        # report names the packages in the cycle rather than everything that
        # can reach one.
        has_out = 0
        has_in = 0
        for (i = 1; i <= n; i++) {
          if (!edge[i]) continue
          split(edge[i], e, " ")
          if (e[1] == v) has_out = 1
          if (e[2] == v) has_in = 1
        }
        if (!has_out || !has_in) {
          node[v] = 0
          for (i = 1; i <= n; i++) {
            if (!edge[i]) continue
            split(edge[i], e, " ")
            if (e[1] == v || e[2] == v) edge[i] = ""
          }
          removed = 1
        }
      }
    }
    for (v in node) if (node[v]) print v
  }
' | LC_ALL=C sort)
if [ -n "$cycle" ]; then
  printf 'layering: the production dependency graph has a cycle.\n'
  printf '%s\n' "$cycle" | sed 's/^/  in the cycle: /'
  printf '  Every layering rule here assumes a direction; a cycle means there\n'
  printf '  is none, and no snapshot can make one acceptable. Break it by\n'
  printf '  moving the shared code down to a package both sides may depend on.\n'
  fail=1
fi

# 6: the facade's own dependencies are the public surface it re-exports.
root_deps=$(printf '%s\n' "$edges" | sed -n 's/^root -> //p' | LC_ALL=C sort -u |
  tr '\n' ' ' | sed 's/ *$//')
expected_root=$(printf '%s\n' $public_packages | LC_ALL=C sort -u |
  tr '\n' ' ' | sed 's/ *$//')
if [ "$root_deps" != "$expected_root" ]; then
  report "the root facade imports [$root_deps]; expected exactly [$expected_root]"
fi

# 7: an internal type in a public interface is the leak, whatever the manifests
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
