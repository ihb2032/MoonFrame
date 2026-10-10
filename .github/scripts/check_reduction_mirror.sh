#!/bin/sh
# The lazy whole-frame reduction enum is a mirror of the frame one:
# `LazyReduceOp` (lazy/logical_plan.mbt) re-spells `FrameReduceOp`
# (frame/stats.mbt) plus `NullCount`, because the frame tag is `priv` to
# its package and the lazy plan needs its own closed set to defer through.
# The mirror is the cheaper of the two designs — unifying the enums would
# widen the engine-seam surface and still leave the executor its match —
# but nothing in the compiler holds the two member sets together: both are
# private, so the enum-surface lock, which reads generated interfaces,
# cannot see either one. This guard does. A member added to one enum and
# not the other is a lazy verb silently missing (or a tag spelling a verb
# no eager reducer answers), caught here at the source instead of by the
# first user who notices the asymmetry.
#
# Usage: check_reduction_mirror.sh [repo-root]
# Exit 0 when the sets agree modulo `NullCount`, 1 with a report.

set -eu

root=$(cd "${1:-.}" && pwd)

# members <file> <enum-name>: the variant identifiers of a private enum,
# payloads and comments stripped (`Quantile(Double, …)` reads as
# `Quantile`), declaration order irrelevant to the comparison.
members() {
  file=$1
  name=$2
  awk -v n="$name" '
    $0 ~ "^priv enum " n "[[:space:]]*\\{" { inside = 1; next }
    inside && /^}/ { exit }
    inside {
      sub(/\/\/.*/, "")
      gsub(/[[:space:]]/, "")
      if ($0 == "") next
      sub(/\(.*/, "")
      print
    }
  ' "$root/$file"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
members frame/stats.mbt FrameReduceOp | sort >"$work/frame"
members lazy/logical_plan.mbt LazyReduceOp | grep -v '^NullCount$' | sort >"$work/lazy"

if cmp -s "$work/frame" "$work/lazy"; then
  count=$(wc -l <"$work/frame" | tr -d ' ')
  echo "reduction mirror: LazyReduceOp re-spells FrameReduceOp plus NullCount ($count shared members)"
  exit 0
fi

echo "reduction mirror: LazyReduceOp (lazy/logical_plan.mbt) no longer re-spells"
echo "FrameReduceOp (frame/stats.mbt) plus NullCount — the private mirror drifted:"
only_frame=$(comm -23 "$work/frame" "$work/lazy" | tr '\n' ' ')
only_lazy=$(comm -13 "$work/frame" "$work/lazy" | tr '\n' ' ')
[ -n "$only_frame" ] && echo "  in FrameReduceOp only: $only_frame"
[ -n "$only_lazy" ] && echo "  in LazyReduceOp only (beyond NullCount): $only_lazy"
echo "  add the member to both enums (or record why the sets now differ)."
exit 1
