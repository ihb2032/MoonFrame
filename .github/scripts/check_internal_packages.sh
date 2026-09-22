#!/bin/sh
# Internal-package manifest guard. The `internal/` packages have no public
# surface, so almost nothing else in this workflow notices when one appears,
# moves, or disappears: `moon info` regenerates an interface no downstream module
# can import, the facade and enum locks skip them by design, and the stale-name
# guard only knows the identifiers it was told about. The one that does notice is
# `check_layering.sh`, which fails a new package with no declared dependency set
# and pins the edge list — but it sees the graph, not the prose. What is left is
# and prose is where "which package does this code belong in?" is actually
# answered.
#
# So this pins one thing, exactly: the set of internal package *names* on disk
# equals the set the architecture doc names. README's repository-structure
# block lists each one with its job. Adding a package without listing it —
# the drift that left the package map describing the architecture
# the kernel extraction replaced — fails here.
#
# What it does not check: whether those descriptions are *accurate*, or which
# way the imports run.
# The last of those is `check_layering.sh`, which reads the manifests; the
# first two are review's job, since no guard can read intent out of a sentence.
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
# `internal/<name>/` followed by its description. The trailing `/` is what makes
# it an inventory line: prose and the layering diagram name a package without
# one, so only the inventory counts. The README is the tested single source
# `README.mbt.md`; `README.md` is a symlink to it, which a checkout without
# symlink support (core.symlinks=false, the Windows default) materialises as a
# one-line pointer — follow that pointer so the guard reads the real file
# either way.
readme_file=README.md
if [ "$(cat README.md)" = "README.mbt.md" ]; then
  readme_file=README.mbt.md
fi
readme=$(sed -n 's#^\(internal/[a-z_]*\)/[ \t].*#\1#p' "$readme_file" |
  LC_ALL=C sort -u)

fail=0
report() {
  # report <message> <package>
  printf 'internal packages: %s: %s\n' "$1" "$2"
  fail=1
}

for pkg in $disk; do
  printf '%s\n' "$readme" | grep -qx "$pkg" ||
    report "on disk but missing from README's repository-structure block" "$pkg"
done

for pkg in $readme; do
  printf '%s\n' "$disk" | grep -qx "$pkg" ||
    report "listed in README but no longer on disk" "$pkg"
done

if [ "$fail" -ne 0 ]; then
  printf '  The architecture doc and the tree disagree. An internal package\n'
  printf '  is where a whole class of work is supposed to live, so a package\n'
  printf '  the doc never mentions gets bypassed: the next contributor puts\n'
  printf '  the code back in the package it was extracted from. Update the\n'
  printf "  README structure block, or delete the stale name.\n"
  exit 1
fi

printf 'internal packages: %s documented in the README structure block\n' \
  "$(printf '%s\n' "$disk" | grep -c 'internal/')"
