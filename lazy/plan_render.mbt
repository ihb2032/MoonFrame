// Rendering behind `LazyFrame::explain`: the tree printer (`render` /
// `write_plan_label`) and its per-shape label helpers, kept apart from the
// IR definition and the executor so each reads alone. Everything here is
// total: rendering walks plain data, including
// plans that would fail to `collect`.

///|
/// Tree printer behind `LazyFrame::explain`: the plan root on the first
/// line, every input indented two further spaces, and a `Join`'s two
/// inputs stacked left-then-right at the same depth. Expressions render
/// through `@expr.Expr`'s `Show` (the documented operator form), and
/// `Scan` prints only the captured frame's shape — `SCAN [rows×cols]` —
/// never its data. A file source (a `Csv` / `Ndjson` scan) prints its label
/// and path (quoted and escaped like a string literal) and, once the
/// optimizer has filled them, the projected column list and any absorbed
/// predicate — `SCAN_CSV "sales.csv" [region, revenue] WHERE (col(qty) > 50)`
/// — but never reads the file. Total:
/// rendering walks plain data, including plans that would fail to `collect`.
fn LogicalPlan::render(
  self : LogicalPlan,
  buf : StringBuilder,
  depth : Int,
) -> Unit {
  // Explicit-stack pre-order walk (not the call stack), so a deeply nested plan
  // renders without overflowing and aborting — `explain` is documented total at
  // any depth. Each node writes its own label; `render_input`'s old job (a fresh
  // line before every input) becomes "a newline before every node but the
  // first", preserving `explain`'s no-leading / no-trailing-newline contract.
  // Sharing can enter a plan only through a `Join`, so a join-free plan is a
  // linear chain with no node reachable twice: the identity `seen` scan the
  // DAG-shaped half needs is pure overhead on it (the same `contains_join`
  // fast path `has_shared_subplan` / `post_order_unique` take), and the walk
  // below skips the scan outright instead of paying it per node.
  let dedup = self.contains_join()
  let stack : Array[(LogicalPlan, Int)] = [(self, depth)]
  let seen : Array[LogicalPlan] = []
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
    node.write_plan_label(buf)
    // A node object reaching the printer twice (a DAG-shaped plan: nested
    // self-joins share subplans by reference) prints its label plus a
    // marker instead of re-expanding — re-expansion is 2^depth lines, which
    // would break `explain`'s total-at-any-depth promise by exhausting
    // memory. Tree plans never repeat a node, so their output is unchanged.
    if dedup {
      if seen_plan(seen, node) {
        buf.write_string(" (shared, rendered above)")
        continue
      }
      seen.push(node)
    }
    // Push children deepest-last so the leftmost child is visited next and a
    // `Join`'s left subtree fully precedes its right (the old left-then-right
    // `render_input` order).
    let kids = node.plan_children()
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
/// its label, path, and (once the optimizer fills them) projection and absorbed
/// predicate — never data.
fn LogicalPlan::write_plan_label(
  self : LogicalPlan,
  buf : StringBuilder,
) -> Unit {
  match self {
    Scan(source) => source.write_scan_label(buf)
    Unary(_, op) => op.write_frame_op_label(buf)
    Join(_, _, options) => buf <+ "\{join_label(options)}"
    Aggregate(_, keys, exprs) =>
      buf <+ "AGGREGATE \{exprs_label(exprs)} BY \{exprs_label(keys)}"
  }
}

///|
/// The one-line label for a `ScanSource` — the `Scan` leaf's half of
/// `write_plan_label`, so a new scannable format adds its render here alone. The
/// strings are unchanged from the former per-variant arms.
fn ScanSource::write_scan_label(self : ScanSource, buf : StringBuilder) -> Unit {
  match self {
    InMemory(df) => buf <+ "SCAN [\{df.nrows()}×\{df.ncols()}]"
    File(fs) =>
      render_scan_source(
        buf,
        "SCAN_\{fs.driver.label()}",
        fs.projection,
        fs.predicate,
      )
  }
}

///|
/// The one-line label for a unary `FrameOp` — the `Unary` node's half of
/// `write_plan_label`, so a new unary verb adds its render here alone. The
/// strings are unchanged from the former per-variant arms.
fn FrameOp::write_frame_op_label(self : FrameOp, buf : StringBuilder) -> Unit {
  match self {
    Select(exprs) => buf <+ "SELECT \{exprs_label(exprs)}"
    WithColumns(exprs) => buf <+ "WITH_COLUMNS \{exprs_label(exprs)}"
    Filter(predicate) => buf <+ "FILTER \{predicate.to_string()}"
    Sort(by) => {
      // One `key order nulls` triple per key, in sort precedence order,
      // the key rendered through `@expr.Expr`'s `Show` (the documented
      // operator form, like the `SELECT` / `WITH_COLUMNS` lists). The
      // direction / null-placement spellings are the ones the enums used
      // to carry, so an `explain` snapshot written before them reads the
      // same after.
      let keys = list_label(
        by.map(key => {
          let (expr, descending, nulls_last) = key
          let order = if descending { "Desc" } else { "Asc" }
          let nulls = if nulls_last { "NullsLast" } else { "NullsFirst" }
          "\{expr.to_string()} \{order} \{nulls}"
        }),
      )
      buf <+ "SORT \{keys}"
    }
    Head(n) => buf <+ "HEAD \{n}"
    Tail(n) => buf <+ "TAIL \{n}"
    Slice(offset, length) =>
      buf <+
        "SLICE [\{offset}: \{match length { Some(l) => "\{l}"; None => "" }}]"
    Drop(exprs) => buf <+ "DROP \{exprs_label(exprs)}"
    Rename(pairs) => {
      // One `from -> to` per rename, reusing the bracketed-list shape of
      // the other plan labels.
      let items = list_label(
        pairs.map(p => {
          let (from, to) = p
          "\{from} -> \{to}"
        }),
      )
      buf <+ "RENAME \{items}"
    }
    RenameWith(_) => buf <+ "RENAME_WITH"
    // The keep strategy shows only when it is not the default, so the
    // common plan line stays `UNIQUE`.
    Unique(keep, subset) => {
      buf <+ "UNIQUE"
      if subset is Some(keys) {
        buf <+ " ON "
        buf.write_string(exprs_label(keys))
      }
      match keep {
        @frame.KeepStrategy::First => ()
        @frame.KeepStrategy::Last => buf <+ " keep=Last"
        @frame.KeepStrategy::None => buf <+ " keep=None"
      }
    }
    Reverse => buf <+ "REVERSE"
    WithRowIndex(name, offset) => {
      buf <+ "WITH_ROW_INDEX \"\{@text.escape_debug(name)}\""
      if offset != 0 {
        buf <+ " offset=\{offset}"
      }
    }
    DropNulls(subset) => {
      buf <+ "DROP_NULLS"
      match subset {
        Some(exprs) => buf <+ " \{exprs_label(exprs)}"
        None => ()
      }
    }
    FillNull(value) => buf <+ "FILL_NULL \{@expr.format_scalar(value)}"
    Reduce(op) =>
      match op {
        Sum => buf <+ "SUM"
        Mean => buf <+ "MEAN"
        Min => buf <+ "MIN"
        Max => buf <+ "MAX"
        Count => buf <+ "COUNT"
        NullCount => buf <+ "NULL_COUNT"
      }
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
  list_label(exprs.map(e => e.to_string()))
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
  let on = options.on_keys()
  let left_on = options.left_keys()
  let right_on = options.right_keys()
  if !on.is_empty() {
    "JOIN \{how} on \{exprs_label(on)}"
  } else if !left_on.is_empty() || !right_on.is_empty() {
    "JOIN \{how} left_on \{exprs_label(left_on)} right_on \{exprs_label(right_on)}"
  } else {
    "JOIN \{how}"
  }
}

///|
/// Render a file-source leaf — `SCAN_<format> "path"` plus, once the
/// optimizer has filled them, the projected column list and the absorbed
/// predicate (`SCAN_CSV "path" [a, b] WHERE (...)`). Shared by every file
/// driver, which differ only in the label head their driver supplies (the
/// path is quoted and escaped there, like a string literal); the projection
/// (when present) reuses the `SELECT` / `SORT` bracketed-list shape, and an
/// absorbed predicate prints after it, so the leaf reads "which columns,
/// then which rows". Total — never reads the file.
fn render_scan_source(
  buf : StringBuilder,
  head : String,
  projection : Array[String]?,
  predicate : @expr.Expr?,
) -> Unit {
  buf.write_string(head)
  match projection {
    None => ()
    Some(columns) => buf <+ " \{list_label(columns)}"
  }
  // An absorbed predicate prints after the projection, so the leaf reads
  // "which columns, then which rows".
  match predicate {
    None => ()
    Some(pred) => buf <+ " WHERE \{pred}"
  }
}
