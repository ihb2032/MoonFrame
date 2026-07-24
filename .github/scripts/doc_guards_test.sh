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
  mkdir -p "$1/docs"
  printf 'name = "x"\n\nversion = "%s"\n' "$2" >"$1/moon.mod"
  printf '# MoonFrame v%s — Public API\n' "$3" >"$1/docs/api.md"
  printf '# Changelog\n\n%s\n' "$4" >"$1/docs/changelog.md"
  printf '# Migration\n\n## v0.0.0 → v%s\n' "$5" >"$1/docs/migration.md"
}

mkfixture "$work/v_released" 0.6.0 0.6 '## v0.6.0 — done' 0.6.0
expect 0 'version: released and consistent' \
  sh "$scripts/check_version_identity.sh" "$work/v_released"

mkfixture "$work/v_unreleased" 0.5.8 0.6 '## v0.6.0 — done (unreleased)' 0.6.0
expect 0 'version: unreleased, moon.mod lagging on purpose' \
  sh "$scripts/check_version_identity.sh" "$work/v_unreleased"

mkfixture "$work/v_silent" 0.5.8 0.6 '## v0.6.0 — done' 0.6.0
expect 1 'version: moon.mod lagging with no marker' \
  sh "$scripts/check_version_identity.sh" "$work/v_silent"

mkfixture "$work/v_stale_marker" 0.6.0 0.6 '## v0.6.0 — done (unreleased)' 0.6.0
expect 1 'version: published but still marked unreleased' \
  sh "$scripts/check_version_identity.sh" "$work/v_stale_marker"

mkfixture "$work/v_api" 0.6.0 0.5 '## v0.6.0 — done' 0.6.0
expect 1 'version: api.md on another series' \
  sh "$scripts/check_version_identity.sh" "$work/v_api"

mkfixture "$work/v_migration" 0.6.0 0.6 '## v0.6.0 — done' 0.5.9
expect 1 'version: migration targets another release' \
  sh "$scripts/check_version_identity.sh" "$work/v_migration"

# ── facade docs ───────────────────────────────────────────────────────────
mkfacade() {
  # mkfacade <dir> <mbti-body> <doc-list>
  mkdir -p "$1/docs"
  printf '%s\n' "$2" >"$1/pkg.generated.mbti"
  printf '# Doc\n\n%s\n\ntail\n' "$3" >"$1/docs/api.md"
}
mbti='pub fn col(String) -> @expr.Expr
pub using @types {type Scalar}
pub using @expr {type Expr}'

mkfacade "$work/f_ok" "$mbti" '- From `@types`: `Scalar`
- From `@expr`: `Expr` · `col`'
expect 0 'facade: complete list' sh "$scripts/check_facade_docs.sh" "$work/f_ok"

mkfacade "$work/f_missing_type" "$mbti" '- From `@types`: `Scalar`
- From `@expr`: `col`'
expect 1 'facade: type re-exported but undocumented' \
  sh "$scripts/check_facade_docs.sh" "$work/f_missing_type"

mkfacade "$work/f_missing_fn" "$mbti" '- From `@types`: `Scalar`
- From `@expr`: `Expr`'
expect 1 'facade: free function re-exported but undocumented' \
  sh "$scripts/check_facade_docs.sh" "$work/f_missing_fn"

mkfacade "$work/f_moved" "$mbti" '- From `@expr`: `Scalar` · `Expr` · `col`'
expect 1 'facade: type documented under the wrong package' \
  sh "$scripts/check_facade_docs.sh" "$work/f_moved"

mkfacade "$work/f_ghost" "$mbti" '- From `@types`: `Scalar` · `Ghost`
- From `@expr`: `Expr` · `col`'
expect 1 'facade: documented symbol no longer re-exported' \
  sh "$scripts/check_facade_docs.sh" "$work/f_ghost"

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

# ── the repository itself ─────────────────────────────────────────────────
expect 0 'repo: version identity' sh "$scripts/check_version_identity.sh" "$root"
expect 0 'repo: facade docs' sh "$scripts/check_facade_docs.sh" "$root"
expect 0 'repo: stale names' sh "$scripts/check_stale_names.sh" "$root"

printf 'doc guards: %s cases pass\n' "$cases"
