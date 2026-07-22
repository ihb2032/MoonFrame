///|
/// The deferred query IR behind `LazyFrame`: a private tree with one node
/// per eager `DataFrame` verb, plus the two walkers that consume it —
/// `execute` (the `collect` engine) and `render` (the `explain` printer).
/// The enum stays `priv`: every `match` over it lives in this package, so
/// nothing of the IR leaks into the public surface (`LazyFrame` exposes
/// builders and the two walkers only). Building nodes is total — a plan is
/// plain data — and every failure a pipeline can produce is deferred to
/// `execute`, which surfaces the underlying eager operator's `DataError`.
///
/// `Head` / `Tail` are nodes of their own rather than sugar over `Slice`:
/// the eager `head` / `tail` clamp out-of-range `n` and never fail, while
/// `slice` bounds-checks and raises. Folding them into `Slice` would need
/// the input's row count at *build* time (a lazy plan doesn't have it) or
/// would trade the clamp for a spurious `IndexOutOfBounds` at collect
/// time — breaking the executor's faithfulness contract. One node per
/// distinct eager semantic keeps `collect ≡ eager` literally true.
///
/// `Aggregate` is the one *fused* node — `group_by(keys).agg(exprs)`
/// in a single step — because the eager intermediate (`GroupedDataFrame`)
/// is not a frame: every plan stage must output rows, so the keys ride on
/// `LazyGroupBy` (plain builder state, no node) until `agg` completes
/// them into a plan stage that does.
///
/// `ScanCsv` and `ScanNdjson` are the leaves that *read* at collect time
/// rather than capturing an already-built frame: each holds a path, the
/// format's read options (`CsvReadOptions` / `JsonReadOptions`) to parse
/// under, and an optional projection. The projection starts empty (`None` —
/// read every column, the faithful mirror of eager `read_csv` /
/// `read_ndjson`) and is filled by the optimizer's projection pass with the
/// columns a pipeline provably consumes, so the parser builds only those —
/// the one push-down that reaches an external source in v0.5 (predicate
/// push-down into the parser and streaming are v0.6). Unlike the in-memory
/// `Scan`, whose narrowing *inserts* a `Select`, a file source narrows in
/// place by carrying its own projection. (There is no `ScanJson` for the
/// single-array shape `[{...}]`: a JSON array must be parsed whole to find its
/// records, so there is nothing to prune at read time — the same reason Polars
/// has `scan_ndjson` but no `scan_json`.)
priv enum LogicalPlan {
  Scan(@frame.DataFrame)
  ScanCsv(String, @io.CsvReadOptions, Array[String]?)
  ScanNdjson(String, @io.JsonReadOptions, Array[String]?)
  Select(LogicalPlan, Array[@expr.Expr])
  WithColumns(LogicalPlan, Array[@expr.Expr])
  Filter(LogicalPlan, @expr.Expr)
  Sort(LogicalPlan, Array[(@expr.Expr, @frame.SortOrder, @frame.NullOrder)])
  Head(LogicalPlan, Int)
  Tail(LogicalPlan, Int)
  Slice(LogicalPlan, Int, Int)
  Join(LogicalPlan, LogicalPlan, @frame.JoinOptions)
  Aggregate(LogicalPlan, Array[@expr.Expr], Array[@expr.Expr])
  Drop(LogicalPlan, Array[@expr.Expr])
  Rename(LogicalPlan, Array[(String, String)])
  RenameWith(LogicalPlan, (String) -> String)
  Unique(LogicalPlan, @frame.KeepStrategy)
  DropNulls(LogicalPlan, Array[@expr.Expr]?)
  FillNull(LogicalPlan, @types.Scalar)
  Reduce(LogicalPlan, LazyReduceOp)
}

///|
/// Which whole-frame reduction a `Reduce` node defers — one per `LazyFrame`
/// reduction method, each executing as the matching eager `DataFrame` verb
/// (`sum` / `mean` / `min` / `max` / `count` / `null_count`) so `collect` is
/// bit-for-bit the eager result. A closed set mirroring `frame`'s private
/// `FrameReduceOp` (plus `NullCount`), kept lazy-local because that tag is
/// `priv` to `frame`.
priv enum LazyReduceOp {
  Sum
  Mean
  Min
  Max
  Count
  NullCount
}

///|
/// The child plans of a node, left-to-right — the `LogicalPlan` analogue of
/// `Expr::children`, and the one place the IR's recursive shape is enumerated
/// for *traversal* (the rebuild passes enumerate it again to reassemble). A
/// leaf (`Scan` / `ScanCsv` / `ScanNdjson`) has none; `Join` has two; every
/// other node has exactly one. Drives the explicit-stack walks (`render`,
/// `post_order`) so a new node joins them the moment it declares its children
/// here.
fn plan_children(plan : LogicalPlan) -> Array[LogicalPlan] {
  match plan {
    Scan(_) | ScanCsv(_, _, _) | ScanNdjson(_, _, _) => []
    Select(input, _)
    | WithColumns(input, _)
    | Filter(input, _)
    | Sort(input, _)
    | Head(input, _)
    | Tail(input, _)
    | Slice(input, _, _)
    | Aggregate(input, _, _)
    | Drop(input, _)
    | Rename(input, _)
    | RenameWith(input, _)
    | Unique(input, _)
    | DropNulls(input, _)
    | FillNull(input, _)
    | Reduce(input, _) => [input]
    Join(left, right, _) => [left, right]
  }
}

///|
/// Plan nodes in post-order — every node's children before the node itself,
/// left subtree before right — built with an explicit stack (not the call
/// stack), so an arbitrarily deep plan linearises without overflowing and
/// aborting. The post-order/value-stack walks (`execute`, `push_predicates`)
/// fold children before parents by stepping this list front-to-back: when a
/// node is reached, its children's results are the top of the value stack.
fn post_order(plan : LogicalPlan) -> Array[LogicalPlan] {
  // Root-first pre-order via a LIFO stack (children pushed left-to-right, so
  // the right subtree pops first), then reversed into post-order.
  let pre : Array[LogicalPlan] = []
  let stack : Array[LogicalPlan] = [plan]
  while stack.length() > 0 {
    let node = pop_top(stack)
    pre.push(node)
    for child in plan_children(node) {
      stack.push(child)
    }
  }
  Array::makei(pre.length(), i => pre[pre.length() - 1 - i])
}

///|
/// Pop the top of an explicit walk's value stack. The post-order walks push a
/// rebuilt value for every child before its parent combines, so the stack is
/// never empty here; the top slot is read by that stack-invariant index — total,
/// like the engine's other indexed reads — and dropped, never `unwrap` (which
/// would leave a dead `None` arm and break coverage).
fn[T] pop_top(stack : Array[T]) -> T {
  let top = stack[stack.length() - 1]
  let _ = stack.pop()
  top
}

///|
/// Whether `node` is already in `seen`, by **physical identity** — the
/// object, not its value. `LazyFrame::join` stores the other frame's plan by
/// reference, so `lf.join(lf, …)` builds a DAG whose `Join` holds the same
/// node object twice; identity is what tells a genuinely shared subplan from
/// two equal-but-separate builds. Linear scan: a plan's distinct-node count
/// is small, and the callers' overall cost stays quadratic in it at worst.
fn seen_plan(seen : Array[LogicalPlan], node : LogicalPlan) -> Bool {
  for p in seen {
    if physical_equal(p, node) {
      return true
    }
  }
  false
}

///|
/// Whether the plan is DAG-shaped: some node object reachable twice (nested
/// self-joins built from a shared `LazyFrame`). The walk marks every node by
/// identity and stops at the first repeat, so it is linear in the number of
/// distinct nodes even on a deeply shared plan — it never re-expands what it
/// has already seen.
fn has_shared_subplan(plan : LogicalPlan) -> Bool {
  let seen : Array[LogicalPlan] = []
  let stack : Array[LogicalPlan] = [plan]
  while stack.length() > 0 {
    let node = pop_top(stack)
    if seen_plan(seen, node) {
      return true
    }
    seen.push(node)
    for child in plan_children(node) {
      stack.push(child)
    }
  }
  false
}

///|
/// Plan nodes in post-order with each *distinct* node exactly once — the
/// identity-deduplicated walk `execute` folds over. On a tree it yields
/// exactly `post_order`'s sequence (left subtree, right subtree, node); on a
/// DAG-shaped plan each shared subplan is listed once, before its first
/// consumer (children always precede parents), so a fold that reads child
/// results out of a memo does each subplan's work once instead of once per
/// occurrence — which is 2^depth for nested self-joins.
fn post_order_unique(plan : LogicalPlan) -> Array[LogicalPlan] {
  let out : Array[LogicalPlan] = []
  let seen : Array[LogicalPlan] = []
  // (node, expanded): expanded=false schedules the node (skipping it if a
  // previous path already claimed it), expanded=true emits it — by then all
  // its children have been emitted.
  let stack : Array[(LogicalPlan, Bool)] = [(plan, false)]
  while stack.length() > 0 {
    let (node, expanded) = pop_top(stack)
    if expanded {
      out.push(node)
      continue
    }
    if seen_plan(seen, node) {
      continue
    }
    seen.push(node)
    stack.push((node, true))
    let kids = plan_children(node)
    for i in 0..<kids.length() {
      stack.push((kids[kids.length() - 1 - i], false))
    }
  }
  out
}

///|
/// The memoised result of `node`, scanned newest-first so the common case —
/// a linear pipeline reading the frame computed immediately before — hits on
/// the first probe. `post_order_unique` emits every child before its parent,
/// so the scan always finds its node; the `idx` initialiser is the total
/// fallback for that impossible miss (mirroring `pop_top`'s
/// stack-invariant indexed read).
fn memo_result(
  memo : Array[(LogicalPlan, @frame.DataFrame)],
  node : LogicalPlan,
) -> @frame.DataFrame {
  let mut idx = 0
  for i = memo.length() - 1; i >= 0; i = i - 1 {
    if physical_equal(memo[i].0, node) {
      idx = i
      break
    }
  }
  memo[idx].1
}

///|
/// Bottom-up plan interpreter — the whole of `collect`. Each node
/// delegates to the public eager operator it mirrors (`Filter` →
/// `filter`, `WithColumns` → `with_columns`, …), so with no
/// optimizer in front the lazy layer is a *faithful deferred executor*:
/// collecting a plan is bitwise-equal to running the same verbs eagerly in
/// the same order. Errors are exactly the eager operators' errors,
/// surfacing here rather than at build time. `Scan` returns the captured
/// frame as-is — frames are immutable, so no defensive copy is needed.
/// A file source (`ScanCsv` / `ScanNdjson`) reads through `@io` —
/// `read_*_with_options` for the as-built plan (every column) or
/// `read_*_projected` once the optimizer has filled its projection — so a
/// missing file (`IoError`) or a parse failure (`ParseError`) surfaces here
/// too.
fn execute(plan : LogicalPlan) -> @frame.DataFrame raise @types.DataError {
  // Memoised post-order fold (not the call stack), so a deep plan collects
  // without overflowing and aborting — the never-abort contract the
  // expression evaluator (`eval_expr`) also keeps. Each node applies the
  // same eager verb its recursive form did, reading its child frame(s) out
  // of the memo by node identity; a leaf computes the frame it reads. On a
  // tree this is the exact old deepest-first order (a `Join`'s left before
  // its right), so a failing plan surfaces the same `DataError` first; on a
  // DAG-shaped plan (nested self-joins sharing node objects) each shared
  // subplan runs ONCE — including a file source's read — where the
  // per-occurrence fold re-ran it 2^depth times.
  let memo : Array[(LogicalPlan, @frame.DataFrame)] = []
  for node in post_order_unique(plan) {
    let result : @frame.DataFrame = match node {
      Scan(df) => df
      ScanCsv(path, options, projection) =>
        match projection {
          None => @io.read_csv(path, options~)
          Some(columns) => @io.read_csv_projected(path, options, columns)
        }
      ScanNdjson(path, options, projection) =>
        match projection {
          None => @io.read_ndjson(path, options~)
          Some(columns) => @io.read_ndjson_projected(path, options, columns)
        }
      Select(input, exprs) => memo_result(memo, input).select(exprs)
      WithColumns(input, exprs) => memo_result(memo, input).with_columns(exprs)
      Filter(input, predicate) => memo_result(memo, input).filter(predicate)
      Sort(input, by) => memo_result(memo, input).sort(by)
      Head(input, n) => memo_result(memo, input).head(n)
      Tail(input, n) => memo_result(memo, input).tail(n)
      Slice(input, start, end) => memo_result(memo, input).slice(start, end)
      Join(left, right, options) =>
        memo_result(memo, left).join(memo_result(memo, right), options)
      Aggregate(input, keys, exprs) =>
        memo_result(memo, input).group_by(keys).agg(exprs)
      Drop(input, exprs) => memo_result(memo, input).drop(exprs)
      Rename(input, pairs) => memo_result(memo, input).rename(pairs)
      RenameWith(input, f) => memo_result(memo, input).rename_with(f)
      Unique(input, keep) => memo_result(memo, input).unique(keep~)
      DropNulls(input, subset) => memo_result(memo, input).drop_nulls(subset?)
      FillNull(input, value) => memo_result(memo, input).fill_null(value)
      // Each reduction executes as its eager `DataFrame` verb on the collected
      // input, so `collect` is bit-for-bit the eager 1-row result.
      Reduce(input, op) => {
        let df = memo_result(memo, input)
        match op {
          Sum => df.sum()
          Mean => df.mean()
          Min => df.min()
          Max => df.max()
          Count => df.count()
          NullCount => df.null_count()
        }
      }
    }
    memo.push((node, result))
  }
  memo_result(memo, plan)
}
