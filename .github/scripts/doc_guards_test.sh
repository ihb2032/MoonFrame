#!/bin/sh
# Self-test for the documentation guards. A guard that cannot fail is worse
# than no guard — it reads as a passing check while nothing is verified — so
# each one is run here against fixtures that must trip it, and against the
# repository itself, which must stay clean.
#
# Usage: .github/scripts/doc_guards_test.sh [repo-root]
# Exit 0 when every case behaves, 1 on the first that does not.

set -eu

root=$(cd "${1:-.}" && pwd)
scripts="$root/.github/scripts"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

cases=0
expect() {
  # expect <want-exit> <label> <command…>
  want=$1
  label=$2
  shift 2
  got=0
  "$@" >"$work/out" 2>&1 || got=$?
  cases=$((cases + 1))
  if [ "$got" -ne "$want" ]; then
    printf 'FAIL %s: expected exit %s, got %s\n' "$label" "$want" "$got"
    sed 's/^/     /' "$work/out"
    exit 1
  fi
}

# ── version identity ──────────────────────────────────────────────────────
mkfixture() {
  # mkfixture <dir> <mod-version> <api-version> <changelog-heading> <migration-target>
  # The changelog always carries a published v0.5.8 section below the newest
  # one, as the real file does — that is what `moon.mod` is held to while the
  # newest release is being prepared.
  mkdir -p "$1/docs"
  printf 'name = "x"\n\nversion = "%s"\n' "$2" >"$1/moon.mod"
  printf '# MoonFrame v%s — Public API\n' "$3" >"$1/docs/api.md"
  printf '# Changelog\n\n%s\n\nbody\n\n## v0.5.8 — before\n' "$4" >"$1/docs/changelog.md"
  printf '# Migration\n\n## v0.0.0 → v%s\n' "$5" >"$1/docs/migration.md"
}

mkfixture "$work/v_released" 0.6.0 0.6 '## v0.6.0 — done' 0.6.0
expect 0 'version: released and consistent' \
  sh "$scripts/check_version_identity.sh" "$work/v_released"

mkfixture "$work/v_unreleased" 0.5.8 0.6 '## v0.6.0 — done (unreleased)' 0.6.0
expect 0 'version: unreleased, moon.mod still on the published version' \
  sh "$scripts/check_version_identity.sh" "$work/v_unreleased"

mkfixture "$work/v_silent" 0.5.8 0.6 '## v0.6.0 — done' 0.6.0
expect 1 'version: moon.mod lagging with no marker' \
  sh "$scripts/check_version_identity.sh" "$work/v_silent"

mkfixture "$work/v_stale_marker" 0.6.0 0.6 '## v0.6.0 — done (unreleased)' 0.6.0
expect 1 'version: published but still marked unreleased' \
  sh "$scripts/check_version_identity.sh" "$work/v_stale_marker"

# The false negative an equality check alone leaves open: `moon.mod` naming a
# version that is neither the release being prepared nor the one published.
mkfixture "$work/v_unreleased_ahead" 9.9.9 0.6 '## v0.6.0 — done (unreleased)' 0.6.0
expect 1 'version: unreleased, moon.mod ahead of the release being prepared' \
  sh "$scripts/check_version_identity.sh" "$work/v_unreleased_ahead"

mkfixture "$work/v_unreleased_behind" 0.5.7 0.6 '## v0.6.0 — done (unreleased)' 0.6.0
expect 1 'version: unreleased, moon.mod behind the published version' \
  sh "$scripts/check_version_identity.sh" "$work/v_unreleased_behind"

# First release: nothing published below it, so there is no version to hold
# `moon.mod` to.
mkdir -p "$work/v_first/docs"
printf 'name = "x"\n\nversion = "0.0.0"\n' >"$work/v_first/moon.mod"
printf '# MoonFrame v0.1 — Public API\n' >"$work/v_first/docs/api.md"
printf '# Changelog\n\n## v0.1.0 — first (unreleased)\n' >"$work/v_first/docs/changelog.md"
printf '# Migration\n\n## v0.0.0 → v0.1.0\n' >"$work/v_first/docs/migration.md"
expect 0 'version: first release has no published predecessor' \
  sh "$scripts/check_version_identity.sh" "$work/v_first"

mkfixture "$work/v_api" 0.6.0 0.5 '## v0.6.0 — done' 0.6.0
expect 1 'version: api.md on another series' \
  sh "$scripts/check_version_identity.sh" "$work/v_api"

mkfixture "$work/v_migration" 0.6.0 0.6 '## v0.6.0 — done' 0.5.9
expect 1 'version: migration targets another release' \
  sh "$scripts/check_version_identity.sh" "$work/v_migration"

# ── stale names ───────────────────────────────────────────────────────────
mkstale() {
  # mkstale <dir> <file> <content>
  mkdir -p "$1/docs"
  (cd "$1" && git init -q . && git config user.email t@t &&
    git config user.name t && git config core.autocrlf false)
  printf '%s\n' "$3" >"$1/$2"
  (cd "$1" && git add -A && git commit -qm f)
}

mkstale "$work/s_clean" README.md 'Build with `DataFrame::DataFrame([])`.'
expect 0 'stale: clean tree' sh "$scripts/check_stale_names.sh" "$work/s_clean"

mkstale "$work/s_dirty" README.md 'Build with `DataFrame::new([])`.'
expect 1 'stale: removed name in prose' \
  sh "$scripts/check_stale_names.sh" "$work/s_dirty"

mkstale "$work/s_marked" README.md 'It replaced `DataFrame::new`. doc-guard: historical'
expect 0 'stale: removed name behind the historical marker' \
  sh "$scripts/check_stale_names.sh" "$work/s_marked"

mkstale "$work/s_history" docs/changelog.md '`DataFrame::new` is gone.'
expect 0 'stale: changelog is exempt' \
  sh "$scripts/check_stale_names.sh" "$work/s_history"

# ── enum surface ──────────────────────────────────────────────────────────
mkenum() {
  # mkenum <dir> <mbti-path> <mbti-body> <snapshot-body|-->
  # `--` as the snapshot writes no snapshot file (the missing-snapshot case).
  mkdir -p "$1/$(dirname "$2")" "$1/.github/scripts"
  (cd "$1" && git init -q . && git config user.email t@t &&
    git config user.name t && git config core.autocrlf false)
  printf '%s\n' "$3" >"$1/$2"
  if [ "$4" != "--" ]; then
    printf '%s\n' "$4" >"$1/.github/scripts/enum_surface.snapshot"
  fi
  (cd "$1" && git add -A && git commit -qm f)
}

enum_mbti='pub(all) enum Color {
  Red
  Green
} derive(Eq)'
# The extracted surface is sorted, so Green precedes Red.
enum_snap='Color | enum | Green
Color | enum | Red'

mkenum "$work/e_ok" types/pkg.generated.mbti "$enum_mbti" "$enum_snap"
expect 0 'enum: surface matches the snapshot' \
  sh "$scripts/check_enum_surface.sh" "$work/e_ok"

mkenum "$work/e_added" types/pkg.generated.mbti 'pub(all) enum Color {
  Red
  Green
  Blue
} derive(Eq)' "$enum_snap"
expect 1 'enum: a variant added since the snapshot' \
  sh "$scripts/check_enum_surface.sh" "$work/e_added"

mkenum "$work/e_removed" types/pkg.generated.mbti 'pub(all) enum Color {
  Red
} derive(Eq)' "$enum_snap"
expect 1 'enum: a variant removed since the snapshot' \
  sh "$scripts/check_enum_surface.sh" "$work/e_removed"

mkenum "$work/e_missing" types/pkg.generated.mbti "$enum_mbti" --
expect 1 'enum: snapshot absent' \
  sh "$scripts/check_enum_surface.sh" "$work/e_missing"

# A plain `pub enum` exposes no variants, and an `internal/` package carries no
# promise — neither is locked, so both leave an empty surface matching an empty
# snapshot.
mkenum "$work/e_internal" internal/col/pkg.generated.mbti "$enum_mbti" ''
expect 0 'enum: internal packages are not locked' \
  sh "$scripts/check_enum_surface.sh" "$work/e_internal"

mkenum "$work/e_opaque" types/pkg.generated.mbti 'pub enum Color {
  Red
  Green
}' ''
expect 0 'enum: a plain pub enum is not matchable, so not locked' \
  sh "$scripts/check_enum_surface.sh" "$work/e_opaque"

# ── the repository itself ─────────────────────────────────────────────────
expect 0 'repo: version identity' sh "$scripts/check_version_identity.sh" "$root"
expect 0 'repo: stale names' sh "$scripts/check_stale_names.sh" "$root"
expect 0 'repo: enum surface' sh "$scripts/check_enum_surface.sh" "$root"

printf 'doc guards: %s cases pass\n' "$cases"
