#!/bin/sh
# A comment that names something is making a claim, and the two claims a
# machine can check are the ones that break silently: *where* a thing lives,
# and *whether it still exists*. Code that moves takes its own call sites with
# it and leaves every sentence about it behind — a file header describing an
# algorithm that moved a layer down, a note pointing at a test that was renamed
# when it moved, a cross-reference to a package that no longer holds the symbol.
# Nothing fails, so nothing says so, and the next reader is told something
# untrue by the file they opened to learn from.
#
# Scope: tracked Markdown, and comment lines in tracked `*.mbt` outside
# `examples/`. Those are the files whose prose describes MoonBit symbols, and the
# `.mbti` interfaces supply the index of what exists. Comments in the guard
# scripts, the CI workflow and the package manifests are *not* scanned — a
# reference that breaks there breaks silently, which is how this guard's own
# header once came to describe a mechanism the script below had replaced. If a
# shell or YAML comment starts carrying symbol references worth checking, widen
# the two file lists rather than the sentence above.
#
# Three reference shapes are checked, in those files:
#
#   * `@pkg.Name` / `@pkg.Type::method` — the package must be one of this
#     module's, and it must actually declare that name. A qualifier this module
#     does not define is external (`@debug`, `@string`, …) and is skipped, since
#     nothing here can say what it holds.
#   * `Type::method` — that exact pair must exist. A method renamed or moved to
#     another type breaks it; the type existing is not enough.
#   * `path/to/file.mbt`, `.md` or `.sh` — the file must exist. Resolution tries
#     the naming file's own directory first (a sibling), then the repository
#     root, then `docs/`, `.github/` and `.github/scripts/` — so a bare
#     `api.md` or `check_layering.sh` resolves from anywhere, while a source
#     file has to say which package.
#
# Evidence comes from code, never from other comments: a symbol two comments
# agree on and no declaration carries is exactly the drift being looked for.
#
# What it cannot check is the sentence around the name — a comment can name
# only living symbols and still describe behaviour that changed. That kind is
# found by reading, and by asking of every claim "what would prove this false".
# Neither can it see a reference in a file it does not read; the scope above is
# the whole of what a green run says.
#
# `docs/changelog.md` and `docs/migration.md` are exempt: naming what was
# removed is their content. Elsewhere two markers skip a line, and which one
# to reach for is the difference between two claims. `doc-guard: historical`
# — the marker the stale-name guard also honours — says the name *was* real:
# this line is about the past. `doc-guard: unresolved` says the name is not
# meant to resolve at all: a convention every package follows (`deprecated.mbt`),
# a file deliberately absent ("no dedicated `foo_test.mbt`"), a basename four
# packages share. Both are claims a reader can check; neither is a way to
# silence a reference that simply broke.
#
# Usage: .github/scripts/check_comment_references.sh [repo-root]
# Exit 0 when every checked reference resolves; 1 otherwise.

set -eu

root="."
for arg in "$@"; do
  case "$arg" in
    *) root="$arg" ;;
  esac
done
cd "$root"

sources=$(git ls-files '*.mbt' | grep -v '^examples/' || true)
prose=$(git ls-files '*.md' | grep -vE '^docs/(changelog|migration)\.md$' || true)
interfaces=$(git ls-files '*.mbti' | grep -v '^examples/' || true)

# The packages this module defines, by their qualifier — the last path segment,
# which is how a caller spells `@column` for `internal/column`.
pkg_dirs=$(git ls-files '*moon.pkg' | grep -v '^examples/' |
  while IFS= read -r m; do
    d=$(dirname "$m")
    [ "$d" != "." ] || d=""
    printf '%s\t%s\n' "${d##*/}" "$d"
  done | LC_ALL=C sort -u)

# Everything below runs as three `awk` passes over file *lists*, not as a
# pipeline per file or per line. Written the obvious way — a `grep` and a `sed`
# for each of two hundred files, then one lookup per reference — this took long
# enough that nobody would run it locally, which is the same as not having it.
index=$(mktemp)
pairs=$(mktemp)
refs=$(mktemp)
paths=$(mktemp)
pkgmap=$(mktemp)
trap 'rm -f "$index" "$pairs" "$refs" "$paths" "$pkgmap" "$types"' EXIT INT TERM

# Pass 1 — what the code declares, by package directory. Comment lines are
# stripped first: a name two comments agree on and no declaration carries is
# exactly the drift being looked for, so it must not count as evidence.
printf '%s\n%s\n' "$sources" "$interfaces" | grep . |
  xargs awk '
    FNR == 1 {
      dir = FILENAME
      if (!sub(/\/[^\/]*$/, "", dir)) dir = ""
      code = (FILENAME ~ /\.mbti$/)
    }
    !code && /^[[:space:]]*(\/\/\/|\/\/)/ { next }
    {
      line = $0
      while (match(line, /[A-Za-z_][A-Za-z0-9_]*/)) {
        print dir "\t" substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' | LC_ALL=C sort -u >"$index"

# The types this module defines. A pair whose owner is not one of them is a
# standard-library method (`Double::to_string`, `Int::MAX`): unreadable from
# here, so a miss would say nothing.
types=$(mktemp)
printf '%s\n%s\n' "$sources" "$interfaces" | grep . |
  xargs grep -hoE '^(pub(\(all\))? )?(priv )?(struct|enum|type|suberror) [A-Z][A-Za-z0-9_]*' |
  sed 's/.* //' | LC_ALL=C sort -u >"$types"

# Pass 2 — the `Type::method` pairs the code spells out, same rule.
printf '%s\n%s\n' "$sources" "$interfaces" | grep . |
  xargs awk '
    FNR == 1 { code = (FILENAME ~ /\.mbti$/) }
    !code && /^[[:space:]]*(\/\/\/|\/\/)/ { next }
    {
      line = $0
      # `#alias(short)` gives a method a second spelling, and a comment may
      # use either. The attribute sits above the declaration it renames, so
      # the name is held until that line arrives.
      if (match(line, /#alias\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\)/)) {
        pending = substr(line, RSTART, RLENGTH)
        gsub(/[^A-Za-z0-9_]/, "", pending)
        sub(/^alias/, "", pending)
        next
      }
      if (pending != "" && match(line, /fn[[:space:]]+[A-Z][A-Za-z0-9_]*::/)) {
        owner = substr(line, RSTART, RLENGTH)
        sub(/^fn[[:space:]]+/, "", owner)
        sub(/::$/, "", owner)
        print owner "::" pending
        pending = ""
      }
      while (match(line, /[A-Z][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*/)) {
        print substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' | LC_ALL=C sort -u >"$pairs"

# Pass 3 — every backticked reference a comment carries. In source only comment
# lines can hold one; in prose every line can.
printf '%s\n' "$prose" | grep . >"$refs.prose" || true
printf '%s\n%s\n' "$sources" "$prose" | grep . |
  xargs awk -v proselist="$refs.prose" '
    BEGIN {
      while ((getline p < proselist) > 0) isprose[p] = 1
    }
    FNR == 1 { prose = (FILENAME in isprose) }
    !prose && $0 !~ /^[[:space:]]*(\/\/\/|\/\/)/ { next }
    /doc-guard: (historical|unresolved)/ { next }
    {
      line = $0
      while (match(line, /`[^`]+`/)) {
        ref = substr(line, RSTART + 1, RLENGTH - 2)
        print FILENAME "\t" FNR "\t" ref
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' >"$refs"
rm -f "$refs.prose"

git ls-files >"$paths"
printf '%s\n' "$pkg_dirs" >"$pkgmap"

result=$(awk -F'\t' '
  FILENAME == idx  { declared[$1 "\t" $2] = 1; next }
  FILENAME == prs  { pair[$0] = 1; next }
  FILENAME == pth  { exists[$0] = 1; next }
  FILENAME == pmap { if ($1 != "") { pkgdir[$1] = $2; known[$1] = 1 } next }
  FILENAME == typ  { types[$0] = 1; next }
  {
    file = $1; no = $2; ref = $3
    if (ref == "") next
    dir = file
    if (!sub(/\/[^\/]*$/, "", dir)) dir = ""
    if (substr(ref, 1, 1) == "@" && index(ref, ".") > 0) {
      qual = substr(ref, 2, index(ref, ".") - 2)
      rest = substr(ref, index(ref, ".") + 1)
      name = rest; sub(/::.*/, "", name)
      short = rest; sub(/.*::/, "", short)
      if (name == "" || qual ~ /[^A-Za-z0-9_]/ || name ~ /[^A-Za-z0-9_]/) next
      if (!(qual in known) && qual != "moonframe") { external++; next }
      d = (qual in pkgdir) ? pkgdir[qual] : ""
      checked++
      if (!((d "\t" name) in declared) && !((d "\t" short) in declared))
        printf "%s:%s: `%s` — `%s` does not declare `%s`\n", file, no, ref, qual, name
      next
    }
    if (ref ~ /^[A-Z][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*$/) {
      # Only a type this module defines can be asked what methods it has.
      # `Double::to_string` and `Int::MAX` belong to the standard library,
      # which is not read here, so a miss would say nothing about the comment.
      owner = ref; sub(/::.*/, "", owner)
      if (!(owner in types)) { external++; next }
      checked++
      if (!(ref in pair))
        printf "%s:%s: `%s` — `%s` has no such method\n", file, no, ref, owner
      next
    }
    if (ref ~ /\.(mbt|md|sh)$/) {
      if (ref ~ /[^A-Za-z0-9_.\/-]/ || ref ~ /^[_.]/) next
      checked++
      if (!(ref in exists) && !(((dir == "") ? ref : dir "/" ref) in exists) &&
          !((".github/" ref) in exists) && !((".github/scripts/" ref) in exists) &&
          !(("docs/" ref) in exists))
        printf "%s:%s: `%s` — no such file\n", file, no, ref
      next
    }
  }
  END { printf "%%counts%%\t%d\t%d\n", checked, external }
' idx="$index" prs="$pairs" pth="$paths" pmap="$pkgmap" typ="$types" \
  "$index" "$pairs" "$paths" "$pkgmap" "$types" "$refs")

counts=$(printf '%s\n' "$result" | grep '^%counts%' || true)
bad=$(printf '%s\n' "$result" | grep -v '^%counts%' | grep . || true)
checked=$(printf '%s' "$counts" | cut -f2)
external=$(printf '%s' "$counts" | cut -f3)

if [ -n "$bad" ]; then
  printf 'comment references: a comment names something that is not there:\n'
  printf '%s\n' "$bad" | sed 's/^/  /'
  printf '  The name moved, was renamed, or is gone, and the sentence around it\n'
  printf '  is describing a repository that no longer exists. Fix the claim,\n'
  printf '  not just the name — what a comment gets wrong about *where* code\n'
  printf '  lives, it usually also gets wrong about what the code does. A line\n'
  printf '  that must name something removed carries `doc-guard: historical`.\n'
  exit 1
fi

printf 'comment references: %s resolve (%s external qualifiers skipped)\n' \
  "$checked" "$external"
