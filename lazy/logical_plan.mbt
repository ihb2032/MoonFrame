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
  match plan {
    Scan(df) => df
    ScanCsv(path, options, projection) =>
      match projection {
        None => @io.read_csv_with_options(path, options)
        Some(columns) => @io.read_csv_projected(path, options, columns)
      }
    ScanNdjson(path, options, projection) =>
      match projection {
        None => @io.read_ndjson_with_options(path, options)
        Some(columns) => @io.read_ndjson_projected(path, options, columns)
      }
    Select(input, exprs) => execute(input).select(exprs)
    WithColumns(input, exprs) => execute(input).with_columns(exprs)
    Filter(input, predicate) => execute(input).filter(predicate)
    Sort(input, by) => execute(input).sort(by)
    Head(input, n) => execute(input).head(n)
    Tail(input, n) => execute(input).tail(n)
    Slice(input, start, end) => execute(input).slice(start, end)
    Join(left, right, options) => execute(left).join(execute(right), options)
    Aggregate(input, keys, exprs) => execute(input).group_by(keys).agg(exprs)
    Drop(input, exprs) => execute(input).drop(exprs)
    Rename(input, pairs) => execute(input).rename(pairs)
    Unique(input) => execute(input).unique()
    DropNulls(input, subset) => execute(input).drop_nulls(subset?)
    FillNull(input, value) => execute(input).fill_null(value)
  }
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
    ScanCsv(path, _, projection) =>
      render_scan_source(buf, "SCAN_CSV", path, projection)
    ScanNdjson(path, _, projection) =>
      render_scan_source(buf, "SCAN_NDJSON", path, projection)
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
      buf.write_string(exprs_label(keys))
      render_input(input, buf, depth)
    }
    Drop(input, exprs) => {
      buf.write_string("DROP ")
      buf.write_string(exprs_label(exprs))
      render_input(input, buf, depth)
    }
    Rename(input, pairs) => {
      buf.write_string("RENAME ")
      buf.write_string(rename_label(pairs))
      render_input(input, buf, depth)
    }
    Unique(input) => {
      buf.write_string("UNIQUE")
      render_input(input, buf, depth)
    }
    DropNulls(input, subset) => {
      buf.write_string("DROP_NULLS")
      match subset {
        Some(exprs) => {
          buf.write_string(" ")
          buf.write_string(exprs_label(exprs))
        }
        None => ()
      }
      render_input(input, buf, depth)
    }
    FillNull(input, value) => {
      buf.write_string("FILL_NULL ")
      buf.write_string(scalar_label(value))
      render_input(input, buf, depth)
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
/// plan line.
fn scalar_label(value : @types.Scalar) -> String {
  match value {
    @types.Scalar::Int(v) => v.to_string()
    @types.Scalar::Float(v) => v.to_string()
    @types.Scalar::Bool(v) => v.to_string()
    @types.Scalar::String(s) => "\"\{escape_debug(s)}\""
    @types.Scalar::Null => "null"
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
  buf.write_string(escape_debug(path))
  buf.write_string("\"")
  match projection {
    None => ()
    Some(columns) => {
      buf.write_string(" ")
      buf.write_string(list_label(columns))
    }
  }
}

///|
/// Escape a file-source path for the quoted form `render` emits
/// (`"a\"b"`), so a path containing a `"`, `\`, or a control character stays
/// unambiguous and on one line in `explain` output. A single forward pass:
/// `\` → `\\`, `"` → `\"`, newline / carriage-return / tab → `\n` / `\r` /
/// `\t`, and every other control character (the rest of C0, `DEL`, and the
/// Unicode line/paragraph separators) → a `\uXXXX` escape, so a hostile path
/// cannot inject a terminal control sequence or an extra line into a plan.
/// Mirrors the identically-named helpers behind `@expr`'s and `@types`' `Show`
/// impls — kept a private duplicate here rather than a shared public symbol so
/// no package's interface grows for a presentation-only concern. Total.
fn escape_debug(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s.iter() {
    match ch {
      '\\' => {
        buf.write_char('\\')
        buf.write_char('\\')
      }
      '"' => {
        buf.write_char('\\')
        buf.write_char('"')
      }
      '\n' => {
        buf.write_char('\\')
        buf.write_char('n')
      }
      '\r' => {
        buf.write_char('\\')
        buf.write_char('r')
      }
      '\t' => {
        buf.write_char('\\')
        buf.write_char('t')
      }
      c if is_control_char(c) => write_unicode_escape(buf, c)
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// Whether `ch` is a control character that must be `\uXXXX`-escaped (the C0
/// range, `DEL`, and the Unicode line/paragraph separators); `\n` / `\r` /
/// `\t` are handled by their own short escapes before this is consulted.
fn is_control_char(ch : Char) -> Bool {
  let cp = ch.to_int()
  cp < 0x20 || cp == 0x7f || cp == 0x85 || cp == 0x2028 || cp == 0x2029
}

///|
/// Append the `\uXXXX` (four lowercase hex digits) escape of `ch` to `buf`;
/// every escaped code point is below `U+10000`, so four digits suffice.
fn write_unicode_escape(buf : StringBuilder, ch : Char) -> Unit {
  let digits = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let cp = ch.to_int()
  buf.write_char('\\')
  buf.write_char('u')
  buf.write_char(digits[(cp >> 12) & 0xF])
  buf.write_char(digits[(cp >> 8) & 0xF])
  buf.write_char(digits[(cp >> 4) & 0xF])
  buf.write_char(digits[cp & 0xF])
}
