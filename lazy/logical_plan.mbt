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
priv enum LogicalPlan {
  Scan(@frame.DataFrame)
  Select(LogicalPlan, Array[@expr.Expr])
  WithColumns(LogicalPlan, Array[@expr.Expr])
  Filter(LogicalPlan, @expr.Expr)
  Sort(LogicalPlan, Array[(String, @frame.SortOrder, @frame.NullOrder)])
  Head(LogicalPlan, Int)
  Tail(LogicalPlan, Int)
  Slice(LogicalPlan, Int, Int)
  Join(LogicalPlan, LogicalPlan, @frame.JoinOptions)
  Aggregate(LogicalPlan, Array[String], Array[@expr.Expr])
}

///|
/// Bottom-up plan interpreter — the whole of `collect`. Each node
/// delegates to the public eager operator it mirrors (`Filter` →
/// `filter_where`, `WithColumns` → `with_columns`, …), so with no
/// optimizer in front the lazy layer is a *faithful deferred executor*:
/// collecting a plan is bitwise-equal to running the same verbs eagerly in
/// the same order. Errors are exactly the eager operators' errors,
/// surfacing here rather than at build time. `Scan` returns the captured
/// frame as-is — frames are immutable, so no defensive copy is needed.
fn execute(plan : LogicalPlan) -> @frame.DataFrame raise @types.DataError {
  match plan {
    Scan(df) => df
    Select(input, exprs) => execute(input).select(exprs)
    WithColumns(input, exprs) => execute(input).with_columns(exprs)
    Filter(input, predicate) => execute(input).filter_where(predicate)
    Sort(input, by) => execute(input).sort_by(by)
    Head(input, n) => execute(input).head(n)
    Tail(input, n) => execute(input).tail(n)
    Slice(input, start, end) => execute(input).slice(start, end)
    Join(left, right, options) => execute(left).join(execute(right), options)
    Aggregate(input, keys, exprs) => execute(input).group_by(keys).agg(exprs)
  }
}

///|
/// Tree printer behind `LazyFrame::explain`: the plan root on the first
/// line, every input indented two further spaces, and a `Join`'s two
/// inputs stacked left-then-right at the same depth. Expressions render
/// through `@expr.Expr`'s `Show` (the documented operator form), and
/// `Scan` prints only the captured frame's shape — `SCAN [rows×cols]` —
/// never its data. Total: rendering walks plain data, including plans
/// that would fail to `collect`.
fn render(plan : LogicalPlan, buf : StringBuilder, depth : Int) -> Unit {
  for _ in 0..<depth {
    buf.write_string("  ")
  }
  match plan {
    Scan(df) => {
      buf.write_string("SCAN [")
      buf.write_string(df.nrows().to_string())
      buf.write_string("×")
      buf.write_string(df.ncols().to_string())
      buf.write_string("]")
    }
    Select(input, exprs) => {
      buf.write_string("SELECT ")
      buf.write_string(exprs_label(exprs))
      render_input(input, buf, depth)
    }
    WithColumns(input, exprs) => {
      buf.write_string("WITH_COLUMNS ")
      buf.write_string(exprs_label(exprs))
      render_input(input, buf, depth)
    }
    Filter(input, predicate) => {
      buf.write_string("FILTER ")
      buf.write_string(predicate.explain())
      render_input(input, buf, depth)
    }
    Sort(input, by) => {
      buf.write_string("SORT ")
      buf.write_string(sort_label(by))
      render_input(input, buf, depth)
    }
    Head(input, n) => {
      buf.write_string("HEAD ")
      buf.write_string(n.to_string())
      render_input(input, buf, depth)
    }
    Tail(input, n) => {
      buf.write_string("TAIL ")
      buf.write_string(n.to_string())
      render_input(input, buf, depth)
    }
    Slice(input, start, end) => {
      buf.write_string("SLICE [")
      buf.write_string(start.to_string())
      buf.write_string(", ")
      buf.write_string(end.to_string())
      buf.write_string(")")
      render_input(input, buf, depth)
    }
    Join(left, right, options) => {
      buf.write_string(join_label(options))
      render_input(left, buf, depth)
      render_input(right, buf, depth)
    }
    Aggregate(input, keys, exprs) => {
      buf.write_string("AGGREGATE ")
      buf.write_string(exprs_label(exprs))
      buf.write_string(" BY ")
      buf.write_string(list_label(keys))
      render_input(input, buf, depth)
    }
  }
}

///|
/// Start an input's subtree on a fresh line, one level deeper. Factored
/// out so `render` lines never end in a dangling newline — `explain`
/// output has no trailing `\n`.
fn render_input(input : LogicalPlan, buf : StringBuilder, depth : Int) -> Unit {
  buf.write_char('\n')
  render(input, buf, depth + 1)
}

///|
/// Bracketed, comma-separated display list — the shared shape of the
/// `SELECT` / `WITH_COLUMNS` expression lists, the `SORT` key list, and
/// the join key list. Items arrive pre-rendered: explain output is
/// display syntax, so nothing here is debug-quoted.
fn list_label(items : Array[String]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("[")
  for i in 0..<items.length() {
    if i > 0 {
      buf.write_string(", ")
    }
    buf.write_string(items[i])
  }
  buf.write_string("]")
  buf.to_string()
}

///|
/// Expression list in the documented `Show` form, e.g.
/// `[col(region), (col(revenue) * 1.1) as adj]`.
fn exprs_label(exprs : Array[@expr.Expr]) -> String {
  list_label(exprs.map(e => e.explain()))
}

///|
/// `SORT` key list, e.g. `[qty Asc NullsFirst, region Desc NullsLast]` —
/// one `name order nulls` triple per key, in sort precedence order.
fn sort_label(
  by : Array[(String, @frame.SortOrder, @frame.NullOrder)],
) -> String {
  list_label(
    by.map(key => {
      let (name, order, nulls) = key
      name + " " + order_label(order) + " " + nulls_label(nulls)
    }),
  )
}

///|
/// `JOIN` line: the join type plus the key list when there is one —
/// `JOIN Left on [id]` — and just `JOIN Cross` for the keyless Cartesian
/// product. Faithful to the stored `JoinOptions`: a malformed combination
/// (say, keys with `Cross`) renders as stored and only fails at collect,
/// exactly like the eager `join` it defers.
fn join_label(options : @frame.JoinOptions) -> String {
  let how = match options.how {
    @frame.JoinType::Inner => "Inner"
    @frame.JoinType::Left => "Left"
    @frame.JoinType::Right => "Right"
    @frame.JoinType::Outer => "Outer"
    @frame.JoinType::Cross => "Cross"
  }
  if options.on.is_empty() {
    "JOIN " + how
  } else {
    "JOIN " + how + " on " + list_label(options.on)
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
