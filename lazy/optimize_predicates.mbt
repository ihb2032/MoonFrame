///|
/// The predicate pass driver: sink each `Filter` toward the scan so rows drop
/// as early as possible. `push_predicates` rewrites the plan bottom-up and
/// `place_filter` sinks one predicate through the stages it may cross. The
/// crossing-soundness rules those two consult (`row_stable`, `signed_zero_safe`,
/// `group_cell_stable`, the bare-column / row-count / defines tests) live in
/// `optimize_predicate_rules.mbt`; the whole-optimizer overview is on `optimize`
/// in `optimize.mbt`.

///|
/// The predicate pass: push every input first, then sink a `Filter` into its
/// now-rewritten input through `place_filter`. Every other node is already done
/// once its children are pushed, so only `Filter` needs a local step. Bottom-up
/// order is what lets a stack of filters sink as a unit — the lower filter is
/// already in place when the upper one descends onto it — while their relative
/// evaluation order never changes.
///
/// Walked iteratively (a `post_order` linearisation plus an explicit value
/// stack of rebuilt plans, not the call stack), so a deeply nested plan
/// optimizes without overflowing and aborting — the same never-abort treatment
/// the expression walks (`row_stable`, `eval_expr`) already carry. Each node is
/// rebuilt from its already-rebuilt children (popped off the stack top); a
/// rebuilt `Filter` then sinks through `place_filter`. Total: every arm is plain
/// data work.
fn push_predicates(plan : LogicalPlan) -> LogicalPlan {
  let values : Array[LogicalPlan] = []
  for node in post_order(plan) {
    match node {
      Scan(_) | ScanCsv(_, _, _, _) | ScanNdjson(_, _, _, _) =>
        values.push(node)
      // A `Filter` sinks into its rewritten input via `place_filter`; every
      // other unary op is an identity rebuild over its already-rewritten child.
      Unary(_, Filter(predicate)) =>
        values.push(place_filter(pop_top(values), predicate))
      Unary(_, op) => values.push(Unary(pop_top(values), op))
      Join(_, _, options) => {
        let right = pop_top(values)
        let left = pop_top(values)
        values.push(Join(left, right, options))
      }
      Aggregate(_, keys, exprs) =>
        values.push(Aggregate(pop_top(values), keys, exprs))
    }
  }
  pop_top(values)
}

///|
/// Sink one predicate into `input` as deep as the crossing rules allow
/// (see the header), wrapping the floor it reaches in the `Filter` node.
/// Each hop reproduces the crossed stage verbatim above the descending
/// filter, so `place_filter(input, p)` is always plan-equivalent to
/// `Filter(input, p)` — the hops are exactly the swaps proven safe.
/// Walked iteratively (descend the single-child spine recording each crossed
/// stage as a rebuild closure, not the call stack), so a deep crossable spine
/// sinks without overflowing and aborting — total at any depth.
fn place_filter(input : LogicalPlan, predicate : @expr.Expr) -> LogicalPlan {
  // Descend while the current stage is crossable, recording how to rebuild each
  // crossed stage over a new input; stop at the first floor.
  let crossed : Array[(LogicalPlan) -> LogicalPlan] = []
  let mut cur = input
  let mut descending = true
  while descending {
    match cur {
      Unary(inner, Select(exprs)) =>
        if all_row_stable(exprs) &&
          preserves_row_count(exprs) &&
          reads_only_bare_columns(predicate, exprs) {
          crossed.push(ni => Unary(ni, Select(exprs)))
          cur = inner
        } else {
          descending = false
        }
      Unary(inner, WithColumns(exprs)) =>
        if all_row_stable(exprs) && defines_none_of(exprs, predicate) {
          crossed.push(ni => Unary(ni, WithColumns(exprs)))
          cur = inner
        } else {
          descending = false
        }
      Aggregate(inner, keys, exprs) =>
        if row_stable(predicate) &&
          all_row_stable(keys) &&
          reads_only_bare_columns(predicate, keys) &&
          signed_zero_safe(predicate) &&
          all_group_cells_stable(exprs) {
          crossed.push(ni => Aggregate(ni, keys, exprs))
          cur = inner
        } else {
          descending = false
        }
      // Every other node is a floor: the in-memory / file scans, a `Join`, and
      // any other unary op (`Sort` / `Head` / a second `Filter` / …) a dropping
      // filter must not cross.
      Scan(_)
      | ScanCsv(_, _, _, _)
      | ScanNdjson(_, _, _, _)
      | Unary(_, _)
      | Join(_, _, _) => descending = false
    }
  }
  // The floor is `cur`. A file source takes the predicate *into* the read
  // (push-down proper: it builds the predicate's columns, prunes the rows, and
  // only then parses the rest), so no `Filter` node remains above it. A scan
  // that already absorbed one keeps its own and the new predicate stays a
  // node above it — combining them would reorder which operand's evaluation
  // error surfaces first.
  //
  // Only a predicate that names at least one column may be absorbed. A
  // column-less predicate (a literal like `lit_bool(true)`, a no-input `map`)
  // reads no key columns, so the pruner would build a zero-column key frame;
  // INV7 collapses that to `0×0`, erasing the file's real row count and
  // dropping every row — `filter(true)` would return nothing where the eager
  // read keeps all. Such a predicate stays a `Filter` above the scan, where it
  // broadcasts over the fully-read frame exactly as the eager path does. (This
  // is the predicate mirror of the zero-match projection falling back to a full
  // read: a scan cannot carry a row count through an empty column set.)
  let names_a_column = !predicate.referenced_columns().is_empty()
  let mut result = match cur {
    ScanCsv(path, options, projection, None) if names_a_column =>
      ScanCsv(path, options, projection, Some(predicate))
    ScanNdjson(path, options, projection, None) if names_a_column =>
      ScanNdjson(path, options, projection, Some(predicate))
    _ => Unary(cur, Filter(predicate))
  }
  for i = crossed.length() - 1; i >= 0; i = i - 1 {
    let rewrap = crossed[i]
    result = rewrap(result)
  }
  result
}
