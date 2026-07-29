#!/bin/sh
# Least privilege inside the module. An `internal/` package cannot be imported
# downstream, so nothing in it is a compatibility promise and the seam lock
# (`check_engine_seams.sh`) skips it entirely — which left its `pub` surface
# the one part of the repository nothing governed. `pub` still means something
# there: it is the difference between a symbol `series` and `internal/kernel`
# can reach and one only its own package can. A helper that is `pub` because a
# test found it convenient hands the packages above it capability nobody chose
# to give them, and capability that exists gets used.
#
# The rule: a `pub fn` in an `internal/` package must have a production caller
# in another package. Otherwise make it package-private — visible across every
# file of its own package, which is all its own code needs — or delete it if
# nothing calls it at all.
#
# The same question is asked of types, where the answer matters more: a
# `pub(all) enum` hands another package the power to match and construct every
# variant, a deeper coupling than a method call. A type is used when a package
# that imports this one *names* it — which is a reliable thing to grep for,
# unlike `len` or `get`. One exception is built in rather than listed: a type
# this package's own public interface already carries (returned by a `pub fn`,
# nested in another public type) must be `pub` whether or not any caller writes
# its name, because MoonBit refuses a public definition that depends on a
# private type. `Bitmap` is that case — `validity()` hands one back, and no
# package outside ever names it.
#
# Where that collides with the test suite, the answer is the test suite: an
# internal package's tests belong *inside* it, as `_wbtest.mbt`, where they can
# assert what the package actually holds. `internal/column`'s suite moved there
# when the typed readers it was keeping alive were deleted.
#
# Exceptions live in `internal_surface.allowlist`, one `pkg/Symbol — reason`
# per line, for the case the rule cannot cover: a symbol with no production
# caller anywhere, which therefore cannot be private either, because
# `unused_value` counts production callers only and the strict warning gate
# turns that into an error. An invariant predicate is the honest example — it
# exists to be asserted and nothing else.
#
# What the symbol list comes from matters as much as the rule. Grepping source
# for `pub fn` answers "what did someone write", and the question is "what does
# this package hand over" — which is the generated interface, where a `derive`'s
# methods and every `pub impl` appear and no source line does. So the audit
# enumerates `pkg.generated.mbti` and classifies each entry: written by hand and
# therefore answerable by name, or generated and therefore not (a derived
# `equal` is reached through `==`, and through the `derive` of any type that
# embeds this one — no caller writes its name, so no name-based rule can find
# it). The generated ones are counted, not audited, and the interfaces that
# carry them are tracked files: adding one is already a diff. The two lists are
# also compared, because a `pub fn` that is in the source and *not* in the
# interface is hidden from every reader of one, including this audit.
#
# Callers are matched by how a symbol can be spelled, and a spelling is not
# always proof: `.len(` says a `len` was called, not whose, and a bare
# `sign_i64` reads the same as a local of that name. Where the spelling cannot
# settle it, the compiler can — the symbol is made private, the module is
# type-checked, and a diagnostic in a package that is not this one proves the
# call is real. That probe is what a human would do by hand; running it is
# cheaper than arguing about a grep. It needs a toolchain, so when `moon` is
# absent the run falls back to pinning the unsettled set in
# `internal_surface.ambiguous`, where growing it is at least a diff someone
# approves.
#
# Usage: .github/scripts/check_internal_surface.sh [repo-root]
# Exit 0 when no internal public function or public type is provably unused.
# Exit 1 when one is unreachable, when an allowlist entry is no longer needed,
# when the probe shows a symbol nothing outside its package uses, or when a
# public function is missing from the generated interface.

set -eu

# Shared with the engine-seam guard: both look for callers, and neither should
# count a name inside a string or a comment as one.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib_moonbit_source.sh"

root="."
write=0
for arg in "$@"; do
  case "$arg" in
    --write) write=1 ;;
    *) root="$arg" ;;
  esac
done
cd "$root"

allowlist=".github/scripts/internal_surface.allowlist"
allowed=$([ -f "$allowlist" ] && grep -v '^[[:space:]]*#' "$allowlist" || true)

production_files=$(git ls-files '*.mbt' | grep -vE '_(test|wbtest)\.mbt$' |
  grep -v '^examples/' || true)

# `<pkg> <dep>` per production import, so only a package that can actually name
# a symbol is searched for calls to it.
edges=$(git ls-files '*moon.pkg' | grep -v '^examples/' |
  while IFS= read -r manifest; do
    pkg=$(dirname "$manifest")
    [ "$pkg" != "." ] || pkg=root
    awk -v pkg="$pkg" '
      /^import \{/ { inblock = 1; n = 0; next }
      inblock && /^\}/ {
        if ($0 !~ /for "(wb)?test"/) for (i = 1; i <= n; i++) print pkg " " dep[i]
        inblock = 0
        next
      }
      inblock {
        want = "\"ihb2032/MoonFrame/"
        if (index($0, want) > 0) {
          d = substr($0, index($0, want) + length(want))
          sub(/".*/, "", d)
          dep[++n] = d
        }
      }
    ' "$manifest"
  done | LC_ALL=C sort -u)

has_outside_caller() {
  # has_outside_caller <declaring-pkg> <symbol>
  short=${2##*::}
  case "$2" in
    *::*)
      owner=${2%::*}
      pattern="(\.[[:space:]]*${short}\(|${owner}::${short}\()"
      ;;
    # No `\(` for a free function: it can be *passed* rather than called —
    # `@kernel.sign_i64` handed to a higher-order kernel is a use, and
    # requiring the parenthesis reported two such helpers as unreachable.
    *)
      pattern="((^|[^A-Za-z0-9_.])${short}([^A-Za-z0-9_]|\$)"
      pattern="$pattern|@[A-Za-z0-9_]+\.${short}([^A-Za-z0-9_]|\$))"
      ;;
  esac
  importers=$(printf '%s\n' "$edges" | awk -v want="$1" '$2 == want { print $1 }' |
    grep -v "^$1$" || true)
  [ -n "$importers" ] || return 1
  for imp in $importers; do
    if [ "$imp" = root ]; then
      files=$(printf '%s\n' "$production_files" | grep -v '/' || true)
    else
      files=$(printf '%s\n' "$production_files" | grep "^$imp/[^/]*\$" || true)
    fi
    [ -n "$files" ] || continue
    hits=$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -f "$f" ] || continue
      strip_noncode <"$f" | grep -nE "$pattern" |
        grep -vE '^[0-9]+:[[:space:]]*(pub )?fn(\[[^]]*\])? ' || true
    done)
    [ -z "$hits" ] || return 0
  done
  return 1
}


has_qualified_caller() {
  # has_qualified_caller <declaring-pkg> <Type::method>
  # The unambiguous half of `has_outside_caller`: only the `Type::method(`
  # spelling, which names the owner and so cannot be another type's method.
  owner=${2%::*}
  short=${2##*::}
  importers=$(printf '%s\n' "$edges" | awk -v want="$1" '$2 == want { print $1 }' |
    grep -v "^$1$" || true)
  [ -n "$importers" ] || return 1
  for imp in $importers; do
    if [ "$imp" = root ]; then
      files=$(printf '%s\n' "$production_files" | grep -v '/' || true)
    else
      files=$(printf '%s\n' "$production_files" | grep "^$imp/[^/]*\$" || true)
    fi
    [ -n "$files" ] || continue
    hits=$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -f "$f" ] || continue
      strip_noncode <"$f" | grep -nE "${owner}::${short}\(" || true
    done)
    [ -z "$hits" ] || return 0
  done
  return 1
}

has_qualified_free_caller() {
  # has_qualified_free_caller <declaring-pkg> <free-function>
  # The unambiguous half for a free function: `@alias.name`, which names the
  # package it came from. A bare token could be a local of the same name.
  importers=$(printf '%s\n' "$edges" | awk -v want="$1" '$2 == want { print $1 }' |
    grep -v "^$1$" || true)
  [ -n "$importers" ] || return 1
  for imp in $importers; do
    if [ "$imp" = root ]; then
      files=$(printf '%s\n' "$production_files" | grep -v '/' || true)
    else
      files=$(printf '%s\n' "$production_files" | grep "^$imp/[^/]*\$" || true)
    fi
    [ -n "$files" ] || continue
    hits=$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -f "$f" ] || continue
      strip_noncode <"$f" |
        grep -nE "@[A-Za-z0-9_]+\.$2([^A-Za-z0-9_]|\$)" || true
    done)
    [ -z "$hits" ] || return 0
  done
  return 1
}

has_outside_mention() {
  # has_outside_mention <declaring-pkg> <type-name>
  # A type is used by naming it — in a signature, a `match` arm, a
  # construction — so any mention in code counts.
  importers=$(printf '%s\n' "$edges" | awk -v want="$1" '$2 == want { print $1 }' |
    grep -v "^$1$" || true)
  [ -n "$importers" ] || return 1
  for imp in $importers; do
    if [ "$imp" = root ]; then
      files=$(printf '%s\n' "$production_files" | grep -v '/' || true)
    else
      files=$(printf '%s\n' "$production_files" | grep "^$imp/[^/]*\$" || true)
    fi
    [ -n "$files" ] || continue
    hits=$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -f "$f" ] || continue
      strip_noncode <"$f" | grep -nE "(^|[^A-Za-z0-9_])$2([^A-Za-z0-9_]|\$)" |
        sed "s|^|$f:|" || true
    done)
    [ -z "$hits" ] || return 0
  done
  return 1
}

settle() {
  # settle <declaring-pkg> <symbol> <why the spelling was not proof>
  # The spelling could not say whether this symbol was the one called. Held
  # for the probe pass, which asks the compiler in one go per package.
  candidates="$candidates$1|$2|$3
"
}

is_allowed() {
  found=$(printf '%s\n' "$allowed" | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      "$1 — "*) printf 'yes' ;;
    esac
  done)
  [ -n "$found" ]
}

unreachable=""
ambiguous=""
checked=0
generated_n=0
hidden=""
allowlisted=0
settled=0
candidates=""
probe_runs=0

# The probe: make a symbol private, type-check the module, and see whose files
# complain. `Type … has no method m` in a package that is not this one is a
# caller no spelling rule could have proven. Three things make it trustworthy:
#
#   * a clean baseline — with the module already failing, every probe would
#     "prove" a caller;
#   * plain `moon check`, not `--deny-warn` — privatising a symbol usually also
#     makes it unused where it was declared, and as an *error* that stops the
#     build before the packages above are checked at all, hiding the very
#     callers the probe is looking for;
#   * the file is restored whatever happens, including on a signal.
#
# A whole package's candidates go in one pass, because a check costs far more
# than an edit. A batch has one blind spot — the first package to fail blocks
# the ones above it, so a symbol whose only caller lives further up can come
# back unproven — and that is what the second pass is for: each unproven symbol
# is then probed alone, where nothing else is broken to block the view.
probe_available=0
if [ -f moon.mod ] && command -v moon >/dev/null 2>&1 &&
  moon check >/dev/null 2>&1; then
  probe_available=1
fi

probe_files=""
# Deliberately not a `… | while read` loop: that runs in a subshell, where
# clearing the list of files to restore has no effect on the shell that filled
# it — the second batch then finds stale entries, skips taking a backup, and
# the probe's edit becomes permanent.
restore_probe() {
  saved=$probe_files
  probe_files=""
  old_ifs=$IFS
  IFS='
'
  for pair in $saved; do
    IFS=$old_ifs
    [ -n "$pair" ] || continue
    cp "${pair#*|}" "${pair%%|*}"
    rm -f "${pair#*|}"
    IFS='
'
  done
  IFS=$old_ifs
}
trap 'restore_probe' EXIT INT TERM

privatize() {
  # privatize <declaring-pkg> <symbol-spelling>; records the file for restore.
  decl=$(printf '%s\n' "$production_files" | grep "^$1/[^/]*\$" |
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      grep -nE "^pub fn(\[[^]]*\])? $2\(" "$f" | sed "s|^|$f:|" | head -1
    done | head -1)
  [ -n "$decl" ] || return 1
  file=${decl%%:*}
  rest=${decl#*:}
  line=${rest%%:*}
  case "$probe_files" in
    *"$file|"*) : ;;
    *)
      backup=$(mktemp)
      cp "$file" "$backup"
      probe_files="$probe_files$file|$backup
" ;;
  esac
  sed -i "${line}s/^pub fn/fn/" "$file"
}

# Which of <symbols> the diagnostics blame on a file outside <pkg>. Every
# diagnostic starts with `╭─[ <path>:<line>:<col> ]` and the message that
# follows names the missing symbol, so the two are read together: a mention of
# the short name inside a block whose path is not this package's is the proof.
# Paths arrive with backslashes on Windows and slashes elsewhere; both are
# normalised before the package path is looked for.
probed_outside() {
  pkg=$1
  syms=$2
  out=$(moon check 2>&1 || true)
  blocks=$(printf '%s\n' "$out" | tr '\\' '/' |
    awk -v pkg="/$pkg/" '
      /╭─\[/ { path = $0; keep = (index(path, pkg) == 0); next }
      keep { print }
    ')
  printf '%s\n' "$syms" | while IFS= read -r sym; do
    [ -n "$sym" ] || continue
    short=${sym##*::}
    printf '%s\n' "$blocks" |
      grep -qE "(^|[^A-Za-z0-9_])$short([^A-Za-z0-9_]|\$)" && printf '%s\n' "$sym"
  done
}

# Every `Type::method` declared anywhere in the module, so a short name can be
# asked how many types carry it. This is what separates "a caller names the
# owner" from "a caller wrote `.len(` and there are four `len`s".
all_methods=$(printf '%s\n' "$production_files" | while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -hE '^(pub(\(all\))? )?fn(\[[^]]*\])? [A-Za-z_][A-Za-z0-9_]*::' "$f" || true
done | sed 's/^pub(all) //; s/^pub //; s/^fn//; s/^\[[^]]*\]//; s/^[[:space:]]*//; s/(.*//' |
  LC_ALL=C sort -u)

for pkg in $(git ls-files 'internal/*/moon.pkg' | while IFS= read -r m; do
  dirname "$m"
done); do
  mbti="$pkg/pkg.generated.mbti"
  # What the package publishes, from the file the compiler writes. `pub fn[T] …`
  # is a declaration too: matching only the ungenerified spelling once left
  # every generic function out of the audit entirely.
  syms=$([ -f "$mbti" ] && grep -hE '^pub fn(\[[^]]*\])? ' "$mbti" |
    sed 's/^pub fn//; s/^\[[^]]*\]//; s/^[[:space:]]*//; s/(.*//' |
    LC_ALL=C sort -u || true)
  # The same list as written by hand, which is what separates a declaration
  # this audit can ask about from one a `derive` produced.
  written=$(printf '%s\n' "$production_files" | grep "^$pkg/[^/]*\$" |
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      grep -hE '^pub fn(\[[^]]*\])? ' "$f" || true
    done | sed 's/^pub fn//; s/^\[[^]]*\]//; s/^[[:space:]]*//; s/(.*//' |
    LC_ALL=C sort -u)
  for sym in $written; do
    printf '%s\n' "$syms" | grep -qx -- "$sym" ||
      hidden="$hidden$pkg/$sym
"
  done
  for sym in $syms; do
    if ! printf '%s\n' "$written" | grep -qx -- "$sym"; then
      # Generated by a `derive` or an `impl`: real surface, but no name-based
      # rule can find its callers, so it is counted and left out of the audit.
      generated_n=$((generated_n + 1))
      continue
    fi
    checked=$((checked + 1))
    if ! has_outside_caller "$pkg" "$sym"; then
      if is_allowed "$pkg/$sym"; then
        allowlisted=$((allowlisted + 1))
      else
        unreachable="$unreachable$pkg/$sym
"
      fi
    elif [ "${sym#*::}" != "$sym" ]; then
      # It has a caller — but if a receiver call was the only evidence and the
      # method's short name belongs to more than one type, the evidence does
      # not say *which* type was called. `Type::method(` spellings are exact
      # and never land here.
      short=${sym##*::}
      owners=$(printf '%s\n' "$all_methods" | awk -F'::' -v s="$short" \
        '$2 == s { print $1 }' | LC_ALL=C sort -u | wc -l | tr -d ' ')
      if [ "$owners" -gt 1 ] && ! has_qualified_caller "$pkg" "$sym"; then
        settle "$pkg" "$sym" "shared with $((owners - 1)) other type(s)"
      fi
    else
      # A free function has the same problem in its own shape: the evidence
      # may be a bare `sign_i64` token, which is how a caller passes one as a
      # value — and also how a local of that name reads. A package-qualified
      # `@kernel.sign_i64` names the package and settles it.
      if ! has_qualified_free_caller "$pkg" "$sym"; then
        settle "$pkg" "$sym" "bare-name evidence only"
      fi
    fi
  done
  # Types travel further than functions: a `pub(all) enum` hands another
  # package the power to match and construct every variant, which is a deeper
  # coupling than calling a method. They are also the easier half to check —
  # a type name is a distinctive word, where `len` or `get` is not — so a
  # mention anywhere in a package that imports this one counts as use.
  types=$([ -f "$mbti" ] &&
    grep -hE '^pub(\(all\))? (struct|enum|type|suberror) ' "$mbti" |
    sed 's/^pub(all) //; s/^pub //; s/^\(struct\|enum\|type\|suberror\) //' |
    sed 's/[ (\[{].*//' | LC_ALL=C sort -u || true)
  for ty in $types; do
    checked=$((checked + 1))
    # A type carried by *another* declaration in this package's own public
    # interface — returned by some other `pub fn`, held in a public field,
    # nested in another public type — has to be `pub` whether or not any caller
    # writes its name: MoonBit refuses a public definition that depends on a
    # private type. `Bitmap` is that case: `ColumnStorage::validity` hands one
    # back, and nothing outside this package names it.
    #
    # "Another declaration" is the whole point, and the first version of this
    # missed it. A type's own methods and impls mention the type by
    # construction — `StorageKind::equal`, `pub impl Eq for ColumnStorage`,
    # every `derive` — so accepting any mention let a type prove its own
    # necessity: it needs to be public because its methods need it to be. Those
    # lines are dropped here, which leaves only evidence from something else.
    in_own_surface=""
    if [ -f "$mbti" ]; then
      in_own_surface=$(grep -E "(^|[^A-Za-z0-9_])$ty([^A-Za-z0-9_]|\$)" "$mbti" |
        grep -vE "^pub(\(all\))? (struct|enum|type|suberror) $ty([^A-Za-z0-9_]|\$)" |
        grep -vE "^pub fn(\[[^]]*\])? $ty::" |
        grep -vE "^pub impl( \[[^]]*\])? .* for $ty([^A-Za-z0-9_]|\$)" |
        grep -vE "^pub extend $ty with " |
        head -1 || true)
    fi
    if [ -z "$in_own_surface" ] && ! has_outside_mention "$pkg" "$ty"; then
      is_allowed "$pkg/$ty" ||
        unreachable="$unreachable$pkg/$ty
"
    fi
  done
done

# The candidates the spelling could not settle, put to the compiler: one pass
# per package, then one pass each for whatever the batch left unproven.
if [ -n "$candidates" ] && [ "$probe_available" -eq 1 ]; then
  proven=""
  for ppkg in $(printf '%s\n' "$candidates" | cut -d'|' -f1 |
    LC_ALL=C sort -u); do
    psyms=$(printf '%s\n' "$candidates" |
      awk -F'|' -v p="$ppkg" '$1 == p { print $2 }')
    for sym in $psyms; do privatize "$ppkg" "$sym" || true; done
    # Counted here, not inside the probe: a command substitution runs in a
    # subshell, where the increment would be thrown away with it.
    probe_runs=$((probe_runs + 1))
    proven="$proven$(probed_outside "$ppkg" "$psyms" | sed "s|^|$ppkg/|")
"
    restore_probe
  done
  for entry in $(printf '%s\n' "$candidates" | tr -d ' ' | grep .); do
    ppkg=$(printf '%s' "$entry" | cut -d'|' -f1)
    sym=$(printf '%s' "$entry" | cut -d'|' -f2)
    if printf '%s\n' "$proven" | grep -qx -- "$ppkg/$sym"; then
      settled=$((settled + 1))
      continue
    fi
    privatize "$ppkg" "$sym" || true
    probe_runs=$((probe_runs + 1))
    alone=$(probed_outside "$ppkg" "$sym")
    restore_probe
    if [ -n "$alone" ]; then
      settled=$((settled + 1))
    elif is_allowed "$ppkg/$sym"; then
      allowlisted=$((allowlisted + 1))
    else
      unreachable="$unreachable$ppkg/$sym (private here type-checks: no user outside)
"
    fi
  done
elif [ -n "$candidates" ]; then
  ambiguous=$(printf '%s\n' "$candidates" | grep . |
    awk -F'|' '{ print $1 "/" $2 " (" $3 ")" }')
  ambiguous="$ambiguous
"
fi

# The other direction: an entry whose symbol gained a caller, was renamed, or
# is gone is an exception nobody has re-read.
stale=$(printf '%s\n' "$allowed" | while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  key=${entry%% — *}
  pkg=$(printf '%s' "$key" | sed 's|/[^/]*$||')
  sym=${key##*/}
  # A listed symbol may be either half of what this audits — a function or a
  # type — so both spellings count as "still there". Checking only for a
  # `pub fn` would report a type exception as a symbol that no longer exists.
  if ! grep -qE "^pub fn(\[[^]]*\])? $sym\(|^pub(\(all\))? (struct|enum|type|suberror) $sym([^A-Za-z0-9_]|\$)" \
    $(printf '%s\n' "$production_files" |
      grep "^$pkg/[^/]*\$" | tr '\n' ' ') 2>/dev/null; then
    printf '%s (no such `pub fn` or public type)\n' "$key"
  elif has_outside_caller "$pkg" "$sym"; then
    printf '%s (has a caller now)\n' "$key"
  fi
done)

if [ -n "$unreachable" ]; then
  printf 'internal surface: a `pub` nothing outside its package calls:\n'
  printf '%s' "$unreachable" | sed 's/^/  /'
  printf '  `pub` in an internal package buys reach into it from `series` and\n'
  printf '  `internal/kernel`, nothing else — so one nobody calls is capability\n'
  printf '  handed over for no reason. Make it a plain `fn` (still visible to\n'
  printf '  every file of its own package, with its tests as `_wbtest.mbt`), or\n'
  printf '  delete it if nothing calls it at all. If it cannot be private\n'
  printf '  because only tests call it, add it with its reason to\n'
  printf '  %s.\n' "$allowlist"
  exit 1
fi

if [ -n "$stale" ]; then
  printf 'internal surface: an exception that is no longer needed:\n'
  printf '%s\n' "$stale" | sed 's/^/  /'
  printf '  Drop the entry from %s.\n' "$allowlist"
  exit 1
fi

if [ -n "$hidden" ]; then
  printf 'internal surface: a `pub fn` the generated interface does not carry:\n'
  printf '%s' "$hidden" | sed 's/^/  /'
  printf '  `#doc(hidden)` keeps a symbol out of the interface, and the audit\n'
  printf '  reads the interface — so a hidden one is public to every package\n'
  printf '  above with nothing left that can see it. Inside an internal package\n'
  printf '  the attribute buys nothing anyway: the module boundary already\n'
  printf '  hides the whole package from downstream. Drop it.\n'
  exit 1
fi

# Functions are one half of what a package hands over; a struct's fields are
# the other, and a published field is the worse of the two — it makes the
# *layout* something another package may depend on, where the methods beside it
# already answer what a consumer needs. So an internal package's generated
# interface must not carry one. (The interfaces are tracked, so a change shows
# in the diff either way; what this adds is that putting a field back is a
# decision someone argues for rather than a line nobody notices.)
fields=$(git ls-files 'internal/*/pkg.generated.mbti' |
  while IFS= read -r mbti; do
    [ -f "$mbti" ] || continue
    awk -v file="$mbti" '
      /^pub struct / { inblock = 1; next }
      /^\}/ { inblock = 0; next }
      inblock && /^  [a-zA-Z_]+ : / { printf "%s: %s\n", file, $1 }
    ' "$mbti"
  done)
if [ -n "$fields" ]; then
  printf 'internal surface: a published field in an internal package:\n'
  printf '%s\n' "$fields" | sed 's/^/  /'
  printf '  A field in the interface makes the layout itself reachable from\n'
  printf '  the packages above — `series` and `internal/kernel` can then hold a\n'
  printf '  representation rather than an accessor. Mark it `priv`; if another\n'
  printf '  package really has to read it, give it a named accessor instead,\n'
  printf '  which this audit can see and account for.\n'
  exit 1
fi

# The symbols whose only evidence is a shared name pass — the audit has nothing
# against them — but the *set* is pinned, so growing it is a decision someone
# made rather than a line in a passing run nobody read. That is the difference
# between "we know this is fine" and "we cannot tell", which a green check
# otherwise flattens into one thing.
ambiguous_snapshot=".github/scripts/internal_surface.ambiguous"
ambiguous_now=$(printf '%s' "$ambiguous" | sed 's/ (.*//' | LC_ALL=C sort -u)
if [ "$write" -eq 1 ]; then
  if [ -z "$ambiguous_now" ]; then
    rm -f "$ambiguous_snapshot"
    printf 'internal surface: nothing rests on a name alone; removed %s\n' \
      "$ambiguous_snapshot"
    exit 0
  fi
  printf '%s\n' "$ambiguous_now" >"$ambiguous_snapshot"
  printf 'internal surface: wrote %s (%s entries)\n' "$ambiguous_snapshot" \
    "$(printf '%s' "$ambiguous_now" | grep -c . || true)"
  exit 0
fi
if [ -f "$ambiguous_snapshot" ]; then
  if ! amb_diff=$(printf '%s\n' "$ambiguous_now" |
    diff -u "$ambiguous_snapshot" - 2>&1); then
    printf 'internal surface: the set credited by name only changed:\n'
    printf '%s\n' "$amb_diff" | sed 's/^/  /'
    printf '  A symbol here has no evidence but a receiver call on a shared\n'
    printf '  method name, or a bare free-function token — the audit cannot say\n'
    printf '  which type or which binding was meant. One appearing is worth a\n'
    printf '  look: an owner-qualified call (`Bitmap::len(b)`) settles it, and\n'
    printf '  so does making the symbol private and seeing what breaks. If it\n'
    printf '  is genuinely unsettleable, regenerate:\n'
    printf '    sh .github/scripts/check_internal_surface.sh --write\n'
    exit 1
  fi
elif [ -n "$ambiguous_now" ]; then
  printf 'internal surface: %s is missing — run with --write to create it\n' \
    "$ambiguous_snapshot"
  exit 1
fi
if [ -n "$ambiguous" ]; then
  printf 'internal surface: credited by a shared name, not by an owner:\n'
  printf '%s' "$ambiguous" | sed 's/^/  /'
fi

# "Audited", not "reachable": the total counts every symbol the run looked at,
# which includes the ones the allowlist excuses for having no caller at all and
# the ones credited by a shared name. Saying "reachable" claimed evidence the
# run does not have.
ambiguous_n=$(printf '%s' "$ambiguous" | grep -c . || true)

# The `pub impl` / `pub extend` lines join the derived methods already counted
# per symbol above: real surface, reachable only through `==` or a trait bound,
# so no name-based rule can find their callers. Counting them keeps that gap
# visible instead of implied — and the interfaces carrying them are tracked, so
# one appearing is a diff either way.
for mbti in $(git ls-files 'internal/*/pkg.generated.mbti'); do
  [ -f "$mbti" ] || continue
  impls=$(grep -c '^pub impl \|^pub extend ' "$mbti" || true)
  generated_n=$((generated_n + impls))
done

printf 'internal surface: %s internal `pub` symbols audited' "$checked"
printf ' (%s allowlisted, %s settled by the compiler in %s probes,\n' \
  "$allowlisted" "$settled" "$probe_runs"
printf '  %s by name only), no published field;\n' "$ambiguous_n"
printf '  %s derived / impl symbols in the generated interfaces are outside the audit\n' \
  "$generated_n"
