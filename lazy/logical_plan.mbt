///|
/// The deferred query IR behind `LazyFrame`: a private tree with one node
/// per eager `DataFrame` verb, and nothing else — the tree's consumers each
/// read in a file of their own: the traversal helpers every walker shares
/// (`lazy/plan_walk.mbt`), plan execution (`lazy/plan_execute.mbt`,
/// `execute` behind `collect`), and plan display (`lazy/plan_render.mbt`,
/// `render` behind `explain`). The enum stays `priv`: every
/// `match` over it lives in this package, so nothing of the IR leaks into
/// the public surface (`LazyFrame` exposes builders and the two walkers' results
/// only). Building nodes is total — a plan is plain data — and every failure a
/// pipeline can produce is deferred to `execute`, which surfaces the
/// underlying eager operator's `DataError`.
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
/// The `Csv` and `Ndjson` sources of a `Scan` leaf *read* at collect time
/// rather than capturing an already-built frame: each holds a path, the
/// format's read options (`CsvReadOptions` / `JsonReadOptions`) to parse
/// under, and an optional projection. The projection starts empty (`None` —
/// read every column, the faithful mirror of eager `read_csv` /
/// `read_ndjson`) and is filled by the optimizer's projection pass with the
/// columns a pipeline provably consumes, so the parser builds only those.
/// The fourth field is an absorbed **predicate**: the optimizer moves a filter
/// sitting on the leaf into the node, and the reader then builds the
/// predicate's columns, prunes the rows, and parses the rest for the survivors
/// alone (streaming the file itself is still future work). Unlike the in-memory
/// `Scan`, whose narrowing *inserts* a `Select`, a file source narrows in
/// place by carrying its own projection. (There is no `ScanJson` for the
/// single-array shape `[{...}]`: a JSON array must be parsed whole to find its
/// records, so there is nothing to prune at read time — the same reason Polars
/// has `scan_ndjson` but no `scan_json`.)
priv enum LogicalPlan {
  Scan(ScanSource)
  Unary(LogicalPlan, FrameOp)
  Join(LogicalPlan, LogicalPlan, @frame.JoinOptions)
  Aggregate(LogicalPlan, Array[@expr.Expr], Array[@expr.Expr])
}

///|
/// The leaf a `Scan` node reads at collect time — an in-memory frame or a file
/// source. Collapsing the three per-format `LogicalPlan` scan variants this
/// replaced behind one `Scan(ScanSource)` leaf keeps each per-source concern in
/// one ScanSource-keyed place — execution (`execute_scan`), rendering
/// (`write_scan_label`), and the projection / predicate push-down
/// (`narrow_scan_source` and `place_filter`'s floor) — so a new scannable format
/// adds a `ScanSource` variant to those few functions rather than a
/// `LogicalPlan` variant to every plan walk. A file source carries the pushed
/// projection (the column list) and the absorbed predicate the optimizer fills
/// in; the in-memory source carries neither (its narrowing inserts a `Select`).
priv enum ScanSource {
  InMemory(@frame.DataFrame)
  Csv(String, @io.CsvReadOptions, Array[String]?, @expr.Expr?)
  Ndjson(String, @io.JsonReadOptions, Array[String]?, @expr.Expr?)
}

///|
/// The single-input frame operation a `Unary` node defers — one per eager
/// `DataFrame` verb it mirrors. Collapsing the former sixteen unary
/// `LogicalPlan` variants behind one `Unary(input, FrameOp)` keeps each per-op
/// concern in one FrameOp-keyed place — execution (`apply_frame_op`), rendering
/// (`write_frame_op_label`), the projection requirement (`frame_op_required`),
/// and the predicate-crossing rule (in `place_filter`'s descent) — so a new verb
/// adds a `FrameOp` arm to those few functions rather than a variant to every
/// plan walk (`plan_children`, `execute`, the two optimizer passes, `render`).
/// `Filter` is a `FrameOp` like the rest; the predicate pass singles it out by
/// matching `Unary(_, Filter(_))`.
priv enum FrameOp {
  Select(Array[@expr.Expr])
  WithColumns(Array[@expr.Expr])
  Filter(@expr.Expr)
  Sort(Array[(@expr.Expr, @types.SortOrder, @types.NullOrder)])
  Head(Int)
  Tail(Int)
  Slice(Int, Int)
  Drop(Array[@expr.Expr])
  Rename(Array[(String, String)])
  RenameWith((String) -> String)
  Unique(@frame.KeepStrategy, Array[@expr.Expr]?)
  Reverse
  WithRowIndex(String, Int64)
  DropNulls(Array[@expr.Expr]?)
  FillNull(@types.Scalar)
  Reduce(LazyReduceOp)
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
