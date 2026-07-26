#!/bin/sh
# Internal-package manifest guard. The `internal/` packages have no public
# surface, so nothing else in this workflow notices when one appears, moves, or
# disappears: `moon info` regenerates an interface no downstream module can
# import, the facade and enum locks skip them by design, and the stale-name
# guard only knows the identifiers it was told about. What is left is prose —
# and prose is where "which package does this code belong in?" is actually
# answered.
#
# So this pins the one thing that must not drift: the set of internal packages
# on disk equals the set the architecture docs describe. README's
# repository-structure block lists each one with its job; `docs/api.md` names
# them where it explains why they carry no compatibility promise. Adding a
# package without saying what belongs in it — the drift that let vectorized
# execution live in two places at once — fails here.
#
# Usage: .github/scripts/check_internal_packages.sh [repo-root]
# Exit 0 when the docs and the tree agree, 1 on drift.

set -eu

root="${1:-.}"
cd "$root"

# On disk: one `internal/<name>` per build manifest. `git ls-files` never lists
# a `_build` copy, so this is the tracked set.
disk=$(git ls-files 'internal/*/moon.pkg' | sed 's#/moon\.pkg$##' | LC_ALL=C sort)

# In README: the repository-structure block lists a package at line start,
# `internal/<name>/` followed by its description. A mention inside prose or a
# layering diagram is indented, so only the inventory counts.
readme=$(sed -n 's#^\(internal/[a-z_]*\)/[ \t].*#\1#p' README.md |
  LC_ALL=C sort -u)

# In api.md: named inline, in the paragraph that explains the module boundary.
# The bare `internal/` path prefix — how that paragraph refers to the boundary
# itself — is not a package name, so a name character is required.
api=$(grep -o 'internal/[a-z_][a-z_]*' docs/api.md | LC_ALL=C sort -u)

fail=0
report() {
  # report <message> <package>
  printf 'internal packages: %s: %s\n' "$1" "$2"
  fail=1
}

for pkg in $disk; do
  printf '%s\n' "$readme" | grep -qx "$pkg" ||
    report "on disk but missing from README's repository-structure block" "$pkg"
  printf '%s\n' "$api" | grep -qx "$pkg" ||
    report "on disk but missing from docs/api.md" "$pkg"
done

for pkg in $readme; do
  printf '%s\n' "$disk" | grep -qx "$pkg" ||
    report "listed in README but no longer on disk" "$pkg"
done

for pkg in $api; do
  printf '%s\n' "$disk" | grep -qx "$pkg" ||
    report "named in docs/api.md but no longer on disk" "$pkg"
done

if [ "$fail" -ne 0 ]; then
  printf '  The architecture docs and the tree disagree. An internal package\n'
  printf '  is where a whole class of work is supposed to live, so a package\n'
  printf '  the docs never mention gets bypassed: the next contributor puts\n'
  printf '  the code back in the package it was extracted from. Update the\n'
  printf "  README structure block and docs/api.md, or delete the stale name.\n"
  exit 1
fi

printf 'internal packages: %s documented in README and docs/api.md\n' \
  "$(printf '%s\n' "$disk" | grep -c 'internal/')"
