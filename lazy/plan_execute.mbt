///|
/// The engine behind `collect`: a bottom-up plan interpreter that delegates
/// each node to the public eager operator it defers, plus the `Scan`-leaf and
/// `Unary`-node halves (`execute_scan`, `apply_frame_op`). Split from
/// `logical_plan.mbt` so plan execution and plan display (`plan_render.mbt`)
/// each read apart from the IR they walk.

///|
/// Bottom-up plan interpreter — the whole of `collect`. Each node
/// delegates to the public eager operator it mirrors (`Filter` →
/// `filter`, `WithColumns` → `with_columns`, …), so with no
/// optimizer in front the lazy layer is a *faithful deferred executor*:
/// collecting a plan is equal to running the same verbs eagerly in
/// the same order. Errors are exactly the eager operators' errors,
/// surfacing here rather than at build time. `Scan` returns the captured
/// frame as-is — frames are immutable, so no defensive copy is needed.
/// A file source (a `Csv` / `Ndjson` scan) reads through `@io` —
/// `read_csv` / `read_ndjson` for the as-built plan (every column) or
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
      Scan(source) => execute_scan(source)
      // Every unary verb defers through `apply_frame_op` on its collected input.
      Unary(input, op) => apply_frame_op(memo_result(memo, input), op)
      Join(left, right, options) =>
        memo_result(memo, left).join(memo_result(memo, right), options)
      Aggregate(input, keys, exprs) =>
        memo_result(memo, input).group_by(keys).agg(exprs)
    }
    memo.push((node, result))
  }
  memo_result(memo, plan)
}

///|
/// Read one `ScanSource` into a frame — the `Scan` leaf's half of `execute`. An
/// in-memory source returns its captured frame as-is (frames are immutable, so
/// no defensive copy); a file source reads through `@io` — the pruned reader
/// when the optimizer absorbed a predicate, the projected reader once it filled
/// a projection, the whole-file reader otherwise — so a missing file (`IoError`)
/// or a parse failure (`ParseError`) surfaces here. One place to add a new
/// scannable format's read.
fn execute_scan(source : ScanSource) -> @frame.DataFrame raise @types.DataError {
  match source {
    InMemory(df) => df
    // Hand `io` the predicate's column names and a row-selection callback rather
    // than the expression itself, so the reader stays below the expression
    // language (see `read_csv_pruned`).
    Csv(path, options, projection, predicate) =>
      match predicate {
        Some(pred) =>
          @io.read_csv_pruned(
            path,
            options,
            projection,
            predicate_columns(pred),
            df => @frame.filter_row_indices(df, pred),
          )
        None =>
          match projection {
            None => @io.read_csv(path, options~)
            Some(columns) => @io.read_csv_projected(path, options, columns)
          }
      }
    Ndjson(path, options, projection, predicate) =>
      match predicate {
        Some(pred) =>
          @io.read_ndjson_pruned(
            path,
            options,
            projection,
            predicate_columns(pred),
            df => @frame.filter_row_indices(df, pred),
          )
        None =>
          match projection {
            None => @io.read_ndjson(path, options~)
            Some(columns) => @io.read_ndjson_projected(path, options, columns)
          }
      }
  }
}

///|
/// Apply one deferred unary op to a collected input frame — the `Unary` node's
/// half of `execute`. Each arm delegates to the public eager `DataFrame` verb
/// it mirrors, so `collect` stays bit-for-bit the eager result and the errors
/// are exactly the eager operators'. One place to add a new unary verb's
/// execution.
fn apply_frame_op(
  df : @frame.DataFrame,
  op : FrameOp,
) -> @frame.DataFrame raise @types.DataError {
  match op {
    Select(exprs) => df.select(exprs)
    WithColumns(exprs) => df.with_columns(exprs)
    Filter(predicate) => df.filter(predicate)
    Sort(by) => df.sort(by)
    Head(n) => df.head(n)
    Tail(n) => df.tail(n)
    Slice(start, end) => df.slice(start, end)
    Drop(exprs) => df.drop(exprs)
    Rename(pairs) => df.rename(pairs)
    RenameWith(f) => df.rename_with(f)
    Unique(keep, subset) =>
      match subset {
        None => df.unique(keep~)
        Some(keys) => df.unique(subset=keys, keep~)
      }
    Reverse => df.reverse()
    WithRowIndex(name, offset) => df.with_row_index(name~, offset~)
    DropNulls(subset) => df.drop_nulls(subset?)
    FillNull(value) => df.fill_null(value)
    // Each reduction executes as its eager `DataFrame` verb on the collected
    // input, so `collect` is bit-for-bit the eager 1-row result.
    Reduce(op) =>
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

///|
/// The columns an absorbed scan predicate reads, as a plain name list — the
/// shape the `io` pruned readers take, so they never see an `Expr`. Order is
/// irrelevant: the reader filters its own header order by membership.
fn predicate_columns(predicate : @expr.Expr) -> Array[String] {
  let names : Array[String] = []
  for name in predicate.referenced_columns() {
    names.push(name)
  }
  names
}
