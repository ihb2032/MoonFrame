# Shared source-reading helpers for the guards that look for a symbol's callers.
#
# Sourced, not executed: `. "$(dirname "$0")/lib_moonbit_source.sh"`.
#
# What lives here is the one thing both caller scans need and neither should
# get subtly different: knowing which parts of a line are code. A guard that
# greps raw text counts `let msg = "validity_bools("` and
# `do_work() // validity_bools(` as calls, and a seam nothing calls then reads
# as live — the failure direction that matters, because these scans exist to
# find what is *not* used.

###|
# Read MoonBit source on stdin, write it back with everything that is not code
# removed: string *contents*, and trailing `//` comments.
#
# Character by character rather than by regex, because `s/"[^"]*"//` gets an
# escaped quote wrong in the dangerous direction: in
# `let m = "prefix \" name"` it takes `"prefix \"` for the whole string and
# leaves the rest standing as code, inventing a use rather than losing one.
#
# Three shapes of string, and the interpolation that runs through two of them:
#
#   "text \{expr}"   double-quoted, `\{…}` evaluates an expression
#   #| text          raw multi-line segment — no interpolation, runs to EOL
#   $| text \{expr}  interpolated multi-line segment, likewise to EOL
#
# So "inside a string" is not the same as "not code". The text is dropped and
# every `\{…}` is kept, because a call written there is a call: missing it
# would report a symbol as unused, and keeping the surrounding prose would
# report prose as a use. A `#|` line is dropped whole — nothing in it runs.
# The scan is a mode stack, not a counter, because the shapes nest: an
# interpolation holds code, that code may hold another string, and that string
# may interpolate again. A counter that merely balances braces ends the
# interpolation at the first `}` it meets — including one inside a `'}'` char
# literal — and everything after it changes meaning: the rest of the string
# reads as code, or real code reads as string. Both directions are wrong for an
# audit whose answer is "is this symbol used".
#
#   CODE   `"` → STR   `'` → CHAR   `//` → rest of line is a comment
#   STR    `\{` → INTERP   `"` → pop   (contents dropped)
#   CHAR   `'` → pop                    (contents dropped)
#   INTERP `"` → STR   `'` → CHAR   `}` at depth 1 → pop   (contents kept)
strip_noncode() {
  awk '
    {
      line = $0
      # A raw segment is text to the end of the line, whatever it contains.
      if (line ~ /^[ \t]*#\|/) { print ""; next }
      sp = 0
      mode[0] = "code"
      # An interpolated segment is text too, but `\{…}` inside it is code.
      if (line ~ /^[ \t]*\$\|/) {
        sub(/^[ \t]*\$\|/, "", line)
        sp = 1
        mode[1] = "str"
      }
      out = ""
      esc = 0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        m = mode[sp]
        if (esc) {
          esc = 0
          # `\{` inside a string opens an interpolation; every other escape is
          # one more character of text (or of a char literal).
          if (c == "{" && m == "str") {
            sp++
            mode[sp] = "interp"
            dep[sp] = 1
            out = out " "
          }
          continue
        }
        if (m == "str" || m == "char") {
          if (c == "\\") { esc = 1; continue }
          if (m == "str" && c == "\"") { sp--; out = out "\"" ; continue }
          if (m == "char" && c == "\x27") { sp--; continue }
          continue
        }
        # code or interp: both are code, and both can open a literal.
        if (c == "\"") { sp++; mode[sp] = "str"; out = out "\""; continue }
        if (c == "\x27") { sp++; mode[sp] = "char"; continue }
        if (m == "interp") {
          if (c == "{") { dep[sp]++ }
          else if (c == "}") {
            if (dep[sp] == 1) { sp--; out = out " "; continue }
            dep[sp]--
          }
          out = out c
          continue
        }
        if (c == "/" && i < n && substr(line, i + 1, 1) == "/") break
        out = out c
      }
      print out
    }'
}
