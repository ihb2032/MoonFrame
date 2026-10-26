#!/bin/sh
# Version identity: the two places that name a release must agree.
#
#   moon.mod            version = "X.Y.Z"      what `moon add` installs
#   docs/migration.md   ## vA.B.C → vX.Y.Z     the newest upgrade target
#
# Nothing else names a release: the guides describe `main` and promise the
# facade surface, not a version, so a reader never has to reconcile two
# numbers. Both halves of that are checked — the two above must agree with
# each other, and the scan at the bottom of this file holds every other tracked
# piece of prose to naming no release at all. (Per-release history lives in
# the GitHub release notes, written when each release is cut, not tracked
# prose — so it is not a home this guard reads.)
#
# The migration document's newest heading carries both numbers that matter:
# the arrow's target is the release the docs describe, and the arrow's source
# is the version that *is* published. `moon.mod` may lag the target — a
# release is prepared on `main` before it is published — but only while the
# heading says so *explicitly*, by marking itself `(unreleased)`:
#
#   ## v0.6.0 → v0.7.0 (unreleased)
#
# While that marker is up, `moon.mod` must still publish the arrow's source
# (v0.6.0); with the marker gone, it must publish the target. Dropping the
# marker and bumping `moon.mod` is the release step; doing one without the
# other fails here. That is the point: an implicit mismatch is how a breaking
# API ships under the previous version's number.
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

# `## v0.6.0 → v0.7.0 (unreleased)` → target `0.7.0`, source `0.6.0`, marker.
# The heading pattern is any `## ` section (the file's h2s are version
# sections and nothing else); a first-release heading carries no source side
# (`## → v0.1.0`), which the extraction below reports as an empty string.
migration_heading=$(grep -m 1 '^## ' docs/migration.md || true)
migration_version=$(printf '%s\n' "$migration_heading" |
  sed -n 's/.*→ *v\([0-9][0-9.]*\).*/\1/p')
published_version=$(printf '%s\n' "$migration_heading" |
  sed -n 's/^## v\([0-9][0-9.]*\).*/\1/p')
case "$migration_heading" in
*'(unreleased)'*) unreleased=yes ;;
*) unreleased=no ;;
esac

for pair in "moon.mod:$mod_version" "docs/migration.md:$migration_version"; do
  case "$pair" in
  *:) note "could not read a version out of ${pair%:*}" ;;
  esac
done
[ "$fail" -eq 0 ] || { printf 'version identity: unreadable\n'; exit 1; }

if [ "$unreleased" = yes ]; then
  if [ "$mod_version" = "$migration_version" ]; then
    note "moon.mod is already v$mod_version — drop the (unreleased) marker from the migration heading"
  elif [ -z "$published_version" ]; then
    # No source side on the arrow: the first release, so there is no published
    # version to hold `moon.mod` to. Being different is all we can ask.
    printf 'version identity: v%s is the first release; moon.mod is v%s\n' \
      "$migration_version" "$mod_version"
  elif [ "$mod_version" != "$published_version" ]; then
    note "moon.mod is v$mod_version, but v$published_version is the published version the migration arrow names"
    note "while v$migration_version is unreleased, moon.mod must still publish v$published_version"
  fi
  printf 'version identity: docs describe v%s, marked unreleased; moon.mod publishes v%s\n' \
    "$migration_version" "$mod_version"
else
  if [ "$mod_version" != "$migration_version" ]; then
    note "moon.mod is v$mod_version but the docs describe v$migration_version"
    note "either bump moon.mod, or mark the migration heading '(unreleased)' while it is being prepared"
  fi
fi

# ── Nothing else names a release ──────────────────────────────────────────
# Comparing the two files enforces half of the rule. The other half — that
# there is no *third* place — is what keeps the reader from having two numbers
# to reconcile, and it is the half that used to be documentation only: a
# "MoonFrame v0.5.4" in a guide or a docstring broke the rule with nothing to
# say so, and went stale the moment the next release cut.
#
# Scope: tracked prose. Markdown, plus every line of the CI workflow and the
# package manifests (a release number misleads from a YAML comment as readily as
# from a docstring), plus comment lines in MoonBit sources — a *code* line there
# is not prose, and a string literal like "1.2.3" in a parser test is not a
# claim about anything. Minus:
#   docs/migration.md    the other home
#   .github/scripts/     these scripts quote the format
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
# A third-party version is not a release of this project, and each kind is
# masked by a `sed` expression binding the token to the version shape it
# introduces — the mask removes exactly the dependency's version, never the
# rest of the line: a sentence may carry both the language's version and
# this project's on one line, and only the former is exempt. Add a line
# here when a new dependency's version arrives, so the exclusion is a
# decision someone wrote down. One expression per kind:
#   - MOONBIT_INSTALL_VERSION / moonc — the pinned toolchain
#   - MoonBit v — the language, in prose
#   - uses: — a pinned action line, deleted whole: an action pin carries
#     its version in a SHA and a trailing comment, and nothing of this
#     project's rides one
#   - owner/pkg@ — a dependency
#   - UCD version — the Unicode Character Database edition
# `moon.mod`'s own `version = "…"` key needs no mask: the manifest is one of
# the two homes and is excluded from the scan set below, so a `version =`
# line anywhere else is exactly the stray this guard exists to catch — an
# earlier mask keyed on a leading colon silently exempted such a line
# wherever it appeared, because the colon came from the `grep -n` line
# number, not the line's content.
# The expressions are ERE (`sed -E`): a bare `+` is a quantifier here, not
# the literal it would be under BRE.
third_party_masks='
s/MOONBIT_INSTALL_VERSION[[:space:]:=]*"*[0-9][0-9a-zA-Z.+]*"*//g
s/moonc[[:space:]]+[0-9][0-9a-zA-Z.+]*//g
s/MoonBit[[:space:]]v[0-9.]+//g
/uses:[[:space:]]/d
s/[A-Za-z0-9_.-]+@[0-9.]+//g
s/UCD[[:space:]]version[[:space:]]*[0-9.]+//g
'

prose=$(git ls-files '*.md' |
  grep -v '^docs/migration\.md$' |
  grep -v '^\.github/scripts/' || true)
# `moon.mod` itself is excluded from `config`: it is one of the two homes,
# compared against the migration guide by this guard's first half — its own
# `version =` line is the fact being checked, not a stray to scan for.
config=$(git ls-files '*.yml' '*.yaml' 'moon.mod' '*moon.pkg' |
  grep -v '^moon\.mod$' |
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
  } | grep . | grep -v 'doc-guard: historical' |
    sed -E -e "$third_party_masks" | grep -E "$release_shape" || true
)
scanned=$(printf '%s\n%s\n%s\n' "$prose" "$config" "$sources" | grep -c . || true)

if [ -n "$stray" ]; then
  printf 'version identity: something other than the two homes names a release:\n'
  printf '%s\n' "$stray" | sed 's/^/  /'
  printf '  Only moon.mod and docs/migration.md name a release. Prose that\n'
  printf '  names one goes stale at the next one and leaves the reader two\n'
  printf '  numbers to reconcile, so describe `main` and the facade surface\n'
  printf '  instead. A line about a past release takes\n'
  printf '  `doc-guard: historical`; a third-party version needs a line in this\n'
  printf '  script'"'"'s `third_party` list.\n'
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  printf 'version identity: inconsistent\n'
  exit 1
fi
printf 'version identity: consistent (v%s); no release named outside the two homes in %s tracked files\n' \
  "$migration_version" "$scanned"
