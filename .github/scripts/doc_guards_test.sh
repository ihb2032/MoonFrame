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

expect_out() {
  # expect_out <want-exit> <substring> <label> <command…>
  # For guards that check several things: an exit code alone cannot tell which
  # one fired, and a case that passes for the wrong reason is a case that has
  # stopped testing anything.
  want=$1
  needle=$2
  label=$3
  shift 3
  got=0
  "$@" >"$work/out" 2>&1 || got=$?
  cases=$((cases + 1))
  if [ "$got" -ne "$want" ] || ! grep -qF -- "$needle" "$work/out"; then
    printf 'FAIL %s: expected exit %s mentioning "%s", got %s\n' \
      "$label" "$want" "$needle" "$got"
    sed 's/^/     /' "$work/out"
    exit 1
  fi
}

# ── version identity ──────────────────────────────────────────────────────
mkfixture() {
  # mkfixture <dir> <mod-version> <api-version> <changelog-heading> <migration-target> [readme]
  # The changelog always carries a published v0.5.8 section below the newest
  # one, as the real file does — that is what `moon.mod` is held to while the
  # newest release is being prepared. Without an explicit README the fixture
  # gets the one its state calls for: the version-channel notice while the
  # newest release is unreleased, and no notice once it ships.
  mkdir -p "$1/docs"
  printf 'name = "x"\n\nversion = "%s"\n' "$2" >"$1/moon.mod"
  printf '# MoonFrame v%s — Public API\n' "$3" >"$1/docs/api.md"
  # Every entry point carries the notice while the newest release is
  # unreleased, so a fixture that varies README varies only README.
  case "$4" in
  *'(unreleased)'*)
    printf 'Documents the unreleased v%s API; moon add installs v%s.\n' \
      "$3" "$2" >>"$1/docs/api.md"
    ;;
  esac
  printf '# Changelog\n\n%s\n\nbody\n\n## v0.5.8 — before\n' "$4" >"$1/docs/changelog.md"
  printf '# Migration\n\n## v0.0.0 → v%s\n' "$5" >"$1/docs/migration.md"
  if [ $# -ge 6 ]; then
    printf '%s\n' "$6" >"$1/README.md"
  else
    case "$4" in
    *'(unreleased)'*)
      printf 'This page documents the unreleased v%s API; moon add installs v%s.\n' \
        "$3" "$2" >"$1/README.md"
      ;;
    *) printf '# x\n' >"$1/README.md" ;;
    esac
  fi
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
printf '# MoonFrame v0.1 — Public API\n\nDocuments the unreleased v0.1 API; moon add installs v0.0.0.\n' \
  >"$work/v_first/docs/api.md"
printf '# Changelog\n\n## v0.1.0 — first (unreleased)\n' >"$work/v_first/docs/changelog.md"
printf '# Migration\n\n## v0.0.0 → v0.1.0\n' >"$work/v_first/docs/migration.md"
printf 'Documents the unreleased v0.1 API; moon add installs v0.0.0.\n' \
  >"$work/v_first/README.md"
expect 0 'version: first release has no published predecessor' \
  sh "$scripts/check_version_identity.sh" "$work/v_first"

mkfixture "$work/v_api" 0.6.0 0.5 '## v0.6.0 — done' 0.6.0
expect 1 'version: api.md on another series' \
  sh "$scripts/check_version_identity.sh" "$work/v_api"

mkfixture "$work/v_migration" 0.6.0 0.6 '## v0.6.0 — done' 0.5.9
expect 1 'version: migration targets another release' \
  sh "$scripts/check_version_identity.sh" "$work/v_migration"

# README is the page that says `moon add`, and while the docs run ahead of the
# published release that command installs something else — so the notice is
# required exactly while the newest release is unreleased, and forbidden after.
mkfixture "$work/v_no_notice" 0.5.8 0.6 '## v0.6.0 — done (unreleased)' 0.6.0 \
  '# MoonFrame

Install it with `moon add`.'
expect_out 1 'version-channel notice' 'version: README missing the unreleased notice' \
  sh "$scripts/check_version_identity.sh" "$work/v_no_notice"

mkfixture "$work/v_notice_wrong_version" 0.5.8 0.6 \
  '## v0.6.0 — done (unreleased)' 0.6.0 \
  'This page documents the unreleased v0.6 API; the published one is older.'
expect_out 1 'must name v0.5.8' 'version: notice does not name the published version' \
  sh "$scripts/check_version_identity.sh" "$work/v_notice_wrong_version"

mkfixture "$work/v_stale_notice" 0.6.0 0.6 '## v0.6.0 — done' 0.6.0 \
  'This page documents the unreleased v0.6 API; moon add installs v0.5.8.'
expect_out 1 'drop README' 'version: notice left behind after the release shipped' \
  sh "$scripts/check_version_identity.sh" "$work/v_stale_notice"

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

# ── facade surface ────────────────────────────────────────────────────────
mkfacadesurface() {
  # mkfacadesurface <dir> <root-mbti> <frame-mbti> <snapshot-body|--> [facade-source] [io-mbti]
  # `--` as the snapshot writes no snapshot file (the missing-snapshot case).
  # The guard reads every tracked public interface, so the fixture is a git
  # repository with a root facade and one public package — plus, when a case
  # needs a second one, an `io`. The facade *source* is read too, for which
  # package each re-exported free function comes from.
  mkdir -p "$1/.github/scripts" "$1/frame"
  (cd "$1" && git init -q . && git config user.email t@t &&
    git config user.name t && git config core.autocrlf false)
  printf '%s\n' "$2" >"$1/pkg.generated.mbti"
  printf '%s\n' "$3" >"$1/frame/pkg.generated.mbti"
  if [ "$4" != "--" ]; then
    printf '%s\n' "$4" >"$1/.github/scripts/facade_surface.snapshot"
  fi
  if [ $# -ge 5 ]; then
    printf '%s\n' "$5" >"$1/moonframe.mbt"
  else
    printf 'pub using @frame {type DataFrame, type HtmlOptions}\n' \
      >"$1/moonframe.mbt"
  fi
  if [ $# -ge 6 ]; then
    mkdir -p "$1/io"
    printf '%s\n' "$6" >"$1/io/pkg.generated.mbti"
  fi
  (cd "$1" && git add -A && git commit -qm f)
}

fs_root='#alias(column)
pub fn col(String) -> @expr.Expr
pub using @frame {type DataFrame}
pub using @frame {type HtmlOptions}'
# `DataFrame` is re-exported and `GroupedDataFrame` is not: the fluent-chain
# intermediate a caller reaches by chaining off `group_by`, never by name.
fs_frame='pub struct DataFrame {
  // private fields
} derive(Eq, @debug.Debug)
pub fn DataFrame::DataFrame(Array[@series.Series]) -> Self
pub fn DataFrame::filter(Self) -> Self
#alias(limit)
pub fn DataFrame::head(Self, Int) -> Self
pub impl Eq for DataFrame
pub struct GroupedDataFrame {
  // private fields
}
pub fn GroupedDataFrame::agg(Self) -> DataFrame
pub struct HtmlOptions {
  escape : Bool
} derive(Eq)'
# The extracted surface is sorted, so the kinds group alphabetically. Each
# callable carries its whole signature: a caller breaks on a parameter type, a
# return type, an optional parameter becoming required, or a `raise` appearing,
# and none of those changes a name.
fs_snap='alias DataFrame::limit <- frame
alias column <- root
ctor DataFrame::DataFrame(Array[@series.Series]) -> Self <- frame
field HtmlOptions.escape : Bool <- frame
fn col(String) -> @expr.Expr <- root
impl Eq for DataFrame <- frame
intermediate GroupedDataFrame <- frame
method DataFrame::filter(Self) -> Self <- frame
method DataFrame::head(Self, Int) -> Self <- frame
method GroupedDataFrame::agg(Self) -> DataFrame <- frame
type DataFrame <- frame
type HtmlOptions <- frame'

mkfacadesurface "$work/fs_ok" "$fs_root" "$fs_frame" "$fs_snap"
expect 0 'facade surface: matches the snapshot' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_ok"

# The gap a root-file-only lock left open: a method added to a re-exported
# type reaches callers as `@moonframe.DataFrame::debug_storage` while the
# facade's own free functions and type names are untouched.
mkfacadesurface "$work/fs_method" "$fs_root" "$fs_frame
pub fn DataFrame::debug_storage(Self) -> Int" "$fs_snap"
expect 1 'facade surface: a method added to a re-exported type' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_method"

mkfacadesurface "$work/fs_impl" "$fs_root" "$fs_frame
pub impl Show for DataFrame" "$fs_snap"
expect 1 'facade surface: a trait impl added to a re-exported type' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_impl"

# The four shapes a name-only lock waved through. Each keeps every symbol name
# in place and breaks a caller anyway.
mkfacadesurface "$work/fs_param" "$fs_root" \
  "$(printf '%s\n' "$fs_frame" | sed 's/head(Self, Int)/head(Self, Int64)/')" \
  "$fs_snap"
expect 1 'facade surface: a parameter type changed' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_param"

mkfacadesurface "$work/fs_return" "$fs_root" \
  "$(printf '%s\n' "$fs_frame" |
    sed 's/^pub fn DataFrame::filter(Self) -> Self$/pub fn DataFrame::filter(Self) -> GroupedDataFrame/')" \
  "$fs_snap"
expect 1 'facade surface: a return type changed' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_return"

mkfacadesurface "$work/fs_raise" "$fs_root" \
  "$(printf '%s\n' "$fs_frame" |
    sed 's/^pub fn DataFrame::filter(Self) -> Self$/pub fn DataFrame::filter(Self) -> Self raise @types.DataError/')" \
  "$fs_snap"
expect 1 'facade surface: a raise effect appeared' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_raise"

mkfacadesurface "$work/fs_field_type" "$fs_root" \
  "$(printf '%s\n' "$fs_frame" | sed 's/^  escape : Bool$/  escape : Bool?/')" \
  "$fs_snap"
expect 1 'facade surface: a public field type changed' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_field_type"

# A mutable container in a public field is refused outright, not snapshotted:
# the snapshot below lists it, and the rule fires anyway.
# A free function has no chain to be reached through, so one the facade omits
# is either unreachable through the supported surface or should not be `pub`.
mkfacadesurface "$work/fs_unexported_fn" "$fs_root" "$fs_frame
pub fn helper(String) -> Int" "$fs_snap
fn helper(String) -> Int <- frame"
expect_out 1 'helper (in frame)' \
  'facade surface: a package free function the facade does not re-export' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_unexported_fn"

# A public top-level value is reachable the same way a free function is, and
# invisible to the lock until the extractor knows the shape.
mkfacadesurface "$work/fs_value" "$fs_root" "$fs_frame
pub const MAX_ROWS : Int = 1000" "$fs_snap
value const MAX_ROWS : Int = 1000 <- frame"
expect_out 1 'MAX_ROWS (in frame)' \
  'facade surface: a public constant the facade does not re-export' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_value"

mkfacadesurface "$work/fs_value_mutable" "$fs_root" "$fs_frame
pub let DEFAULTS : Array[String] = []" "$fs_snap
value let DEFAULTS : Array[String] = [] <- frame" 'pub using @frame {type DataFrame, type HtmlOptions, DEFAULTS}'
expect_out 1 'holding a mutable container' \
  'facade surface: a public top-level value holding a mutable container' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_value_mutable"

# Both rules match on package *and* name. A bare-name rule would let a second
# package publish a symbol and ride on the facade entry that belongs to the
# first: `frame` growing its own `col`, or `io` its own `WhenThen`.
mkfacadesurface "$work/fs_fn_collision" "$fs_root" "$fs_frame
pub fn col(String) -> @expr.Expr" "$fs_snap
fn col(String) -> @expr.Expr <- frame" 'pub using @expr {col}
pub using @frame {type DataFrame, type HtmlOptions}'
expect_out 1 'col (in frame)' \
  'facade surface: a second package publishing a facade function name' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_fn_collision"

mkfacadesurface "$work/fs_type_collision" "$fs_root" "$fs_frame" "$fs_snap
intermediate WhenThen <- io
method WhenThen::then(Self) -> Self <- io" '' 'pub struct WhenThen {
  // private fields
}
pub fn WhenThen::then(Self) -> Self'
expect_out 1 'WhenThen (in io)' \
  'facade surface: an allowed intermediate name in the wrong package' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_type_collision"

mkfacadesurface "$work/fs_mutable_field" "$fs_root" \
  "$(printf '%s\n' "$fs_frame" |
    awk '{ print } /^  escape : Bool$/ { print "  classes : Array[String]" }')" \
  "$fs_snap
field HtmlOptions.classes : Array[String] <- frame"
expect_out 1 'field HtmlOptions.classes : Array[String]' \
  'facade surface: a public field holding a mutable array' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_mutable_field"

# The constructor case is the same shape, and the one most easily mistaken for
# additive: an optional parameter with a default becoming required.
mkfacadesurface "$work/fs_required" "$fs_root" \
  "$(printf '%s\n' "$fs_frame" |
    sed 's/^pub fn DataFrame::DataFrame(Array\[@series.Series\]) -> Self$/pub fn DataFrame::DataFrame(Array[@series.Series], strict : Bool) -> Self/')" \
  "$fs_snap"
expect 1 'facade surface: a constructor gained a required parameter' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_required"

mkfacadesurface "$work/fs_field" "$fs_root" \
  "$(printf '%s\n' "$fs_frame" |
    awk '{ print } /^  escape : Bool/ { print "  max_rows : Int?" }')" \
  "$fs_snap"
expect 1 'facade surface: a field added to a re-exported struct' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_field"

# An `#alias` is a second callable spelling, so dropping it retracts a name.
mkfacadesurface "$work/fs_alias" "$fs_root" \
  "$(printf '%s\n' "$fs_frame" | grep -v '^#alias')" "$fs_snap"
expect 1 'facade surface: a method alias dropped' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_alias"

# Reclassification, in both directions: a re-exported type demoted to a
# fluent-chain intermediate is as much a break as a new export.
mkfacadesurface "$work/fs_unexported" \
  "$(printf '%s\n' "$fs_root" | grep -v 'HtmlOptions')" "$fs_frame" "$fs_snap"
expect 1 'facade surface: a type no longer re-exported by the facade' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_unexported"

mkfacadesurface "$work/fs_removed" \
  "$(printf '%s\n' "$fs_root" | grep -v -e 'pub fn col' -e '^#alias')" \
  "$fs_frame" "$fs_snap"
expect 1 'facade surface: a free function removed since the snapshot' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_removed"

mkfacadesurface "$work/fs_moved" \
  "$(printf '%s\n' "$fs_root" | sed 's/@frame {type DataFrame}/@lazy {type DataFrame}/')" \
  "$fs_frame" "$fs_snap"
expect 1 'facade surface: a type changed source package' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_moved"

mkfacadesurface "$work/fs_missing" "$fs_root" "$fs_frame" --
expect 1 'facade surface: snapshot absent' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_missing"

# The allowlist is checked ahead of the snapshot, so a leaked public type fails
# even once someone has regenerated the snapshot over it — which is exactly the
# hole a regenerable-everything lock leaves.
mkfacadesurface "$work/fs_leak" "$fs_root" "$fs_frame
pub struct LeakedHelper {
  // private fields
}
pub fn LeakedHelper::run(Self) -> Int" "$fs_snap
intermediate LeakedHelper <- frame
method LeakedHelper::run <- frame"
expect 1 'facade surface: a public type outside the intermediate allowlist' \
  sh "$scripts/check_facade_surface.sh" "$work/fs_leak"

# ── internal package manifest ─────────────────────────────────────────────
mkinternal() {
  # mkinternal <dir> <disk-packages> <readme-body> <api-body>
  # `<disk-packages>` is a space-separated list of `internal/<name>` packages
  # to create, each as a bare build manifest.
  mkdir -p "$1/docs"
  (cd "$1" && git init -q . && git config user.email t@t &&
    git config user.name t && git config core.autocrlf false)
  for pkg in $2; do
    mkdir -p "$1/internal/$pkg"
    printf 'import {}\n' >"$1/internal/$pkg/moon.pkg"
  done
  printf '%s\n' "$3" >"$1/README.md"
  printf '%s\n' "$4" >"$1/docs/api.md"
  (cd "$1" && git add -A && git commit -qm f)
}

ip_readme='types/      value types
internal/column/   Arrow-style storage
internal/kernel/   vectorized expression kernels'
ip_api='Storage (`internal/column`) and the expression kernels
(`internal/kernel`) live in module-internal packages a downstream module
cannot import at all.'

mkinternal "$work/ip_ok" "column kernel" "$ip_readme" "$ip_api"
expect 0 'internal packages: docs and tree agree' \
  sh "$scripts/check_internal_packages.sh" "$work/ip_ok"

# The drift this exists for: a package extracted without saying what belongs
# in it, so the docs still describe the architecture it replaced.
mkinternal "$work/ip_undocumented" "column kernel text" "$ip_readme" "$ip_api"
expect 1 'internal packages: a package the docs never mention' \
  sh "$scripts/check_internal_packages.sh" "$work/ip_undocumented"

mkinternal "$work/ip_readme_only" "column kernel" "$ip_readme" \
  'Storage (`internal/column`) lives in a module-internal package.'
expect 1 'internal packages: a package missing from docs/api.md' \
  sh "$scripts/check_internal_packages.sh" "$work/ip_readme_only"

mkinternal "$work/ip_stale" "column" "$ip_readme" "$ip_api"
expect 1 'internal packages: a documented package that no longer exists' \
  sh "$scripts/check_internal_packages.sh" "$work/ip_stale"

# ── production layering ───────────────────────────────────────────────────
mklayering() {
  # mklayering <dir> <frame-manifest> <internal-kernel-manifest> <root-manifest>
  # A miniature of the real graph: a root facade over six public packages, a
  # `series` that owns the column, and the two internal layers below it. The
  # edge snapshot is generated from the fixture itself — these cases are about
  # the *rules*, and a rule violation must fail before the snapshot is even
  # consulted, so writing one that matches proves exactly that.
  mkdir -p "$1"
  (cd "$1" && git init -q . && git config user.email t@t &&
    git config user.name t && git config core.autocrlf false)
  for pkg in expr io lazy types; do
    mkdir -p "$1/$pkg"
    # `types` is the bottom of the stack and depends on nothing in the module;
    # the rest sit on it.
    if [ "$pkg" = types ]; then
      printf 'import {\n}\n' >"$1/$pkg/moon.pkg"
    else
      printf 'import {\n  "ihb2032/MoonFrame/types",\n}\n' >"$1/$pkg/moon.pkg"
    fi
    printf 'package "ihb2032/MoonFrame/%s"\n' "$pkg" \
      >"$1/$pkg/pkg.generated.mbti"
  done
  mkdir -p "$1/series" "$1/frame" "$1/internal/column" "$1/internal/kernel"
  printf 'import {\n  "ihb2032/MoonFrame/internal/column",\n}\n' \
    >"$1/series/moon.pkg"
  printf 'import {\n  "ihb2032/MoonFrame/types",\n}\n' \
    >"$1/internal/column/moon.pkg"
  printf 'package "ihb2032/MoonFrame/series"\n' >"$1/series/pkg.generated.mbti"
  printf '%s\n' "$2" >"$1/frame/moon.pkg"
  printf '%s\n' "$3" >"$1/internal/kernel/moon.pkg"
  printf '%s\n' "$4" >"$1/moon.pkg"
  printf 'package "ihb2032/MoonFrame/frame"\n' >"$1/frame/pkg.generated.mbti"
  mkdir -p "$1/.github/scripts"
  (cd "$1" && git add -A && git commit -qm f)
  sh "$scripts/check_layering.sh" "$1" --write >/dev/null 2>&1 || true
}

# `frame` reaches the column only through `series`; its *test* block names the
# storage layer deliberately, which is the distinction the guard must draw.
ly_frame='import {
  "ihb2032/MoonFrame/series",
  "ihb2032/MoonFrame/internal/kernel",
}

import {
  "ihb2032/MoonFrame/internal/column",
} for "test"'
ly_kernel='import {
  "ihb2032/MoonFrame/internal/column",
  "ihb2032/MoonFrame/series",
}'
ly_root='import {
  "ihb2032/MoonFrame/expr",
  "ihb2032/MoonFrame/frame",
  "ihb2032/MoonFrame/io",
  "ihb2032/MoonFrame/lazy",
  "ihb2032/MoonFrame/series",
  "ihb2032/MoonFrame/types",
}'

mklayering "$work/ly_ok" "$ly_frame" "$ly_kernel" "$ly_root"
expect 0 'layering: production graph obeys the rules (test imports reach further)' \
  sh "$scripts/check_layering.sh" "$work/ly_ok"

mklayering "$work/ly_column" 'import {
  "ihb2032/MoonFrame/series",
  "ihb2032/MoonFrame/internal/column",
}' "$ly_kernel" "$ly_root"
expect_out 1 'imports internal/column' 'layering: frame imports the physical column layer' \
  sh "$scripts/check_layering.sh" "$work/ly_column"

# The execution engine's machinery is `frame`'s to drive: another public
# package reaching past it for the kernel routes computation around the layer
# that decides what a verb means.
mklayering "$work/ly_kernel_importer" "$ly_frame" "$ly_kernel" "$ly_root"
printf 'import {\n  "ihb2032/MoonFrame/types",\n  "ihb2032/MoonFrame/internal/kernel",\n}\n' \
  >"$work/ly_kernel_importer/io/moon.pkg"
(cd "$work/ly_kernel_importer" && git add -A && git commit -qm kernel)
expect_out 1 'imports internal/kernel' 'layering: a public package other than frame imports the kernel' \
  sh "$scripts/check_layering.sh" "$work/ly_kernel_importer"

mklayering "$work/ly_reverse" "$ly_frame" 'import {
  "ihb2032/MoonFrame/internal/column",
  "ihb2032/MoonFrame/frame",
}' "$ly_root"
expect_out 1 'stays below the verbs' 'layering: an internal package imports a verb package' \
  sh "$scripts/check_layering.sh" "$work/ly_reverse"

mklayering "$work/ly_root_dep" "$ly_frame" "$ly_kernel" 'import {
  "ihb2032/MoonFrame/expr",
  "ihb2032/MoonFrame/frame",
  "ihb2032/MoonFrame/io",
  "ihb2032/MoonFrame/lazy",
  "ihb2032/MoonFrame/series",
  "ihb2032/MoonFrame/types",
  "ihb2032/MoonFrame/internal/kernel",
}'
expect_out 1 'the root facade imports' 'layering: the facade imports beyond the six public packages' \
  sh "$scripts/check_layering.sh" "$work/ly_root_dep"

mklayering "$work/ly_leak" "$ly_frame" "$ly_kernel" "$ly_root"
printf 'package "ihb2032/MoonFrame/frame"\n\nimport {\n  "ihb2032/MoonFrame/internal/column",\n}\n' \
  >"$work/ly_leak/frame/pkg.generated.mbti"
(cd "$work/ly_leak" && git add -A && git commit -qm leak)
expect_out 1 'names an internal package' 'layering: an internal package named in a public interface' \
  sh "$scripts/check_layering.sh" "$work/ly_leak"

# Direction, which a snapshot cannot hold: `types` depending on `series` is a
# reversal of the stack, not a new edge to consider.
mklayering "$work/ly_reversed" "$ly_frame" "$ly_kernel" "$ly_root"
printf 'import {\n  "ihb2032/MoonFrame/series",\n}\n' \
  >"$work/ly_reversed/types/moon.pkg"
(cd "$work/ly_reversed" && git add -A && git commit -qm reversed)
expect_out 1 'not in its allowed set' 'layering: a package depending upward' \
  sh "$scripts/check_layering.sh" "$work/ly_reversed"

# And the property that gives direction its meaning. This cycle runs the long
# way round — `expr` through `types` and back — so no single edge looks wrong.
mklayering "$work/ly_cycle" "$ly_frame" "$ly_kernel" "$ly_root"
printf 'import {\n  "ihb2032/MoonFrame/expr",\n}\n' \
  >"$work/ly_cycle/types/moon.pkg"
printf 'import {\n  "ihb2032/MoonFrame/types",\n}\n' >"$work/ly_cycle/expr/moon.pkg"
(cd "$work/ly_cycle" && git add -A && git commit -qm cycle)
expect_out 1 'has a cycle' 'layering: a dependency cycle' \
  sh "$scripts/check_layering.sh" "$work/ly_cycle"

# Everything the rules do not forbid is still pinned: a new edge between two
# packages breaks no rule, and is exactly the structural decision the snapshot
# is there to surface.
mklayering "$work/ly_new_edge" "$ly_frame" "$ly_kernel" "$ly_root"
printf 'import {\n  "ihb2032/MoonFrame/types",\n  "ihb2032/MoonFrame/series",\n}\n' \
  >"$work/ly_new_edge/expr/moon.pkg"
(cd "$work/ly_new_edge" && git add -A && git commit -qm edge)
expect_out 1 'dependency graph changed' 'layering: a new production edge the rules allow' \
  sh "$scripts/check_layering.sh" "$work/ly_new_edge"

mklayering "$work/ly_no_snapshot" "$ly_frame" "$ly_kernel" "$ly_root"
rm -f "$work/ly_no_snapshot/.github/scripts/layering.snapshot"
expect_out 1 'snapshot' 'layering: snapshot absent' \
  sh "$scripts/check_layering.sh" "$work/ly_no_snapshot"

# The way past every rule above: declare the imports in the legacy JSON
# manifest, which nothing here parses. The fixture's own JSON manifest is
# exempt — it belongs to a separate module built against the published facade.
mklayering "$work/ly_json" "$ly_frame" "$ly_kernel" "$ly_root"
mkdir -p "$work/ly_json/sneaky"
printf '{ "import": ["ihb2032/MoonFrame/frame"] }\n' \
  >"$work/ly_json/sneaky/moon.pkg.json"
(cd "$work/ly_json" && git add -A && git commit -qm json)
expect_out 1 'legacy JSON manifest' 'layering: a package outside the parsed manifests' \
  sh "$scripts/check_layering.sh" "$work/ly_json"

mklayering "$work/ly_json_fixture" "$ly_frame" "$ly_kernel" "$ly_root"
mkdir -p "$work/ly_json_fixture/.github/fixtures/smoke"
printf '{ "import": ["ihb2032/MoonFrame"] }\n' \
  >"$work/ly_json_fixture/.github/fixtures/smoke/moon.pkg.json"
(cd "$work/ly_json_fixture" && git add -A && git commit -qm fixture)
expect 0 'layering: the CI fixture keeps its JSON manifest' \
  sh "$scripts/check_layering.sh" "$work/ly_json_fixture"

# ── engine seams ──────────────────────────────────────────────────────────
mkseams() {
  # mkseams <dir> <series-source> <snapshot-body|--> [test-source] [allowlist]
  # The optional fourth argument lands in a `_wbtest.mbt`, which the guard must
  # skip: a whitebox test compiles inside its own package, so a `pub` helper
  # there is not an external symbol at all. The fifth is the allowlist of seams
  # allowed to have no production caller (absent file = nothing allowed).
  #
  # Every fixture gets an `io` package that imports `series` and calls the
  # seams, because a seam nothing outside its package calls is a failure now:
  # without a consumer these fixtures would all trip that rule instead of
  # testing what they are named for. `io` and not `frame`, so the two fixtures
  # that write their own `frame` keep saying only what they mean to.
  mkdir -p "$1/series" "$1/io" "$1/.github/scripts"
  (cd "$1" && git init -q . && git config user.email t@t &&
    git config user.name t && git config core.autocrlf false)
  printf '%s\n' "$2" >"$1/series/series.mbt"
  printf 'import {\n  "ihb2032/MoonFrame/series",\n}\n' >"$1/io/moon.pkg"
  printf '///|\npub fn consume(c : Series) -> Int {\n  ignore(validity_bools(c))\n  ignore(reducer_for(c, ReduceOp::Sum))\n  ignore(after_the_value(c))\n  ignore(bool_cells(c))\n  0\n}\n' \
    >"$1/io/io.mbt"
  if [ "$3" != "--" ]; then
    printf '%s\n' "$3" >"$1/.github/scripts/engine_seams.snapshot"
  fi
  if [ $# -ge 4 ] && [ -n "$4" ]; then
    printf '%s\n' "$4" >"$1/series/series_wbtest.mbt"
  fi
  if [ $# -ge 5 ]; then
    printf '%s\n' "$5" >"$1/.github/scripts/engine_seams.allowlist"
  fi
  (cd "$1" && git add -A && git commit -qm f)
}

es_source='///|
/// A public constructor, no attributes: ordinary API, not a seam.
pub fn Series::from_ints(name : String, values : Array[Int64]) -> Series {
  ignore(name)
}

///|
/// A seam: shared across packages, hidden from the interface.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn validity_bools(column : Series) -> Array[Bool] {
  ignore(column)
}

///|
/// A wrapped signature, which the extractor joins into one line.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn reducer_for(
  column : Series,
  op : ReduceOp,
) -> (Int, @types.DataType) {
  ignore(column)
}

///|
/// A hidden enum two packages share: matchable and constructible by both, and
/// absent from every `.mbti`, so its variants ride in this snapshot.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub(all) enum ReduceOp {
  Sum
  Mean
}'
es_snap='series | doc_hidden internal_engine | pub fn reducer_for( column : Series, op : ReduceOp, ) -> (Int, @types.DataType) | used by: io
series | doc_hidden internal_engine | pub fn validity_bools(column : Series) -> Array[Bool] | used by: io
series | doc_hidden internal_engine | pub(all) enum ReduceOp
series | doc_hidden internal_engine | variant ReduceOp::Mean
series | doc_hidden internal_engine | variant ReduceOp::Sum'

es_orphan="$es_source

///|
#doc(hidden)
#internal(engine, \"MoonFrame execution engine API\")
pub fn Series::is_canonical(self : Series) -> Bool {
  ignore(self)
}"
es_orphan_snap="series | doc_hidden internal_engine | pub fn Series::is_canonical(self : Series) -> Bool | used by: (no production caller outside series)
$es_snap"


mkseams "$work/es_ok" "$es_source" "$es_snap"
expect 0 'engine seams: match the snapshot (an unattributed pub is not a seam)' \
  sh "$scripts/check_engine_seams.sh" "$work/es_ok"

mkseams "$work/es_added" "$es_source

///|
#doc(hidden)
#internal(engine, \"MoonFrame execution engine API\")
pub fn bool_cells(column : Series) -> Array[Bool]? {
  ignore(column)
}" "$es_snap"
expect_out 1 'hidden cross-package surface changed' 'engine seams: a new hidden seam' \
  sh "$scripts/check_engine_seams.sh" "$work/es_added"

# The widening this exists for: same name, same visibility, a return type that
# now hands another package a live buffer.
mkseams "$work/es_widened" \
  "$(printf '%s\n' "$es_source" |
    sed 's/-> Array\[Bool\] {/-> (Array[Bool], @column.Bitmap) {/')" \
  "$es_snap"
expect_out 1 'hidden cross-package surface changed' 'engine seams: a seam signature widened' \
  sh "$scripts/check_engine_seams.sh" "$work/es_widened"

# The attributes are a pair, and each half alone fails: an alert on a symbol
# the interface still publishes, or a symbol hidden from the interface — and so
# from every guard that reads one — with nothing stopping a downstream call.
# Adding a variant to a hidden shared enum widens the seam as surely as a
# signature change, and no `.mbti` records it.
mkseams "$work/es_variant" \
  "$(printf '%s\n' "$es_source" | awk '{ print } /^  Mean$/ { print "  Product" }')" \
  "$es_snap"
expect_out 1 'variant ReduceOp::Product' 'engine seams: a hidden enum gained a variant' \
  sh "$scripts/check_engine_seams.sh" "$work/es_variant"

mkseams "$work/es_unpaired" \
  "$(printf '%s\n' "$es_source" | grep -v '^#doc(hidden)$')" "$es_snap"
expect_out 1 'only one of the two attributes' \
  'engine seams: an alert without the interface hide' \
  sh "$scripts/check_engine_seams.sh" "$work/es_unpaired"

mkseams "$work/es_hidden_only" \
  "$(printf '%s\n' "$es_source" | grep -v '^#internal(engine')" "$es_snap"
expect_out 1 'only one of the two attributes' \
  'engine seams: hidden from the interface with no alert' \
  sh "$scripts/check_engine_seams.sh" "$work/es_hidden_only"

# A top-level value opens no body, so the signature joiner must take it as it
# stands — otherwise it swallows every declaration up to the next brace, and
# the seam after this one disappears from the snapshot.
mkseams "$work/es_value" "$es_source

///|
#doc(hidden)
#internal(engine, \"MoonFrame execution engine API\")
pub let seam_limit : Int = 3

///|
#doc(hidden)
#internal(engine, \"MoonFrame execution engine API\")
pub fn after_the_value(column : Series) -> Int {
  ignore(column)
}" 'series | doc_hidden internal_engine | pub fn after_the_value(column : Series) -> Int | used by: io
series | doc_hidden internal_engine | pub fn reducer_for( column : Series, op : ReduceOp, ) -> (Int, @types.DataType) | used by: io
series | doc_hidden internal_engine | pub fn validity_bools(column : Series) -> Array[Bool] | used by: io
series | doc_hidden internal_engine | pub let seam_limit : Int = 3
series | doc_hidden internal_engine | pub(all) enum ReduceOp
series | doc_hidden internal_engine | variant ReduceOp::Mean
series | doc_hidden internal_engine | variant ReduceOp::Sum'
expect 0 'engine seams: a top-level value seam, and the one after it' \
  sh "$scripts/check_engine_seams.sh" "$work/es_value"

# The caller scan reads a name, so two things have to keep it honest: a package
# that cannot import the declaring one is not searched at all, and a
# declaration of the same name is not a call. Both fixtures would otherwise
# report `frame` as a consumer and hide a seam nothing calls.
mkseams "$work/es_same_name" "$es_source" "$es_snap"
mkdir -p "$work/es_same_name/frame"
printf 'import {\n}\n' >"$work/es_same_name/frame/moon.pkg"
printf '///|\npub fn DataFrame::validity_bools(self : DataFrame) -> Int {\n  0\n}\n' \
  >"$work/es_same_name/frame/frame.mbt"
(cd "$work/es_same_name" && git add -A && git commit -qm samename)
expect 0 'engine seams: a same-named symbol in a package that cannot import the seam' \
  sh "$scripts/check_engine_seams.sh" "$work/es_same_name"

mkseams "$work/es_decl_only" "$es_source" "$es_snap"
mkdir -p "$work/es_decl_only/frame"
printf 'import {\n  "ihb2032/MoonFrame/series",\n}\n' \
  >"$work/es_decl_only/frame/moon.pkg"
printf '///|\npub fn DataFrame::validity_bools(self : DataFrame) -> Int {\n  0\n}\n' \
  >"$work/es_decl_only/frame/frame.mbt"
(cd "$work/es_decl_only" && git add -A && git commit -qm declonly)
expect 0 'engine seams: a declaration of the same name is not a call' \
  sh "$scripts/check_engine_seams.sh" "$work/es_decl_only"

# How the symbol is spelled at the call site carries the rest of the weight. A
# free function is never reached through a receiver, so `c.validity_bools(` is
# a method on something else — counting it would report a seam as live while
# nothing calls it, which is the false negative that lets a dead seam stay.
mkseams "$work/es_receiver" "$es_source" "$es_snap"
printf '///|\npub fn consume(c : Series) -> Int {\n  ignore(c.validity_bools())\n  ignore(reducer_for(c, ReduceOp::Sum))\n  ignore(after_the_value(c))\n  ignore(bool_cells(c))\n  0\n}\n' \
  >"$work/es_receiver/io/io.mbt"
(cd "$work/es_receiver" && git add -A && git commit -qm receiver)
expect_out 1 'no production caller outside its package' \
  'engine seams: a receiver call is not a call to the free function' \
  sh "$scripts/check_engine_seams.sh" "$work/es_receiver"

# The two spellings that *are* calls: package-qualified for a free function,
# and through the owning type for a method.
mkseams "$work/es_qualified" "$es_source" "$es_snap"
printf '///|\npub fn consume(c : Series) -> Int {\n  ignore(@series.validity_bools(c))\n  ignore(reducer_for(c, ReduceOp::Sum))\n  ignore(after_the_value(c))\n  ignore(bool_cells(c))\n  0\n}\n' \
  >"$work/es_qualified/io/io.mbt"
(cd "$work/es_qualified" && git add -A && git commit -qm qualified)
expect 0 'engine seams: a package-qualified free call counts' \
  sh "$scripts/check_engine_seams.sh" "$work/es_qualified"

mkseams "$work/es_type_call" "$es_orphan" "$(printf '%s\n' "$es_orphan_snap" |
  sed 's/pub fn Series::is_canonical(self : Series) -> Bool | used by: (no production caller outside series)/pub fn Series::is_canonical(self : Series) -> Bool | used by: io/')"
printf '///|\npub fn consume(c : Series) -> Int {\n  ignore(Series::is_canonical(c))\n  ignore(validity_bools(c))\n  ignore(reducer_for(c, ReduceOp::Sum))\n  ignore(after_the_value(c))\n  ignore(bool_cells(c))\n  0\n}\n' \
  >"$work/es_type_call/io/io.mbt"
(cd "$work/es_type_call" && git add -A && git commit -qm typecall)
expect 0 'engine seams: a Type::method call counts' \
  sh "$scripts/check_engine_seams.sh" "$work/es_type_call"

# A consumer writing into a buffer the seam handed it. Nothing about this
# shows up in an import, a signature, or a snapshot — the whole point of
# checking it here.
mkseams "$work/es_mutation" "$es_source" "$es_snap"
printf '///|\npub fn consume(c : Series) -> Int {\n  match c.storage().data() {\n    ColumnData::Int(a) => a[0] = 1L\n    _ => ()\n  }\n  ignore(validity_bools(c))\n  ignore(reducer_for(c, ReduceOp::Sum))\n  ignore(after_the_value(c))\n  ignore(bool_cells(c))\n  0\n}\n' \
  >"$work/es_mutation/io/io.mbt"
(cd "$work/es_mutation" && git add -A && git commit -qm mutation)
expect_out 1 'writes into a live column buffer' \
  'engine seams: a consumer mutating a column buffer' \
  sh "$scripts/check_engine_seams.sh" "$work/es_mutation"

# Writing into an array the consumer built itself is ordinary code, and a
# rule that cannot tell the two apart would just be turned off.
mkseams "$work/es_own_array" "$es_source" "$es_snap"
printf '///|\npub fn consume(c : Series) -> Int {\n  let out : Array[Int64] = [0L]\n  match c.storage().data() {\n    ColumnData::Int(a) => out[0] = a[0]\n    _ => ()\n  }\n  ignore(validity_bools(c))\n  ignore(reducer_for(c, ReduceOp::Sum))\n  ignore(after_the_value(c))\n  ignore(bool_cells(c))\n  0\n}\n' \
  >"$work/es_own_array/io/io.mbt"
(cd "$work/es_own_array" && git add -A && git commit -qm ownarray)
expect 0 'engine seams: writing into a locally built array is fine' \
  sh "$scripts/check_engine_seams.sh" "$work/es_own_array"

mkseams "$work/es_missing" "$es_source" --
expect_out 1 'snapshot' 'engine seams: snapshot absent' \
  sh "$scripts/check_engine_seams.sh" "$work/es_missing"

# The rule the allowlist exists for. A seam nothing outside its package calls
# is `pub` for no reason the architecture can state, and the snapshot used to
# record that quietly — which is how five of them survived a release cycle.
mkseams "$work/es_orphan" "$es_orphan" "$es_orphan_snap"
expect_out 1 'no production caller outside its package' \
  'engine seams: a seam nothing outside the package calls' \
  sh "$scripts/check_engine_seams.sh" "$work/es_orphan"

# The remediation has to name the file to edit. It said "add it to the list in
# this script" while the list had already moved to its own file, which sends a
# maintainer to fix the guard that just fired at them.
expect_out 1 '.github/scripts/engine_seams.allowlist' \
  'engine seams: the fix names the allowlist file' \
  sh "$scripts/check_engine_seams.sh" "$work/es_orphan"

# Listed, with a reason, in a file `--write` does not touch: allowed. This is
# also what pins the key spelling — `pkg/Symbol`, the reason after an em dash.
mkseams "$work/es_allowed" "$es_orphan" "$es_orphan_snap" '' \
  '# a comment, and a blank line, are both fine

series/Series::is_canonical — asserted by another package, which has no other way to see it'
expect 0 'engine seams: a caller-less seam listed with its reason' \
  sh "$scripts/check_engine_seams.sh" "$work/es_allowed"

# Regenerating must not be a way to accept one: the rule runs before --write.
mkseams "$work/es_orphan_write" "$es_orphan" "$es_orphan_snap"
expect_out 1 'no production caller outside its package' \
  'engine seams: --write does not launder a caller-less seam' \
  sh "$scripts/check_engine_seams.sh" "$work/es_orphan_write" --write

# And the list stays honest the other way: an entry for a seam that has a
# caller now (or was renamed, or deleted) is an exception nobody re-read.
mkseams "$work/es_stale_allow" "$es_source" "$es_snap" '' \
  'series/validity_bools — a reason that stopped being true when io started calling it'
expect_out 1 'an exception that is no longer needed' \
  'engine seams: an allowlist entry whose seam gained a caller' \
  sh "$scripts/check_engine_seams.sh" "$work/es_stale_allow"

expect_out 1 '.github/scripts/engine_seams.allowlist' \
  'engine seams: dropping a stale entry names the allowlist file' \
  sh "$scripts/check_engine_seams.sh" "$work/es_stale_allow"

# A test-only helper carrying the seam attributes is not part of the surface,
# in either test spelling. Left in scope it would land in the snapshot and fail
# CI over a symbol no caller outside its own package can name.
mkseams "$work/es_wbtest" "$es_source" "$es_snap" '///|
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn test_only_probe(column : Series) -> Int {
  ignore(column)
}'
expect 0 'engine seams: a whitebox test declaration is out of scope' \
  sh "$scripts/check_engine_seams.sh" "$work/es_wbtest"

# ── internal surface ──────────────────────────────────────────────────────
mkinternal() {
  # mkinternal <dir> <internal-column-source> [allowlist] [kernel-source]
  # `series` imports `internal/column` and is where a legitimate caller lives;
  # the optional kernel source is a second consumer, for the case where the
  # only use is a function *passed* rather than called.
  mkdir -p "$1/internal/column" "$1/series" "$1/.github/scripts"
  (cd "$1" && git init -q . && git config user.email t@t &&
    git config user.name t && git config core.autocrlf false)
  printf 'import {\n}\n' >"$1/internal/column/moon.pkg"
  printf '%s\n' "$2" >"$1/internal/column/column.mbt"
  printf 'import {\n  "ihb2032/MoonFrame/internal/column",\n}\n' \
    >"$1/series/moon.pkg"
  printf '%s\n' "${4:-///|
pub fn read(c : BuiltinColumn) -> Int {
  ignore(c.len())
  0
}}" >"$1/series/series.mbt"
  if [ $# -ge 3 ] && [ -n "$3" ]; then
    printf '%s\n' "$3" >"$1/.github/scripts/internal_surface.allowlist"
  fi
  (cd "$1" && git add -A && git commit -qm f)
}

is_source='///|
/// Called from `series`: reachable, and stays `pub`.
pub fn BuiltinColumn::len(self : BuiltinColumn) -> Int {
  ignore(self)
}

///|
/// Nothing outside this package names it.
pub fn BuiltinColumn::placeholders_normalized(self : BuiltinColumn) -> Bool {
  ignore(self)
}'

mkinternal "$work/is_unreachable" "$is_source"
expect_out 1 'nothing outside its package calls' \
  'internal surface: a pub nothing outside the package calls' \
  sh "$scripts/check_internal_surface.sh" "$work/is_unreachable"

mkinternal "$work/is_listed" "$is_source" \
  '# a comment

internal/column/BuiltinColumn::placeholders_normalized — an invariant that exists to be asserted'
expect 0 'internal surface: an unreachable pub listed with its reason' \
  sh "$scripts/check_internal_surface.sh" "$work/is_listed"

# An entry for a symbol that has a caller now is an exception nobody re-read.
mkinternal "$work/is_stale" "$is_source" \
  'internal/column/BuiltinColumn::placeholders_normalized — an invariant that exists to be asserted
internal/column/BuiltinColumn::len — a reason that stopped being true when series started calling it'
expect_out 1 'no longer needed' \
  'internal surface: an entry whose symbol gained a caller' \
  sh "$scripts/check_internal_surface.sh" "$work/is_stale"

# A free function handed to a higher-order kernel is used, though the call site
# never spells a parenthesis after its name — the false positive that made two
# real helpers look unreachable.
mkinternal "$work/is_passed" '///|
pub fn BuiltinColumn::len(self : BuiltinColumn) -> Int {
  ignore(self)
}

///|
pub fn sign_i64(a : Int64) -> Int64 {
  a
}' '' '///|
pub fn read(c : BuiltinColumn) -> Int {
  ignore(c.len())
  apply(@column.sign_i64)
}'
expect 0 'internal surface: a function passed rather than called is used' \
  sh "$scripts/check_internal_surface.sh" "$work/is_passed"

# ── the repository itself ─────────────────────────────────────────────────
expect 0 'repo: version identity' sh "$scripts/check_version_identity.sh" "$root"
expect 0 'repo: stale names' sh "$scripts/check_stale_names.sh" "$root"
expect 0 'repo: enum surface' sh "$scripts/check_enum_surface.sh" "$root"
expect 0 'repo: facade surface' sh "$scripts/check_facade_surface.sh" "$root"
expect 0 'repo: internal packages' \
  sh "$scripts/check_internal_packages.sh" "$root"
expect 0 'repo: layering' sh "$scripts/check_layering.sh" "$root"
expect 0 'repo: engine seams' sh "$scripts/check_engine_seams.sh" "$root"
expect 0 'repo: internal surface' \
  sh "$scripts/check_internal_surface.sh" "$root"

printf 'doc guards: %s cases pass\n' "$cases"
