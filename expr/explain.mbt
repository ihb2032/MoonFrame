///|
/// Introspection over the expression tree: a handwritten `Show` rendering
/// the documented operator form, `explain` exposing that rendering as a
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
/// Handwritten `@debug.Debug`: the `Map` variant's closure payload has no
/// `Debug`, so the enum cannot `derive` one. The debug form delegates to
/// the `Show` rendering (`explain`), which already presents every variant —
/// `Map` by its `(label, inputs)`, the closure opaque — in the documented
/// operator form. Debug output surfaces only in `assert_eq` failure messages
/// and `debug_inspect`; the structural comparison itself rides the
/// handwritten `Eq`. `Repr` has no public constructor, so delegating to an
/// existing `Debug` (here `String`'s) is the one way to build one.
pub impl @debug.Debug for Expr with fn to_repr(self) {
  @debug.Debug::to_repr(self.explain())
}

///|
/// The `Show` rendering as a `String` — the human-readable face of an
/// expression for demos, docs, and (from L1 on) per-node plan lines in
/// `LazyFrame::explain`.
pub fn Expr::explain(self : Expr) -> String {
  self.to_string()
}

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
    Map(_, inputs, _) => inputs.copy()
  }
}

///|
/// Every column name the tree references, as a set — membership only;
/// iteration order is neither significant nor guaranteed. A `Ternary`'s
/// condition counts — the optimizer must keep a column alive even if only
/// the condition reads it — unlike output *naming*, which draws from the
/// value branches only. Duplicates collapse: `col("a") + col("a")`
/// references `{"a"}`.
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
/// writers that take more than a plain string (`write_scalar` for a `Lit`, a
/// `Cast` target, a `Str` suffix).
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
          ScalarLit(v) => write_scalar(logger, v)
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
    // string literal (`write_scalar` quotes those), so `col("x")` stays distinct
    // from `lit_str("x")` in a plan line. A name containing literal parens can
    // therefore read paren-ambiguously (`col(a)b)`); that is display-only and
    // accepted — `explain` output is diagnostic, not re-parsed.
    Col(name) => [Frag("col(" + @types.escape_debug(name) + ")")]
    Lit(value) => [ScalarLit(value)]
    // The embedded data is opaque to the rendering, so a `LitSeries` shows its
    // name (quoted / escaped like a string literal) and length —
    // `lit_series("flag", 4)` — enough to read a plan line without dumping
    // every cell.
    LitSeries(s) =>
      [
        Frag(
          "lit_series(\"" +
          @types.escape_debug(s.name()) +
          "\", " +
          s.len().to_string() +
          ")",
        ),
      ]
    Binary(op, l, r) =>
      [
        Frag("("),
        Node(l),
        Frag(" " + binop_symbol(op) + " "),
        Node(r),
        Frag(")"),
      ]
    Unary(op, e) =>
      match op {
        Neg => [Frag("(-"), Node(e), Frag(")")]
        Not => [Frag("(not "), Node(e), Frag(")")]
        IsNull => [Node(e), Frag(".is_null()")]
        IsNotNull => [Node(e), Frag(".is_not_null()")]
        IsNan => [Node(e), Frag(".is_nan()")]
        IsNotNan => [Node(e), Frag(".is_not_nan()")]
      }
    Agg(op, e) => [Node(e), Frag(agg_suffix(op))]
    Str(op, e) => [Node(e), StrSuffix(op)]
    Cast(e, target) => [Node(e), Frag(".cast("), CastTarget(target), Frag(")")]
    Alias(e, name) => [Node(e), Frag(" as " + @types.escape_debug(name))]
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
    // The closure is opaque, so a `Map` renders by its label and inputs:
    // `map("label", [in1, in2])`. The label is quoted / escaped like a string
    // literal so it stays on one unambiguous line.
    Map(label, inputs, _) => {
      let ts : Array[WriteTask] = [
        Frag("map(\"" + @types.escape_debug(label) + "\", ["),
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
  }
  for i = tasks.length() - 1; i >= 0; i = i - 1 {
    stack.push(tasks[i])
  }
}

///|
/// Bare-value rendering for literals. Strings are quoted so `lit_str("x")`
/// and `col("x")` stay distinguishable, and the (unevaluatable) null
/// literal renders as `null` — this is display syntax, not the debug form
/// `Scalar`'s own `Show` produces.
fn write_scalar(logger : &Logger, value : @types.Scalar) -> Unit {
  match value {
    Int(v) => logger.write_string(v.to_string())
    Float(v) => {
      // `Double::to_string` prints a finite whole value without a decimal
      // point (`1.0` -> `"1"`), which would read as `lit_int(1)`; append
      // `.0` so a `Float` literal stays distinct from an `Int` one. `NaN` /
      // `Infinity` / `-Infinity` are non-finite (`v - v != 0`) and keep their
      // own spelling.
      let s = v.to_string()
      let finite = v - v == 0.0
      let has_point = s.iter().any(c => c == '.' || c == 'e' || c == 'E')
      if finite && !has_point {
        logger.write_string(s + ".0")
      } else {
        logger.write_string(s)
      }
    }
    Bool(v) => logger.write_string(v.to_string())
    String(v) => {
      logger.write_string("\"")
      logger.write_string(@types.escape_debug(v))
      logger.write_string("\"")
    }
    Null => logger.write_string("null")
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
  }
}

///|
/// Render one parameterised string-op call `.name("arg", …)`, each argument
/// quoted and `escape_debug`-escaped exactly like a `lit_str` in
/// `write_scalar`, so a pattern containing a `"` or a control character stays
/// on one unambiguous line.
fn write_str_call(
  logger : &Logger,
  name : String,
  args : Array[String],
) -> Unit {
  logger.write_string(".")
  logger.write_string(name)
  logger.write_string("(")
  logger.write_string(args.map(a => "\"\{@types.escape_debug(a)}\"").join(", "))
  logger.write_string(")")
}
