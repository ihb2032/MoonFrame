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
# Read MoonBit source on stdin, write it back with string contents and
# trailing `//` comments removed.
#
# Character by character rather than by regex, because `s/"[^"]*"//` gets an
# escaped quote wrong in the dangerous direction: in
# `let m = "prefix \" name"` it takes `"prefix \"` for the whole string and
# leaves the rest standing as code, inventing a use rather than losing one.
# The scan tracks three things — inside a string, just after a backslash, past
# a `//` — which is all MoonBit needs: it has no block comments, and a string
# literal cannot span a line.
strip_noncode() {
  awk '{
    out = ""
    instr = 0
    esc = 0
    n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (instr) {
        if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == "\"") { instr = 0; out = out "\"" }
        continue
      }
      if (c == "\"") { instr = 1; out = out "\""; continue }
      if (c == "/" && i < n && substr($0, i + 1, 1) == "/") break
      out = out c
    }
    print out
  }'
}
