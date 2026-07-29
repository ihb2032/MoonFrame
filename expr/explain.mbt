///|
/// Introspection over the expression tree: a handwritten `Show` rendering
/// the documented operator form, its `to_string` exposing that rendering as a
/// `String` (shared later by `LazyFrame::explain`'s plan printer), and the thin
/// handle-level accessors (`children` / `referenced_columns` / `output_name`)
/// that delegate to the AST analysis living beside the tree in `internal/ir`.
/// All are total — they walk shape, nothing can fail.

///|
/// Render the documented operator form, e.g.
/// `(col(revenue) - col(cost)) as profit`: columns as `col(name)`, bare
/// literals (strings quoted, the null literal as `null`), binary nodes
/// parenthesised infix, prefix `(-e)` / `(not e)`, the remaining unary
/// probes and `Agg` / `Cast` as postfix method calls, `Alias` as
/// `expr as name`, `Ternary` mirroring its `when(c).then(a).otherwise(b)`
/// construction route, a `Map` as `map("label", [inputs])`, and a
/// `LitSeries` as `lit_series("name", len)`. Handwritten because
/// `derive(Show)` is deprecated — and the derived variant form would leak
/// construction-route noise into `explain` output anyway.
pub impl Show for Expr with fn output(self, logger) {
  write_expr(logger, self)
}

///|
pub extend Expr with Show::{to_string, output}

///|
/// Handwritten `@debug.Debug`: the `@ir.ExprNode` `Map` / `MapBatches` closures
/// have no `Debug`, so neither the AST node nor the `Expr` wrapping it can
/// `derive` one. The debug form delegates to
/// the `Show` rendering (`to_string`), which already presents every variant —
/// `Map` by its `(label, inputs)`, the closure opaque — in the documented
/// operator form. Debug output surfaces in `debug_inspect` and in the failure
/// message of any assertion over something that embeds an expression — the
/// handle itself has no equality to fail. `Repr` has no public constructor, so
/// delegating to an existing `Debug` (here `String`'s) is the one way to
/// build one.
pub impl @debug.Debug for Expr with fn to_repr(self) {
  @debug.Debug::to_repr(self.to_string())
}

///|
pub extend Expr with Debug::{to_repr}

///|
/// The immediate sub-expressions of a node, left to right, as opaque `Expr`
/// handles — the wrapper-level face of `@ir.ExprNode::children`, which is the
/// single place that encodes the tree's recursive shape. A new variant declares
/// its child structure once, in `ExprNode`, and every walk over it follows: this
/// handle-level face, the `internal/ir` analyses behind `referenced_columns` /
/// `output_name`, and the lazy optimizer's `row_stable` / `group_cell_stable`
/// (which walk the raw `@ir.ExprNode` children directly). Total — it only
/// inspects shape.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::children(self : Expr) -> Array[Expr] {
  // The AST's shape lives on `@ir.ExprNode::children`; wrap each raw child back
  // into the opaque `Expr` this returns, so a caller walks the handle.
  self.node.children().map(Expr::of)
}

///|
/// Every column name the tree references, as a set — the handle-level face of
/// `@ir.ExprNode::referenced_columns` (the analysis itself lives in
/// `internal/ir`, beside the AST). A `Ternary`'s condition counts. Total.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::referenced_columns(self : Expr) -> @set.Set[String] {
  self.node.referenced_columns()
}

///|
/// The output-column name this expression produces (Polars' naming rule: an
/// alias wins, else the leftmost column reference, else `"literal"`) — the
/// handle-level face of `@ir.ExprNode::output_name`. Total.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::output_name(self : Expr) -> String {
  self.node.output_name()
}

///|
/// A pending step for the iterative `write_expr`: either a literal string
/// fragment to emit, a sub-expression still to expand, or one of the three leaf
/// writers that take more than a plain string (`@literal.format_scalar`
/// for a `Lit`, a `Cast` target, a `Str` suffix).
priv enum WriteTask {
  Frag(String)
  Node(Expr)
  ScalarLit(@types.Scalar)
  CastTarget(@types.DataType)
  StrSuffix(@ir.StrOp)
}

///|
/// Renderer behind `Show`, driven by an explicit heap stack instead of the call
/// stack so a deeply nested tree can't overflow and abort (the same discipline
/// as `@ir.ExprNode::referenced_columns`). Every composite form is
/// self-delimiting (parentheses or
/// a closing `)` of a method call), so a node expands into a fixed sequence of
/// fragments and child placeholders; the emitted text is byte-for-byte the
/// recursive form's.
fn write_expr(logger : &Logger, expr : Expr) -> Unit {
  let stack : Array[WriteTask] = [Node(expr)]
  for ;; {
    match stack.pop() {
      None => break
      Some(task) =>
        match task {
          Frag(s) => logger.write_string(s)
          ScalarLit(v) => logger.write_string(@literal.format_scalar(v))
          CastTarget(t) => t.output(logger)
          StrSuffix(op) => write_str_suffix(logger, op)
          Node(e) => push_write_tasks(stack, e)
        }
    }
  }
}

///|
/// Expand one node into its fragment / child sequence, pushed so the parts emit
/// left to right (built forward, then pushed in reverse so the first pops
/// first). The per-variant shapes mirror the recursive renderer exactly.
fn push_write_tasks(stack : Array[WriteTask], expr : Expr) -> Unit {
  let tasks : Array[WriteTask] = match expr.node {
    // `col(name)` and `Alias`'s ` as name` render the name UNQUOTED, unlike a
    // string literal (`@literal.format_scalar` quotes those), so
    // `col("x")` stays distinct
    // from `lit_str("x")` in a plan line. A name containing literal parens can
    // therefore read paren-ambiguously (`col(a)b)`); that is display-only and
    // accepted — `explain` output is diagnostic, not re-parsed.
    Col(name) => [Frag("col(\{@text.escape_debug(name)})")]
    Lit(value) => [ScalarLit(value)]
    // The embedded data is opaque to the rendering, so a `LitSeries` shows its
    // name (quoted / escaped like a string literal) and length —
    // `lit_series("flag", 4)` — enough to read a plan line without dumping
    // every cell.
    LitSeries(s) =>
      [Frag("lit_series(\"\{@text.escape_debug(s.name())}\", \{s.len()})")]
    // A `Node` holds the opaque `Expr`, so every AST child is wrapped with
    // `Expr::of` before it is pushed for expansion.
    Binary(op, l, r) =>
      [
        Frag("("),
        Node(Expr::of(l)),
        Frag(" \{binop_symbol(op)} "),
        Node(Expr::of(r)),
        Frag(")"),
      ]
    Unary(op, e) =>
      match op {
        Neg => [Frag("(-"), Node(Expr::of(e)), Frag(")")]
        Not => [Frag("(not "), Node(Expr::of(e)), Frag(")")]
        IsNull => [Node(Expr::of(e)), Frag(".is_null()")]
        IsNotNull => [Node(Expr::of(e)), Frag(".is_not_null()")]
        IsNan => [Node(Expr::of(e)), Frag(".is_nan()")]
        IsNotNan => [Node(Expr::of(e)), Frag(".is_not_nan()")]
        Abs => [Node(Expr::of(e)), Frag(".abs()")]
        Floor => [Node(Expr::of(e)), Frag(".floor()")]
        Ceil => [Node(Expr::of(e)), Frag(".ceil()")]
        Sign => [Node(Expr::of(e)), Frag(".sign()")]
        Round(0) => [Node(Expr::of(e)), Frag(".round()")]
        Round(d) => [Node(Expr::of(e)), Frag(".round(decimals=\{d})")]
      }
    Agg(op, e) => [Node(Expr::of(e)), Frag(agg_suffix(op))]
    Str(op, e) => [Node(Expr::of(e)), StrSuffix(op)]
    Cast(e, target) =>
      [Node(Expr::of(e)), Frag(".cast("), CastTarget(target), Frag(")")]
    Alias(e, name) =>
      [Node(Expr::of(e)), Frag(" as \{@text.escape_debug(name)}")]
    Ternary(c, t, f) =>
      [
        Frag("when("),
        Node(Expr::of(c)),
        Frag(").then("),
        Node(Expr::of(t)),
        Frag(").otherwise("),
        Node(Expr::of(f)),
        Frag(")"),
      ]
    // Postfix method-call form, mirroring the construction route — the
    // operand appears once, so a chained coalesce renders linearly.
    FillNull(o, v) =>
      [Node(Expr::of(o)), Frag(".fill_null("), Node(Expr::of(v)), Frag(")")]
    FillNan(o, v) =>
      [Node(Expr::of(o)), Frag(".fill_nan("), Node(Expr::of(v)), Frag(")")]
    // `col(a).is_in([1, 2])`: the operand, then each set member rendered as a
    // literal (`format_scalar`, like a `Lit`) inside `[...]`.
    IsIn(operand, members) => {
      let ts : Array[WriteTask] = [Node(Expr::of(operand)), Frag(".is_in([")]
      for i in 0..<members.length() {
        if i > 0 {
          ts.push(Frag(", "))
        }
        ts.push(ScalarLit(members[i]))
      }
      ts.push(Frag("])"))
      ts
    }
    // `col(a).is_between(lo, hi)` — the operand once, then both bounds.
    // A non-default `closed` renders as the named argument that builds it.
    IsBetween(x, lo, hi, closed) => {
      let ts : Array[WriteTask] = [
        Node(Expr::of(x)),
        Frag(".is_between("),
        Node(Expr::of(lo)),
        Frag(", "),
        Node(Expr::of(hi)),
      ]
      match closed {
        @types.ClosedInterval::Both => ()
        @types.ClosedInterval::Left => ts.push(Frag(", closed=Left"))
        @types.ClosedInterval::Right => ts.push(Frag(", closed=Right"))
        @types.ClosedInterval::None => ts.push(Frag(", closed=None"))
      }
      ts.push(Frag(")"))
      ts
    }
    // The closure is opaque, so a `Map` renders by its label and inputs:
    // `map("label", [in1, in2])`. The label is quoted / escaped like a string
    // literal so it stays on one unambiguous line.
    Map(label, inputs, _) => {
      let ts : Array[WriteTask] = [
        Frag("map(\"\{@text.escape_debug(label)}\", ["),
      ]
      for i in 0..<inputs.length() {
        if i > 0 {
          ts.push(Frag(", "))
        }
        ts.push(Node(Expr::of(inputs[i])))
      }
      ts.push(Frag("])"))
      ts
    }
    // Like `Map`, as `map_batches("label", [inputs])`, and — when the node is
    // flagged as a reduction — a trailing `, returns_scalar=true` so the two
    // forms render distinctly.
    MapBatches(label, inputs, returns_scalar, _) => {
      let ts : Array[WriteTask] = [
        Frag("map_batches(\"\{@text.escape_debug(label)}\", ["),
      ]
      for i in 0..<inputs.length() {
        if i > 0 {
          ts.push(Frag(", "))
        }
        ts.push(Node(Expr::of(inputs[i])))
      }
      ts.push(
        Frag(if returns_scalar { "], returns_scalar=true)" } else { "])" }),
      )
      ts
    }
  }
  for i = tasks.length() - 1; i >= 0; i = i - 1 {
    stack.push(tasks[i])
  }
}

///|
/// Infix symbol for a binary tag — the call-site spelling (`&` / `|` for
/// the Kleene connectives, comparison glyphs for the method family).
fn binop_symbol(op : @ir.BinOp) -> String {
  match op {
    Add => "+"
    Sub => "-"
    Mul => "*"
    Div => "/"
    FloorDiv => "//"
    Mod => "%"
    Pow => "**"
    Eq => "=="
    Ne => "!="
    Lt => "<"
    Le => "<="
    Gt => ">"
    Ge => ">="
    And => "&"
    Or => "|"
  }
}

///|
/// Postfix method spelling for an aggregation tag.
fn agg_suffix(op : @ir.AggOp) -> String {
  match op {
    Sum => ".sum()"
    Mean => ".mean()"
    Min => ".min()"
    Max => ".max()"
    Count => ".count()"
    Std => ".std()"
    Var => ".variance()"
    Median => ".median()"
    NUnique => ".n_unique()"
    First => ".first()"
    Last => ".last()"
  }
}

///|
/// Postfix method rendering for a string-namespace tag, written straight to
/// `logger` (unlike `agg_suffix`'s fixed string) because the parameterised
/// operations carry literal arguments that are quoted and escaped like a
/// `lit_str` — `.str_contains("foo")`, `.str_replace("a", "b")` — so a plan
/// line stays unambiguous and on one line.
fn write_str_suffix(logger : &Logger, op : @ir.StrOp) -> Unit {
  match op {
    ToUppercase => logger.write_string(".str_to_uppercase()")
    ToLowercase => logger.write_string(".str_to_lowercase()")
    StripChars => logger.write_string(".str_strip_chars()")
    LenChars => logger.write_string(".str_len_chars()")
    Contains(p) => write_str_call(logger, "str_contains", [p])
    StartsWith(p) => write_str_call(logger, "str_starts_with", [p])
    EndsWith(p) => write_str_call(logger, "str_ends_with", [p])
    Replace(a, b) => write_str_call(logger, "str_replace", [a, b])
    ReplaceAll(a, b) => write_str_call(logger, "str_replace_all", [a, b])
    Reverse => logger.write_string(".str_reverse()")
    // The width renders bare, the fill as a `'x'` char literal (escaped like a
    // string so a control or quote character stays on one line).
    PadStart(width, fill) =>
      logger.write_string(
        ".str_pad_start(\{width}, '\{@text.escape_debug(fill.to_string())}')",
      )
    PadEnd(width, fill) =>
      logger.write_string(
        ".str_pad_end(\{width}, '\{@text.escape_debug(fill.to_string())}')",
      )
    // The regex forms render as the spelling that builds them: the same
    // method with `literal=false`.
    ContainsRegex(p) =>
      logger.write_string(
        ".str_contains(\"\{@text.escape_debug(p)}\", literal=false)",
      )
    ReplaceRegex(a, b) =>
      logger.write_string(
        ".str_replace(\"\{@text.escape_debug(a)}\", \"\{@text.escape_debug(b)}\", literal=false)",
      )
    ReplaceAllRegex(a, b) =>
      logger.write_string(
        ".str_replace_all(\"\{@text.escape_debug(a)}\", \"\{@text.escape_debug(b)}\", literal=false)",
      )
    // The pattern renders quoted, the group index bare.
    Extract(pattern, group) =>
      logger.write_string(
        ".str_extract(\"\{@text.escape_debug(pattern)}\", \{group})",
      )
    CountMatches(p) => write_str_call(logger, "str_count_matches", [p])
    // The offset renders bare; the length only when present.
    Slice(offset, length) =>
      match length {
        None => logger.write_string(".str_slice(\{offset})")
        Some(n) => logger.write_string(".str_slice(\{offset}, \{n})")
      }
    LenBytes => logger.write_string(".str_len_bytes()")
    // The custom strip renders its charset as a quoted argument, so it stays
    // distinct from the default `.str_strip_chars()`.
    StripCharsCustom(chars) =>
      write_str_call(logger, "str_strip_chars", [chars])
    // The separator renders quoted, the index bare.
    SplitGet(sep, index) =>
      logger.write_string(
        ".str_split_get(\"\{@text.escape_debug(sep)}\", \{index})",
      )
    ZFill(width) => logger.write_string(".str_zfill(\{width})")
  }
}

///|
/// Render one parameterised string-op call `.name("arg", …)`, each argument
/// quoted and `escape_debug`-escaped exactly like a rendered `lit_str`
/// (`@literal.format_scalar`), so a pattern containing a `"` or a
/// control character stays on one unambiguous line.
fn write_str_call(
  logger : &Logger,
  name : String,
  args : Array[String],
) -> Unit {
  logger.write_string(".")
  logger.write_string(name)
  logger.write_string("(")
  logger.write_string(args.map(a => "\"\{@text.escape_debug(a)}\"").join(", "))
  logger.write_string(")")
}
