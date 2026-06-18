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
    Map(_, inputs, _) => inputs.copy()
  }
}

///|
/// Every column name the tree references, in first-reference order
/// (depth-first, left to right). A `Ternary`'s condition counts — the
/// optimizer must keep a column alive even if only the condition reads
/// it — unlike output *naming*, which draws from the value branches only.
/// Duplicates collapse: `col("a") + col("a")` references `{"a"}`.
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
  match expr {
    Col(name) => acc.add(name)
    _ => ()
  }
  for child in expr.children() {
    collect_columns(child, acc)
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
  match leftmost_name(self) {
    Some(name) => name
    None => "literal"
  }
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
  match expr {
    Col(name) => Some(name)
    LitSeries(s) => Some(s.name())
    Alias(_, name) => Some(name)
    Ternary(_, t, f) =>
      match leftmost_name(t) {
        Some(name) => Some(name)
        None => leftmost_name(f)
      }
    Lit(_)
    | Binary(_, _, _)
    | Unary(_, _)
    | Agg(_, _)
    | Str(_, _)
    | Cast(_, _)
    | Map(_, _, _) => {
      for child in expr.children() {
        match leftmost_name(child) {
          Some(name) => return Some(name)
          None => ()
        }
      }
      None
    }
  }
}

///|
/// Recursive renderer behind `Show` — every composite form is
/// self-delimiting (parentheses or a closing `)` of a method call), so
/// nesting never needs context from above.
fn write_expr(logger : &Logger, expr : Expr) -> Unit {
  match expr {
    Col(name) => {
      logger.write_string("col(")
      logger.write_string(escape_debug(name))
      logger.write_string(")")
    }
    Lit(value) => write_scalar(logger, value)
    // The embedded data is opaque to the rendering, so a `LitSeries` shows
    // its name (quoted / escaped like a string literal) and length —
    // `lit_series("flag", 4)` — enough to read a plan line without dumping
    // every cell.
    LitSeries(s) => {
      logger.write_string("lit_series(\"")
      logger.write_string(escape_debug(s.name()))
      logger.write_string("\", ")
      logger.write_string(s.len().to_string())
      logger.write_string(")")
    }
    Binary(op, l, r) => {
      logger.write_string("(")
      write_expr(logger, l)
      logger.write_string(" ")
      logger.write_string(binop_symbol(op))
      logger.write_string(" ")
      write_expr(logger, r)
      logger.write_string(")")
    }
    Unary(op, e) =>
      match op {
        Neg => {
          logger.write_string("(-")
          write_expr(logger, e)
          logger.write_string(")")
        }
        Not => {
          logger.write_string("(not ")
          write_expr(logger, e)
          logger.write_string(")")
        }
        IsNull => {
          write_expr(logger, e)
          logger.write_string(".is_null()")
        }
        IsNotNull => {
          write_expr(logger, e)
          logger.write_string(".is_not_null()")
        }
        IsNan => {
          write_expr(logger, e)
          logger.write_string(".is_nan()")
        }
        IsNotNan => {
          write_expr(logger, e)
          logger.write_string(".is_not_nan()")
        }
      }
    Agg(op, e) => {
      write_expr(logger, e)
      logger.write_string(agg_suffix(op))
    }
    Str(op, e) => {
      write_expr(logger, e)
      write_str_suffix(logger, op)
    }
    Cast(e, target) => {
      write_expr(logger, e)
      logger.write_string(".cast(")
      target.output(logger)
      logger.write_string(")")
    }
    Alias(e, name) => {
      write_expr(logger, e)
      logger.write_string(" as ")
      logger.write_string(escape_debug(name))
    }
    Ternary(c, t, f) => {
      logger.write_string("when(")
      write_expr(logger, c)
      logger.write_string(").then(")
      write_expr(logger, t)
      logger.write_string(").otherwise(")
      write_expr(logger, f)
      logger.write_string(")")
    }
    // The closure is opaque, so a `Map` renders by its label and inputs:
    // `map("label", [in1, in2])`. The label is quoted / escaped like a
    // string literal so it stays on one unambiguous line.
    Map(label, inputs, _) => {
      logger.write_string("map(\"")
      logger.write_string(escape_debug(label))
      logger.write_string("\", [")
      for i in 0..<inputs.length() {
        if i > 0 {
          logger.write_string(", ")
        }
        write_expr(logger, inputs[i])
      }
      logger.write_string("])")
    }
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
    Float(v) => logger.write_string(v.to_string())
    Bool(v) => logger.write_string(v.to_string())
    String(v) => {
      logger.write_string("\"")
      logger.write_string(escape_debug(v))
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
  logger.write_string(args.map(a => "\"\{escape_debug(a)}\"").join(", "))
  logger.write_string(")")
}

///|
/// Escape a string literal for the quoted form `write_scalar` emits
/// (`"a\"b"`), so a literal containing a `"`, `\`, or a control character
/// stays unambiguous and on one line in `explain` output. A single forward
/// pass: `\` → `\\`, `"` → `\"`, newline / carriage-return / tab →
/// `\n` / `\r` / `\t`, and every other control character (the rest of C0,
/// `DEL`, and the Unicode line/paragraph separators) → a `\uXXXX` escape, so
/// a hostile column name cannot inject a newline or forge an extra line into a
/// plan rendering. (The escape set targets line injection; the C1 range
/// 0x80–0x9F is left as-is — harmless under UTF-8 output, which emits it as
/// multi-byte sequences rather than raw 8-bit controls.) Mirrors the
/// identically-named helper
/// behind `@types`' `Show` impls — kept a private duplicate here rather than
/// a shared public symbol so neither package's interface grows for a
/// presentation-only concern. Total.
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
