#!/bin/sh
# Stale API names: an identifier that no longer exists must not appear in
# current-state prose — README, the guides, or a source comment. Naming a
# removed function is worse than saying nothing: it reads as instruction.
#
# Scope. Tracked `*.md` and `*.mbt` files, minus:
#   docs/changelog.md, docs/migration.md   history — old names are the content
#   .github/scripts/                       this list itself
# Untracked scratch (PLAN_*.md and friends) is never scanned: the file list
# comes from `git ls-files`.
#
# A line that genuinely needs to name a removed identifier — explaining what
# something replaced — opts out with the marker `doc-guard: historical` on the
# same line.
#
# Only identifiers are checked, and only ones with a distinctive spelling. Two
# things this cannot do, both learned the hard way:
#
#   * A *claim* that drifts — "its fields stay readable", "adding a field is
#     therefore additive" — wraps across lines, has no fixed spelling, and is
#     wrong only relative to the interface. When a symbol's visibility changes,
#     re-read the sections that describe it; no guard here will.
#   * A bare word, repository-wide. `take` became `Series::gather` in v0.6, but
#     `take` also names live methods (`Bitmap::take`, `ColumnStorage::take`)
#     and is an ordinary English verb, so pinning it everywhere would fire on
#     prose. Where a bare name is worth pinning in *one* file — the file that
#     used to own the symbol, whose comments are the ones that will name it —
#     write the entry as `path/to/file.mbt:name` and it is checked there alone.
#     That is how the `Bitmap` comments naming its own deleted constructors are
#     held, while `Series::from_bools` goes on living.
#
# Usage: .github/scripts/check_stale_names.sh [repo-root]
# Exit 0 when clean, 1 when a removed name is found.

set -eu

root="${1:-.}"
cd "$root"

# Removed in v0.6 unless noted. Keep one per line, most specific first.
patterns='DataFrame::new
Schema::new
Field::new
Field::with_nullable
Options::default(
lazy_frame(
Expr::explain
ScanCsv
ScanNdjson
NdjsonReadOptions
parse_json_records_str
format_json_records
write_json_records
_with_options
str_contains_regex
str_replace_regex
str_replace_all_regex
DataFrame::storage_kinds
DataFrame::take
Series::to_numeric
Series::to_builtin
DataFrame::to_numeric
DataFrame::to_builtin
ColumnStorage::to_numeric
ColumnStorage::to_string_column
Bitmap::all_null
Bitmap::bit_and
Bitmap::from_bools
int_values
float_values
bool_values
string_values
numeric_test.mbt
bitmap_test.mbt
builtin_test.mbt
storage_test.mbt
LazyFrame::from
Expr::col
Expr::lit
JoinOptions::with_
ChartSpec::with_
HtmlOptions::with_
to_markdown_with_limit
to_html_with_options
coalesce_into
internal/column/bitmap.mbt:from_bools
internal/column/bitmap.mbt:bit_and
internal/column/bitmap.mbt:all_null
internal/kernel/numeric.mbt:expr_eval.mbt'

# `|| true`: a `grep` that filters everything out exits 1, which `set -e` would
# turn into a silent failure of the whole script.
files=$(git ls-files '*.md' '*.mbt' |
  grep -v '^docs/changelog\.md$' |
  grep -v '^docs/migration\.md$' |
  grep -v '^\.github/scripts/' || true)

if [ -z "$files" ]; then
  printf 'stale names: no files to scan\n'
  exit 0
fi

fail=0
printf '%s\n' "$patterns" | while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue
  # A pattern written `path/to/file.mbt:name` is checked in that file alone.
  # This is what makes a *bare* name pinnable: `from_bools` was deleted from
  # `Bitmap` while `Series::from_bools` and `BuiltinColumn::from_bools` are
  # live, so a repository-wide entry would fire on every one of them — and the
  # comment that named the deleted one, in the file that used to own it, went
  # unnoticed for exactly that reason.
  scope=""
  case "$pattern" in
    *.mbt:* | *.md:*)
      scope=${pattern%%:*}
      pattern=${pattern#*:}
      ;;
  esac
  if [ -n "$scope" ]; then
    scoped=$(printf '%s\n' "$files" | grep -x -F -- "$scope" || true)
    [ -n "$scoped" ] || continue
  else
    scoped=$files
  fi
  hits=$(printf '%s\n' "$scoped" | tr '\n' '\0' |
    xargs -0 grep -n -F -- "$pattern" 2>/dev/null |
    grep -v 'doc-guard: historical' || true)
  if [ -n "$hits" ]; then
    printf '  removed name "%s":\n' "$pattern"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
  fi
  # The loop body runs in a subshell (the pipe), so the exit status has to
  # ride out through a file rather than a variable.
  [ "$fail" -eq 0 ] || echo dirty >"${TMPDIR:-/tmp}/.stale_names_$$"
done

if [ -f "${TMPDIR:-/tmp}/.stale_names_$$" ]; then
  rm -f "${TMPDIR:-/tmp}/.stale_names_$$"
  printf 'stale names: found\n'
  exit 1
fi
printf 'stale names: none in %s tracked files\n' "$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
