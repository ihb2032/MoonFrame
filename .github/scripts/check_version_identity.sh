#!/bin/sh
# Version identity: the three places that name a release must agree.
#
#   moon.mod            version = "X.Y.Z"      what `moon add` installs
#   docs/changelog.md   ## vX.Y.Z — …          the newest entry
#   docs/migration.md   ## vA.B.C → vX.Y.Z     the newest upgrade target
#
# Nothing else names a release: the guides describe `main` and promise the
# facade surface, not a version, so a reader never has to reconcile two
# numbers. Both halves of that are checked — the three above must agree with
# each other, and the scan at the bottom of this file holds every other tracked
# piece of prose to naming no release at all.
#
# The two history documents must always agree with each other. `moon.mod` may lag
# them — a release is prepared on `main` before it is published — but only
# while the changelog says so *explicitly*, by marking its newest heading
# `(unreleased)`:
#
#   ## v0.6.0 — API convergence (unreleased)
#
# Dropping that marker and bumping `moon.mod` is the release step; doing one
# without the other fails here. That is the point: an implicit mismatch is how
# a breaking API ships under the previous version's number.
#
# Usage: .github/scripts/check_version_identity.sh [repo-root]
# Exit 0 when consistent, 1 otherwise (every problem is printed, not just the
# first). The root must be a git work tree: the scan reads its file list from
# `git ls-files`, and a guard that skipped it must not report success.

set -eu

root="${1:-.}"
cd "$root"

fail=0
note() {
  printf '  %s\n' "$1"
  fail=1
}

# `version = "0.6.0"` → `0.6.0`
mod_version=$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' moon.mod | head -n 1)

# `## v0.6.0 — API convergence (unreleased)` → `0.6.0`, plus the marker.
changelog_heading=$(grep -m 1 '^## v' docs/changelog.md || true)
changelog_version=$(printf '%s\n' "$changelog_heading" |
  sed -n 's/^## v\([0-9][0-9.]*\).*/\1/p')
case "$changelog_heading" in
*'(unreleased)'*) unreleased=yes ;;
*) unreleased=no ;;
esac

# The heading below the newest one: the version that *is* published. Releases
# here are linear — one section per release, newest first — so "the previous
# entry" is exactly what `moon.mod` should still say while the newest is being
# prepared. Comparing against it beats ordering two version strings in POSIX
# shell, and it rejects a `moon.mod` that has run *ahead* of the release being
# prepared, which an inequality check alone would wave through.
previous_version=$(grep '^## v' docs/changelog.md | sed -n '2p' |
  sed -n 's/^## v\([0-9][0-9.]*\).*/\1/p')

# `## v0.5.8 → v0.6.0` → `0.6.0` (the target side).
migration_version=$(grep -m 1 '^## v' docs/migration.md |
  sed -n 's/.*→ *v\([0-9][0-9.]*\).*/\1/p')

for pair in "moon.mod:$mod_version" \
  "docs/changelog.md:$changelog_version" "docs/migration.md:$migration_version"; do
  case "$pair" in
  *:) note "could not read a version out of ${pair%:*}" ;;
  esac
done
[ "$fail" -eq 0 ] || { printf 'version identity: unreadable\n'; exit 1; }

# The documents describe one release, whatever `moon.mod` says.
if [ "$changelog_version" != "$migration_version" ]; then
  note "changelog is at v$changelog_version but migration upgrades to v$migration_version"
fi
if [ "$unreleased" = yes ]; then
  if [ "$mod_version" = "$changelog_version" ]; then
    note "moon.mod is already v$mod_version — drop the (unreleased) marker from the changelog heading"
  elif [ -z "$previous_version" ]; then
    # No section below the newest: this is the first release, so there is no
    # published version to hold `moon.mod` to. Being different is all we can ask.
    printf 'version identity: v%s is the first release; moon.mod is v%s\n' \
      "$changelog_version" "$mod_version"
  elif [ "$mod_version" != "$previous_version" ]; then
    note "moon.mod is v$mod_version, but v$previous_version is the released version the changelog names below v$changelog_version"
    note "while v$changelog_version is unreleased, moon.mod must still publish v$previous_version"
  fi
  printf 'version identity: docs describe v%s, marked unreleased; moon.mod publishes v%s\n' \
    "$changelog_version" "$mod_version"
else
  if [ "$mod_version" != "$changelog_version" ]; then
    note "moon.mod is v$mod_version but the docs describe v$changelog_version"
    note "either bump moon.mod, or mark the changelog heading '(unreleased)' while it is being prepared"
  fi
fi

# ── Nothing else names a release ──────────────────────────────────────────
# Comparing the three files enforces half of the rule. The other half — that
# there is no *fourth* place — is what keeps the reader from having two numbers
# to reconcile, and it is the half that used to be documentation only: a
# "MoonFrame v0.5.4" in a guide or a docstring broke the rule with nothing to
# say so, and went stale the moment the next release cut.
#
# Scope: tracked prose. Markdown, plus every line of the CI workflow and the
# package manifests (a release number misleads from a YAML comment as readily as
# from a docstring), plus comment lines in MoonBit sources — a *code* line there
# is not prose, and a string literal like "1.2.3" in a parser test is not a
# claim about anything. Minus:
#   docs/changelog.md, docs/migration.md   two of the three homes
#   .github/scripts/                       these scripts quote the format
#
# A third-party version is not a release of this project, and each kind is
# recognised by a token the line already carries — see `third_party` below. Add
# a line there when a new dependency's version arrives, so the exclusion is a
# decision someone wrote down. A line that must name a *past* release of this
# project takes the shared `doc-guard: historical` marker.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'version identity: no work tree — the release-name scan cannot run\n'
  exit 1
fi

release_shape='v?[0-9]+\.[0-9]+\.[0-9]+'
# One per line: `regex # why`. The reason is stripped at the `#`, which no
# pattern contains — a whitespace split would eat the `v` of `MoonBit v` and the
# `historical` of the marker, quietly widening both.
third_party='MOONBIT_INSTALL_VERSION|moonc  # the pinned toolchain
MoonBit v               # the language, in prose
uses:                   # a pinned action, versioned in a trailing comment
/[A-Za-z0-9_.-]+@[0-9]  # a dependency, `owner/pkg@X.Y.Z`
:version = "            # the manifest key itself, on its own line
doc-guard: historical    # a deliberate reference to a past release'
exclude=$(printf '%s\n' "$third_party" | sed 's/[[:space:]]*#.*$//' | grep . |
  tr '\n' '|' | sed 's/|$//')

prose=$(git ls-files '*.md' |
  grep -vE '^docs/(changelog|migration)\.md$' |
  grep -v '^\.github/scripts/' || true)
config=$(git ls-files '*.yml' '*.yaml' 'moon.mod' '*moon.pkg' |
  grep -v '^\.github/scripts/' || true)
sources=$(git ls-files '*.mbt' | grep -v '^\.github/scripts/' || true)

# `|| true` on every filter: a `grep` that matches nothing exits 1, which
# `set -e` would turn into a silent failure of the guard rather than a clean run.
scan() {
  # scan <newline-separated files> <line-pattern>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | tr '\n' '\0' |
    xargs -0 grep -nE "$2" 2>/dev/null || true
}
stray=$(
  {
    scan "$prose" "$release_shape"
    scan "$config" "$release_shape"
    scan "$sources" "^[[:space:]]*(///|//).*$release_shape"
  } | grep . | grep -vE "$exclude" || true
)
scanned=$(printf '%s\n%s\n%s\n' "$prose" "$config" "$sources" | grep -c . || true)

if [ -n "$stray" ]; then
  printf 'version identity: something other than the three homes names a release:\n'
  printf '%s\n' "$stray" | sed 's/^/  /'
  printf '  Only moon.mod, docs/changelog.md and docs/migration.md name a\n'
  printf '  release. Prose that names one goes stale at the next one and leaves\n'
  printf '  the reader two numbers to reconcile, so describe `main` and the\n'
  printf '  facade surface instead. A line about a past release takes\n'
  printf '  `doc-guard: historical`; a third-party version needs a line in this\n'
  printf '  script'"'"'s `third_party` list.\n'
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  printf 'version identity: inconsistent\n'
  exit 1
fi
printf 'version identity: consistent (v%s); no release named outside the three homes in %s tracked files\n' \
  "$changelog_version" "$scanned"
