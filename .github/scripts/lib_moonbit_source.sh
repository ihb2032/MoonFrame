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
strip_noncode() {
  awk '
    {
      line = $0
      # A raw segment is text to the end of the line, whatever it contains.
      if (line ~ /^[ \t]*#\|/) { print ""; next }
      # An interpolated segment is text too, but `\{…}` inside it is code.
      if (line ~ /^[ \t]*\$\|/) {
        sub(/^[ \t]*\$\|/, "", line)
        instr = 1
      } else {
        instr = 0
      }
      out = ""
      esc = 0
      ininterp = 0
      depth = 0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (ininterp) {
          if (c == "{") depth++
          else if (c == "}") {
            depth--
            if (depth == 0) { ininterp = 0; out = out " "; continue }
          }
          out = out c
          continue
        }
        if (instr) {
          if (esc) {
            esc = 0
            # `\{` opens an interpolation; every other escape is just text.
            if (c == "{") { ininterp = 1; depth = 1; out = out " " }
            continue
          }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") { instr = 0; out = out "\"" }
          continue
        }
        if (c == "\"") { instr = 1; out = out "\""; continue }
        if (c == "/" && i < n && substr(line, i + 1, 1) == "/") break
        out = out c
      }
      print out
    }'
}
