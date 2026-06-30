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
/// format's read options (`CsvReadOptions` / `NdjsonReadOptions`) to parse
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
  ScanNdjson(String, @io.NdjsonReadOptions, Array[String]?)
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
  Unique(LogicalPlan)
  DropNulls(LogicalPlan, Array[@expr.Expr]?)
  FillNull(LogicalPlan, @types.Scalar)
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
    | Unique(input)
    | DropNulls(input, _)
    | FillNull(input, _) => [input]
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
  // Post-order fold on an explicit value stack (not the call stack), so a deep
  // plan collects without overflowing and aborting — the never-abort contract
  // the expression evaluator (`eval_expr`) also keeps. Each node applies the
  // same eager verb its recursive form did, reading its child frame(s) off the
  // stack top; a leaf pushes the frame it reads. The order matches the old
  // recursion exactly — deepest-first, a `Join`'s left before its right — so a
  // plan that fails surfaces the same `DataError` first.
  let values : Array[@frame.DataFrame] = []
  for node in post_order(plan) {
    match node {
      Scan(df) => values.push(df)
      ScanCsv(path, options, projection) =>
        values.push(
          match projection {
            None => @io.read_csv_with_options(path, options)
            Some(columns) => @io.read_csv_projected(path, options, columns)
          },
        )
      ScanNdjson(path, options, projection) =>
        values.push(
          match projection {
            None => @io.read_ndjson_with_options(path, options)
            Some(columns) => @io.read_ndjson_projected(path, options, columns)
          },
        )
      Select(_, exprs) => values.push(pop_top(values).select(exprs))
      WithColumns(_, exprs) => values.push(pop_top(values).with_columns(exprs))
      Filter(_, predicate) => values.push(pop_top(values).filter(predicate))
      Sort(_, by) => values.push(pop_top(values).sort(by))
      Head(_, n) => values.push(pop_top(values).head(n))
      Tail(_, n) => values.push(pop_top(values).tail(n))
      Slice(_, start, end) => values.push(pop_top(values).slice(start, end))
      Join(_, _, options) => {
        // Right is on top (pushed last in post-order), left just below.
        let right = pop_top(values)
        let left = pop_top(values)
        values.push(left.join(right, options))
      }
      Aggregate(_, keys, exprs) =>
        values.push(pop_top(values).group_by(keys).agg(exprs))
      Drop(_, exprs) => values.push(pop_top(values).drop(exprs))
      Rename(_, pairs) => values.push(pop_top(values).rename(pairs))
      Unique(_) => values.push(pop_top(values).unique())
      DropNulls(_, subset) => values.push(pop_top(values).drop_nulls(subset?))
      FillNull(_, value) => values.push(pop_top(values).fill_null(value))
    }
  }
  pop_top(values)
}

///|
/// Tree printer behind `LazyFrame::explain`: the plan root on the first
/// line, every input indented two further spaces, and a `Join`'s two
/// inputs stacked left-then-right at the same depth. Expressions render
/// through `@expr.Expr`'s `Show` (the documented operator form), and
/// `Scan` prints only the captured frame's shape — `SCAN [rows×cols]` —
/// never its data. A file source (`ScanCsv` / `ScanNdjson`) prints its label
/// and path (quoted and escaped like a string literal) and, once the
/// optimizer has filled it, the projected column list — `SCAN_CSV
/// "sales.csv" [region, revenue]` — but never reads the file. Total:
/// rendering walks plain data, including plans that would fail to `collect`.
fn render(plan : LogicalPlan, buf : StringBuilder, depth : Int) -> Unit {
  // Explicit-stack pre-order walk (not the call stack), so a deeply nested plan
  // renders without overflowing and aborting — `explain` is documented total at
  // any depth. Each node writes its own label; `render_input`'s old job (a fresh
  // line before every input) becomes "a newline before every node but the
  // first", preserving `explain`'s no-leading / no-trailing-newline contract.
  let stack : Array[(LogicalPlan, Int)] = [(plan, depth)]
  let mut first = true
  while stack.length() > 0 {
    let (node, d) = pop_top(stack)
    if first {
      first = false
    } else {
      buf.write_char('\n')
    }
    for _ in 0..<d {
      buf.write_string("  ")
    }
    write_plan_label(node, buf)
    // Push children deepest-last so the leftmost child is visited next and a
    // `Join`'s left subtree fully precedes its right (the old left-then-right
    // `render_input` order).
    let kids = plan_children(node)
    for i in 0..<kids.length() {
      stack.push((kids[kids.length() - 1 - i], d + 1))
    }
  }
}

///|
/// Write a single plan node's own label (its inputs excluded) into `buf` — the
/// per-node half of `render`, split out so the iterative walk emits each label
/// and schedules its children separately. Expressions render through
/// `@expr.Expr`'s `Show`; `Scan` prints only its frame's shape and a file source
/// its label, path, and (once the optimizer fills it) projection — never data.
fn write_plan_label(plan : LogicalPlan, buf : StringBuilder) -> Unit {
  match plan {
    Scan(df) => {
      buf.write_string("SCAN [")
      buf.write_string(df.nrows().to_string())
      buf.write_string("×")
      buf.write_string(df.ncols().to_string())
      buf.write_string("]")
    }
    ScanCsv(path, _, projection) =>
      render_scan_source(buf, "SCAN_CSV", path, projection)
    ScanNdjson(path, _, projection) =>
      render_scan_source(buf, "SCAN_NDJSON", path, projection)
    Select(_, exprs) => {
      buf.write_string("SELECT ")
      buf.write_string(exprs_label(exprs))
    }
    WithColumns(_, exprs) => {
      buf.write_string("WITH_COLUMNS ")
      buf.write_string(exprs_label(exprs))
    }
    Filter(_, predicate) => {
      buf.write_string("FILTER ")
      buf.write_string(predicate.explain())
    }
    Sort(_, by) => {
      buf.write_string("SORT ")
      buf.write_string(sort_label(by))
    }
    Head(_, n) => {
      buf.write_string("HEAD ")
      buf.write_string(n.to_string())
    }
    Tail(_, n) => {
      buf.write_string("TAIL ")
      buf.write_string(n.to_string())
    }
    Slice(_, start, end) => {
      buf.write_string("SLICE [")
      buf.write_string(start.to_string())
      buf.write_string(", ")
      buf.write_string(end.to_string())
      buf.write_string(")")
    }
    Join(_, _, options) => buf.write_string(join_label(options))
    Aggregate(_, keys, exprs) => {
      buf.write_string("AGGREGATE ")
      buf.write_string(exprs_label(exprs))
      buf.write_string(" BY ")
      buf.write_string(exprs_label(keys))
    }
    Drop(_, exprs) => {
      buf.write_string("DROP ")
      buf.write_string(exprs_label(exprs))
    }
    Rename(_, pairs) => {
      buf.write_string("RENAME ")
      buf.write_string(rename_label(pairs))
    }
    Unique(_) => buf.write_string("UNIQUE")
    DropNulls(_, subset) => {
      buf.write_string("DROP_NULLS")
      match subset {
        Some(exprs) => {
          buf.write_string(" ")
          buf.write_string(exprs_label(exprs))
        }
        None => ()
      }
    }
    FillNull(_, value) => {
      buf.write_string("FILL_NULL ")
      buf.write_string(scalar_label(value))
    }
  }
}

///|
/// `RENAME` pair list, e.g. `[old -> new, a -> b]` — one `from -> to` per
/// rename, reusing the bracketed-list shape of the other plan labels.
fn rename_label(pairs : Array[(String, String)]) -> String {
  list_label(
    pairs.map(p => {
      let (from, to) = p
      "\{from} -> \{to}"
    }),
  )
}

///|
/// A scalar fill value in `FILL_NULL` display syntax: numbers / booleans bare,
/// a string quoted and escaped (so it stays distinguishable and on one line),
/// the null literal as `null` — mirroring how `@expr` renders a literal in a
/// plan line. A whole-valued `Float` keeps a `.0` suffix (`1.0`, not `1`) so it
/// stays distinct from an `Int` literal, exactly as `@expr`'s `write_scalar`.
fn scalar_label(value : @types.Scalar) -> String {
  match value {
    @types.Scalar::Int(v) => v.to_string()
    // `Double::to_string` drops the point of a finite whole value (`1.0` ->
    // `"1"`), which would read as an `Int`; re-add `.0` so the `Float` stays
    // distinct. Non-finite (`NaN` / `Infinity`) keeps its own spelling. Mirrors
    // `@expr.write_scalar`, kept in sync by hand (the two packages can't share
    // a private helper).
    @types.Scalar::Float(v) => {
      let s = v.to_string()
      let finite = v - v == 0.0
      let has_point = s.iter().any(c => c == '.' || c == 'e' || c == 'E')
      if finite && !has_point {
        s + ".0"
      } else {
        s
      }
    }
    @types.Scalar::Bool(v) => v.to_string()
    @types.Scalar::String(s) => "\"\{@types.escape_debug(s)}\""
    @types.Scalar::Null => "null"
  }
}

///|
/// Bracketed, comma-separated display list — the shared shape of the
/// `SELECT` / `WITH_COLUMNS` expression lists, the `SORT` key list, and
/// the join key list. Items arrive pre-rendered: explain output is
/// display syntax, so nothing here is debug-quoted.
fn list_label(items : Array[String]) -> String {
  "[\{items.join(", ")}]"
}

///|
/// Expression list in the documented `Show` form, e.g.
/// `[col(region), (col(revenue) * 1.1) as adj]`.
fn exprs_label(exprs : Array[@expr.Expr]) -> String {
  list_label(exprs.map(e => e.explain()))
}

///|
/// `SORT` key list, e.g. `[col(qty) Asc NullsFirst, col(region) Desc NullsLast]`
/// — one `key order nulls` triple per key, in sort precedence order, the
/// key rendered through `@expr.Expr`'s `Show` (the documented operator
/// form, like the `SELECT` / `WITH_COLUMNS` expression lists).
fn sort_label(
  by : Array[(@expr.Expr, @frame.SortOrder, @frame.NullOrder)],
) -> String {
  list_label(
    by.map(key => {
      let (expr, order, nulls) = key
      "\{expr.explain()} \{order_label(order)} \{nulls_label(nulls)}"
    }),
  )
}

///|
/// `JOIN` line: the join type plus the key list when there is one —
/// `JOIN Left on [col(id)]`, or `JOIN Inner left_on [col(a)] right_on
/// [col(b)]` for paired keys — and just `JOIN Cross` for the keyless
/// Cartesian product. Keys render through `@expr.Expr`'s `Show` (the
/// documented operator form, like the `SELECT` / `SORT` lists). Faithful to
/// the stored `JoinOptions`: a malformed combination (say, keys with
/// `Cross`) renders as stored and only fails at collect, exactly like the
/// eager `join` it defers.
fn join_label(options : @frame.JoinOptions) -> String {
  let how = match options.how {
    @frame.JoinType::Inner => "Inner"
    @frame.JoinType::Left => "Left"
    @frame.JoinType::Right => "Right"
    @frame.JoinType::Outer => "Outer"
    @frame.JoinType::Cross => "Cross"
  }
  if !options.on.is_empty() {
    "JOIN \{how} on \{exprs_label(options.on)}"
  } else if !options.left_on.is_empty() || !options.right_on.is_empty() {
    "JOIN \{how} left_on \{exprs_label(options.left_on)} right_on \{exprs_label(options.right_on)}"
  } else {
    "JOIN \{how}"
  }
}

///|
/// Display name of a sort direction.
fn order_label(order : @frame.SortOrder) -> String {
  match order {
    @frame.SortOrder::Asc => "Asc"
    @frame.SortOrder::Desc => "Desc"
  }
}

///|
/// Display name of a null placement.
fn nulls_label(nulls : @frame.NullOrder) -> String {
  match nulls {
    @frame.NullOrder::NullsFirst => "NullsFirst"
    @frame.NullOrder::NullsLast => "NullsLast"
  }
}

///|
/// Render a file-source leaf — `LABEL "path"` plus, once the optimizer has
/// filled it, the projected column list (`LABEL "path" [a, b]`). Shared by
/// `ScanCsv` and `ScanNdjson`, which differ only in the label: the path is
/// quoted and escaped like a string literal, and the projection (when present)
/// reuses the `SELECT` / `SORT` bracketed-list shape. Total — never reads the
/// file.
fn render_scan_source(
  buf : StringBuilder,
  label : String,
  path : String,
  projection : Array[String]?,
) -> Unit {
  buf.write_string(label)
  buf.write_string(" \"")
  buf.write_string(@types.escape_debug(path))
  buf.write_string("\"")
  match projection {
    None => ()
    Some(columns) => {
      buf.write_string(" ")
      buf.write_string(list_label(columns))
    }
  }
}
