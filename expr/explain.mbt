///|
/// Introspection over the expression tree: a handwritten `Show` rendering
/// the documented operator form, its `to_string` exposing that rendering as a
/// `String` (shared later by `LazyFrame::explain`'s plan printer), and
/// `referenced_columns` collecting every column a tree reads (the input
/// the lazy optimizer's projection / predicate pushdown runs on). All
/// three are total — they walk data, nothing can fail.

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
/// Handwritten `@debug.Debug`: the `Map` variant's closure payload has no
/// `Debug`, so the enum cannot `derive` one. The debug form delegates to
/// the `Show` rendering (`to_string`), which already presents every variant —
/// `Map` by its `(label, inputs)`, the closure opaque — in the documented
/// operator form. Debug output surfaces only in `assert_eq` failure messages
/// and `debug_inspect`; the structural comparison itself rides the
/// handwritten `Eq`. `Repr` has no public constructor, so delegating to an
/// existing `Debug` (here `String`'s) is the one way to build one.
pub impl @debug.Debug for Expr with fn to_repr(self) {
  @debug.Debug::to_repr(self.to_string())
}

///|
pub extend Expr with Debug::{to_repr}

///|
/// The immediate sub-expressions of a node, left to right — the single
/// place that encodes the tree's recursive shape. Every tree walk that
/// recurses uniformly rides this: `referenced_columns` and `output_name`
/// here, and the lazy optimizer's `row_stable` / `group_cell_stable`
/// analyses across the package boundary (hence `pub` — methods live with
/// their type). A new variant declares its child structure once, here,
/// rather than in every walk. A `Ternary` lists all three arms with the
/// condition first; the one walk that must skip the condition — output
/// *naming* — special-cases it rather than reading children. A `Map` lists
/// its input expressions (a fresh copy, so a caller can never alias — and
/// mutate — the node's own `inputs`). Leaves (`Col` / `Lit` / `LitSeries`)
/// have none — a `LitSeries` carries materialised data, not sub-expressions.
/// Total — it only inspects shape.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::children(self : Expr) -> Array[Expr] {
  match self {
    Col(_) | Lit(_) | LitSeries(_) => []
    Binary(_, l, r) => [l, r]
    Unary(_, e) | Agg(_, e) | Str(_, e) | Cast(e, _) | Alias(e, _) => [e]
    Ternary(c, t, f) => [c, t, f]
    // Operand first, fill value second — so the naming walk finds the
    // operand's name before the value's, exactly as the old ternary
    // lowering's `then`-before-`otherwise` order did.
    FillNull(o, v) | FillNan(o, v) => [o, v]
    // The `IsIn` set is literal data, not sub-expressions — only the operand is
    // a child. `IsBetween` lists its operand and both bounds.
    IsIn(e, _) => [e]
    IsBetween(x, lo, hi, _) => [x, lo, hi]
    Map(_, inputs, _) => inputs.copy()
    MapBatches(_, inputs, _, _) => inputs.copy()
  }
}

///|
/// Every column name the tree references, as a set — membership only;
/// iteration order is neither significant nor guaranteed. A `Ternary`'s
/// condition counts — the optimizer must keep a column alive even if only
/// the condition reads it — unlike output *naming*, which draws from the
/// value branches only. Duplicates collapse: `col("a") + col("a")`
/// references `{"a"}`.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::referenced_columns(self : Expr) -> @set.Set[String] {
  let acc : @set.Set[String] = @set.Set([])
  collect_columns(self, acc)
  acc
}

///|
/// Depth-first, left-to-right accumulation behind `referenced_columns`:
/// record a `Col`'s name, then recurse into every child. Only the naming
/// leaf is special-cased; the recursion rides `Expr::children`, so a new
/// variant is covered the moment it declares its children there.
fn collect_columns(expr : Expr, acc : @set.Set[String]) -> Unit {
  // Walk an explicit heap stack rather than the call stack: a deeply nested
  // user-built tree (`col("a") + col("a") + …` tens of thousands deep) would
  // otherwise overflow the native stack and abort — breaking the "total —
  // nothing can fail" contract these introspection walks promise. Children are
  // pushed right-to-left so the leftmost pops first — consistent with the other
  // explicit-stack walks (`leftmost_name` / `write_expr`); for a `Set` result
  // the visit order is not observable anyway.
  let stack : Array[Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) => {
        match e {
          Col(name) => acc.add(name)
          _ => ()
        }
        let children = e.children()
        for i = children.length() - 1; i >= 0; i = i - 1 {
          stack.push(children[i])
        }
      }
    }
  }
}

///|
/// The output-column name this expression produces — Polars' naming rule:
/// an alias wins, otherwise the leftmost column reference's name,
/// otherwise `"literal"` for a column-less tree. One rule, two consumers
/// that must never drift apart: the eager materialisers in `frame`
/// (`with_columns` / `select` / `agg`) name their output
/// columns with it, and the lazy optimizer's projection pushdown uses it
/// to know which names a deferred `with_columns` stage *defines* — a
/// defined name need not exist in the stage's input, so pruning must not
/// require it there. Total — naming walks plain data.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::output_name(self : Expr) -> String {
  leftmost_name(self).unwrap_or("literal")
}

///|
/// Depth-first, left-to-right search for the first *naming* node behind
/// `output_name`. An `Alias` names its whole subtree, so an alias anywhere
/// on the leftmost path wins over the `Col` beneath it; the wrappers
/// (`Unary` / `Agg` / `Cast`) and the binary / map operands are
/// name-transparent, so the search rides `Expr::children` for them, taking
/// the first child to yield a name (a `Map` is thus named after its leftmost
/// input, like Polars' `map_elements`). A `LitSeries` names itself after the
/// series it carries — like a `Col`, so a bare `lit_series(s)` outputs a
/// column named `s.name()`. A `Ternary` draws its name from the value branches —
/// `then` first, `otherwise` as fallback — never from the condition (the
/// condition gates rows, it does not produce output values), so it is
/// matched explicitly rather than walking all of its children.
/// (`referenced_columns`, by contrast, includes condition columns —
/// pushdown must keep them alive.)
fn leftmost_name(expr : Expr) -> String? {
  // Leftmost-first search over an explicit stack (see `collect_columns` for why
  // the call stack is avoided). The first naming node reached — `Col` /
  // `LitSeries` / `Alias` — wins. A `Ternary` names itself from the value
  // branches only (`then` before `otherwise`), never the condition, so it
  // pushes just those two; every other composite rides `children` with the
  // leftmost on top. Leaves with no name (a bare `Lit`) fall through to `None`.
  let stack : Array[Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          Col(name) => return Some(name)
          LitSeries(s) => return Some(s.name())
          Alias(_, name) => return Some(name)
          Ternary(_, t, f) => {
            stack.push(f)
            stack.push(t)
          }
          _ => {
            let children = e.children()
            for i = children.length() - 1; i >= 0; i = i - 1 {
              stack.push(children[i])
            }
          }
        }
    }
  }
  None
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
  StrSuffix(StrOp)
}

///|
/// Renderer behind `Show`, driven by an explicit heap stack instead of the call
/// stack so a deeply nested tree can't overflow and abort (see
/// `collect_columns`). Every composite form is self-delimiting (parentheses or
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
  let tasks : Array[WriteTask] = match expr {
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
    Binary(op, l, r) =>
      [Frag("("), Node(l), Frag(" \{binop_symbol(op)} "), Node(r), Frag(")")]
    Unary(op, e) =>
      match op {
        Neg => [Frag("(-"), Node(e), Frag(")")]
        Not => [Frag("(not "), Node(e), Frag(")")]
        IsNull => [Node(e), Frag(".is_null()")]
        IsNotNull => [Node(e), Frag(".is_not_null()")]
        IsNan => [Node(e), Frag(".is_nan()")]
        IsNotNan => [Node(e), Frag(".is_not_nan()")]
        Abs => [Node(e), Frag(".abs()")]
        Floor => [Node(e), Frag(".floor()")]
        Ceil => [Node(e), Frag(".ceil()")]
        Sign => [Node(e), Frag(".sign()")]
        Round(0) => [Node(e), Frag(".round()")]
        Round(d) => [Node(e), Frag(".round(decimals=\{d})")]
      }
    Agg(op, e) => [Node(e), Frag(agg_suffix(op))]
    Str(op, e) => [Node(e), StrSuffix(op)]
    Cast(e, target) => [Node(e), Frag(".cast("), CastTarget(target), Frag(")")]
    Alias(e, name) => [Node(e), Frag(" as \{@text.escape_debug(name)}")]
    Ternary(c, t, f) =>
      [
        Frag("when("),
        Node(c),
        Frag(").then("),
        Node(t),
        Frag(").otherwise("),
        Node(f),
        Frag(")"),
      ]
    // Postfix method-call form, mirroring the construction route — the
    // operand appears once, so a chained coalesce renders linearly.
    FillNull(o, v) => [Node(o), Frag(".fill_null("), Node(v), Frag(")")]
    FillNan(o, v) => [Node(o), Frag(".fill_nan("), Node(v), Frag(")")]
    // `col(a).is_in([1, 2])`: the operand, then each set member rendered as a
    // literal (`format_scalar`, like a `Lit`) inside `[...]`.
    IsIn(operand, members) => {
      let ts : Array[WriteTask] = [Node(operand), Frag(".is_in([")]
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
        Node(x),
        Frag(".is_between("),
        Node(lo),
        Frag(", "),
        Node(hi),
      ]
      match closed {
        ClosedInterval::Both => ()
        ClosedInterval::Left => ts.push(Frag(", closed=Left"))
        ClosedInterval::Right => ts.push(Frag(", closed=Right"))
        ClosedInterval::None => ts.push(Frag(", closed=None"))
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
        ts.push(Node(inputs[i]))
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
        ts.push(Node(inputs[i]))
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
fn binop_symbol(op : BinOp) -> String {
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
fn agg_suffix(op : AggOp) -> String {
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
fn write_str_suffix(logger : &Logger, op : StrOp) -> Unit {
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
