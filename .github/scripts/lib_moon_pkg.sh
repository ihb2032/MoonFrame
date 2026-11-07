# Shared moon.pkg dependency reader for the guard scripts. Sourced, not
# executed: `. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib_moon_pkg.sh"`.
#
# Three guards read the same manifests — layering, engine seams, internal
# surface — and the one thing they must not get subtly different is the answer
# to "what does this package depend on". The reader each of them carried was a
# few lines of awk that knew exactly one shape: `import {` at column 0, items
# on their own lines, `}` at column 0. Every other spelling of a dependency
# vanished from the graph without a word — a block closed by an indented `}`,
# a brace nested inside the block, a dependency keyword the reader had never
# been told about (`preload`, say). A dependency the graph cannot see is a
# dependency no layering rule, no caller scan and no cycle check ever sees,
# which is a way past every guard that reads a manifest — so this reader
# refuses what it cannot parse, out loud, instead of guessing.
#
# The canonical form is what `moon fmt` writes, and what the reader accepts:
#
#   import {
#     "owner/module/pkg" @alias?,
#   }
#
# — the block opens with `import {` and closes with `}` at column 0, one
# quoted package path per line with an optional `@alias` after it, and an
# optional `for "test"` / `for "wbtest"` marker after the closer for a
# test-only block. A block that opens and closes on one line
# (`import { "owner/module/pkg" }`) is accepted and read the same way, as is
# content riding the opener line (`import { "owner/module/pkg",` then the
# block continuing). Everything else about dependencies is refused.
#
# The other statements the manifest DSL allows — `pkgtype(…)`, `options(…)`,
# `formatter(…)`, `rule(…)`, `dev_build(…)`, `warnings = …`,
# `supported_targets = …` — are configuration, not dependencies, and are
# skipped (multi-line ones included: the reader tracks their delimiters until
# they close). A statement whose head is none of those and not `import` fails
# the run: the day the DSL grows a dependency keyword, this failure is what
# makes someone teach the reader, instead of shipping a manifest every graph
# silently under-reads.
#
# moon_pkg_imports <manifest> <pkg> <module>
#   Prints one `<pkg> <dep>` line per *production* import of a package in
#   <module> — an import of <module> itself prints `root`, as the facade
#   package's path is the module name with nothing after it. Test-only blocks
#   (`for "test"` / `for "wbtest"`) are dropped. A manifest the reader refuses
#   prints one `FAIL <manifest>: <reason>` line and nothing else; the caller
#   treats any FAIL line as fatal, and every reason names the canonical form.

moon_pkg_imports() {
  # moon_pkg_imports <manifest> <pkg> <module>
  awk -v manifest="$1" -v pkg="$2" -v module="$3" '
    function fail(msg) {
      printf "FAIL %s: %s\n", manifest, msg
      failed = 1
      exit
    }
    # `moon.pkg` allows // comments, and one must not be able to hide — or
    # forge — a block closer or a kind marker, so every line is read
    # comment-free. (A package path never contains //; canonical manifests
    # never need one inside a string.)
    function strip(line) { sub(/\/\/.*/, "", line); return line }
    function trim(line) { gsub(/^[ \t]+/, "", line); gsub(/[ \t]+$/, "", line); return line }
    # Blank quoted strings so delimiter counting cannot be fooled by one.
    function mask(line) { gsub(/"[^"]*"/, "\"\"", line); return line }
    # The head word of a statement, for the whitelist dispatch.
    function head(line) { h = line; sub(/[^A-Za-z0-9_].*/, "", h); return h }
    # Read the items of one import block body: each quoted path that belongs
    # to <module> becomes a dep (`root` for the module itself). Anything on an
    # item line that is not quoted paths, `@alias`es, commas or whitespace is
    # refused — an import item has one shape.
    function take_items(line) {
      line = trim(line)
      if (line == "" || line == ",") return
      rest = line
      gsub(/"[^"]*"/, "", rest)
      gsub(/@[A-Za-z_][A-Za-z0-9_]*/, "", rest)
      gsub(/[ \t,]/, "", rest)
      if (rest != "")
        fail("import item is not a quoted package path: `" line "` — canonical items are \"owner/module/pkg\", one per line, optional @alias")
      s = line
      while (match(s, /"[^"]*"/)) {
        q = substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
        want = module "/"
        if (q == module) { dep[++n] = "root"; continue }
        if (index(q, want) == 1) {
          d = substr(q, length(want) + 1)
          if (d != "") dep[++n] = d
        }
      }
    }
    # The text after a block closer must be empty or the test-kind marker,
    # read on a comment-stripped line so a comment cannot forge or disguise
    # one (the rule the layering guard established for `} // for "test"`).
    function closer_kind(tail) {
      tail = trim(tail)
      if (tail == "") return ""
      if (tail ~ /^for[ \t]*"test"$/ || tail ~ /^for[ \t]*"wbtest"$/) return tail
      if (tail ~ /^for[ \t]*"/)
        fail("unknown import kind `" tail "` — only for \"test\" / for \"wbtest\" exist")
      fail("unexpected text after the import closer: `" tail "`")
    }
    BEGIN { state = "code" }
    {
      raw = $0
      line = trim(strip(raw))
      if (state == "consume") {
        m = mask(line)
        d += gsub(/\(/, "(", m) - gsub(/\)/, ")", m)
        d += gsub(/\[/, "[", m) - gsub(/\]/, "]", m)
        d += gsub(/\{/, "{", m) - gsub(/\}/, "}", m)
        if (d <= 0) state = "code"
        next
      }
      if (state == "import") {
        if (raw ~ /^\}/) {
          # The tail is read off the comment-stripped line, so a comment can
          # neither forge nor disguise the kind marker — `} // for "test"` is
          # a production block wearing a comment (the layering rule).
          kind = closer_kind(substr(line, 2))
          if (kind == "")
            for (i = 1; i <= n; i++) print pkg " " dep[i]
          n = 0
          state = "code"
          next
        }
        if (raw ~ /^[ \t]*\}/)
          fail("import block closed by an indented `}` — canonical form closes at column 0, optionally `} for \"test\"`")
        if (line ~ /[{}]/)
          fail("brace inside an import block — items are quoted package paths, one per line; the DSL has no nested block")
        take_items(line)
        next
      }
      # state == "code"
      if (line == "") next
      h = head(line)
      if (h == "import") {
        body = line
        sub(/^import[ \t]*\{/, "", body)
        if (body == line)
          fail("an import must open a block: `import {` — got `" line "`")
        if (index(body, "}") > 0) {
          # The whole block on one line: read it here, no block state.
          inner = substr(body, 1, index(body, "}") - 1)
          kind = closer_kind(substr(body, index(body, "}") + 1))
          n = 0
          take_items(inner)
          if (kind == "")
            for (i = 1; i <= n; i++) print pkg " " dep[i]
          n = 0
          next
        }
        n = 0
        state = "import"
        # Content riding the opener line is the first item line.
        take_items(body)
        next
      }
      if (h == "pkgtype" || h == "options" || h == "formatter" ||
          h == "rule" || h == "dev_build" || h == "warnings" ||
          h == "supported_targets") {
        m = mask(line)
        d = gsub(/\(/, "(", m) - gsub(/\)/, ")", m)
        d += gsub(/\[/, "[", m) - gsub(/\]/, "]", m)
        d += gsub(/\{/, "{", m) - gsub(/\}/, "}", m)
        if (d > 0) state = "consume"
        next
      }
      fail("unrecognised statement `" h "` — the reader knows import / pkgtype / options / formatter / rule / dev_build / warnings / supported_targets; a dependency keyword spelled any other way would vanish from every graph that reads this manifest")
    }
    END {
      if (failed) exit
      if (state == "import")
        printf "FAIL %s: import block never closed — canonical form closes with `}` at column 0\n", manifest
      if (state == "consume")
        printf "FAIL %s: a configuration statement never closed\n", manifest
    }
  ' "$1"
}
