#!/bin/sh
# Version identity: the four places that name a release must agree.
#
#   moon.mod            version = "X.Y.Z"      what `moon add` installs
#   docs/api.md         # MoonFrame vX.Y — …   what the reference describes
#   docs/changelog.md   ## vX.Y.Z — …          the newest entry
#   docs/migration.md   ## vA.B.C → vX.Y.Z     the newest upgrade target
#
# The three documents must always agree with each other. `moon.mod` may lag
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
# first).

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

# `# MoonFrame v0.6 — Public API` → `0.6` (the reference names a minor series,
# not a patch, so it is compared as a prefix).
api_version=$(sed -n 's/^# MoonFrame v\([0-9][0-9.]*\).*/\1/p' docs/api.md | head -n 1)

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

for pair in "moon.mod:$mod_version" "docs/api.md:$api_version" \
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
# api.md names the minor series (v0.6), the others the full version (v0.6.0).
case "$changelog_version" in
"$api_version" | "$api_version".*) ;;
*) note "api.md documents v$api_version but the changelog is at v$changelog_version" ;;
esac

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

if [ "$fail" -ne 0 ]; then
  printf 'version identity: inconsistent\n'
  exit 1
fi
printf 'version identity: consistent (v%s)\n' "$changelog_version"
