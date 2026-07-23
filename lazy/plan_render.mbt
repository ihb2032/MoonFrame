// Rendering behind `LazyFrame::explain`: the tree printer (`render` /
// `write_plan_label`) and its per-shape label helpers, split from
// `logical_plan.mbt` so plan display and plan traversal / execution read
// apart. Everything here is total: rendering walks plain data, including
// plans that would fail to `collect`.

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
    write_plan_label(node, buf)
    // A node object reaching the printer twice (a DAG-shaped plan: nested
    // self-joins share subplans by reference) prints its label plus a
    // marker instead of re-expanding — re-expansion is 2^depth lines, which
    // would break `explain`'s total-at-any-depth promise by exhausting
    // memory. Tree plans never repeat a node, so their output is unchanged.
    if seen_plan(seen, node) {
      buf.write_string(" (shared, rendered above)")
      continue
    }
    seen.push(node)
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
    Scan(df) => buf <+ "SCAN [\{df.nrows()}×\{df.ncols()}]"
    ScanCsv(path, _, projection, predicate) =>
      render_scan_source(buf, "SCAN_CSV", path, projection, predicate)
    ScanNdjson(path, _, projection, predicate) =>
      render_scan_source(buf, "SCAN_NDJSON", path, projection, predicate)
    Unary(_, op) => write_frame_op_label(op, buf)
    Join(_, _, options) => buf <+ "\{join_label(options)}"
    Aggregate(_, keys, exprs) =>
      buf <+ "AGGREGATE \{exprs_label(exprs)} BY \{exprs_label(keys)}"
  }
}

///|
/// The one-line label for a unary `FrameOp` — the `Unary` node's half of
/// `write_plan_label`, so a new unary verb adds its render here alone. The
/// strings are unchanged from the former per-variant arms.
fn write_frame_op_label(op : FrameOp, buf : StringBuilder) -> Unit {
  match op {
    Select(exprs) => buf <+ "SELECT \{exprs_label(exprs)}"
    WithColumns(exprs) => buf <+ "WITH_COLUMNS \{exprs_label(exprs)}"
    Filter(predicate) => buf <+ "FILTER \{predicate.to_string()}"
    Sort(by) => buf <+ "SORT \{sort_label(by)}"
    Head(n) => buf <+ "HEAD \{n}"
    Tail(n) => buf <+ "TAIL \{n}"
    Slice(start, end) => buf <+ "SLICE [\{start}, \{end})"
    Drop(exprs) => buf <+ "DROP \{exprs_label(exprs)}"
    Rename(pairs) => buf <+ "RENAME \{rename_label(pairs)}"
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
    FillNull(value) => buf <+ "FILL_NULL \{@literal.format_scalar(value)}"
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
/// `SORT` key list, e.g. `[col(qty) Asc NullsFirst, col(region) Desc NullsLast]`
/// — one `key order nulls` triple per key, in sort precedence order, the
/// key rendered through `@expr.Expr`'s `Show` (the documented operator
/// form, like the `SELECT` / `WITH_COLUMNS` expression lists).
fn sort_label(
  by : Array[(@expr.Expr, @types.SortOrder, @types.NullOrder)],
) -> String {
  list_label(
    by.map(key => {
      let (expr, order, nulls) = key
      "\{expr.to_string()} \{order_label(order)} \{nulls_label(nulls)}"
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
fn order_label(order : @types.SortOrder) -> String {
  match order {
    @types.SortOrder::Asc => "Asc"
    @types.SortOrder::Desc => "Desc"
  }
}

///|
/// Display name of a null placement.
fn nulls_label(nulls : @types.NullOrder) -> String {
  match nulls {
    @types.NullOrder::NullsFirst => "NullsFirst"
    @types.NullOrder::NullsLast => "NullsLast"
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
  predicate : @expr.Expr?,
) -> Unit {
  buf <+ "\{label} \"\{@text.escape_debug(path)}\""
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
