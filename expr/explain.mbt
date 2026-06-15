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
/// `expr as name`, and `Ternary` mirroring its
/// `when(c).then(a).otherwise(b)` construction route. Handwritten because
/// `derive(Show)` is deprecated — and the derived variant form would leak
/// construction-route noise into `explain` output anyway.
pub impl Show for Expr with fn output(self, logger) {
  write_expr(logger, self)
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
/// *naming* — special-cases it rather than reading children. Leaves
/// (`Col` / `Lit`) have none. Total — it only inspects shape.
pub fn Expr::children(self : Expr) -> Array[Expr] {
  match self {
    Col(_) | Lit(_) => []
    Binary(_, l, r) => [l, r]
    Unary(_, e) | Agg(_, e) | Cast(e, _) | Alias(e, _) => [e]
    Ternary(c, t, f) => [c, t, f]
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
/// (`with_columns` / `select_exprs` / `agg_exprs`) name their output
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
/// (`Unary` / `Agg` / `Cast`) and the binary operands are name-transparent,
/// so the search rides `Expr::children` for them, taking the first child to
/// yield a name. A `Ternary` draws its name from the value branches —
/// `then` first, `otherwise` as fallback — never from the condition (the
/// condition gates rows, it does not produce output values), so it is
/// matched explicitly rather than walking all of its children.
/// (`referenced_columns`, by contrast, includes condition columns —
/// pushdown must keep them alive.)
fn leftmost_name(expr : Expr) -> String? {
  match expr {
    Col(name) => Some(name)
    Alias(_, name) => Some(name)
    Ternary(_, t, f) =>
      match leftmost_name(t) {
        Some(name) => Some(name)
        None => leftmost_name(f)
      }
    Lit(_) | Binary(_, _, _) | Unary(_, _) | Agg(_, _) | Cast(_, _) => {
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
      logger.write_string(name)
      logger.write_string(")")
    }
    Lit(value) => write_scalar(logger, value)
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
      }
    Agg(op, e) => {
      write_expr(logger, e)
      logger.write_string(agg_suffix(op))
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
      logger.write_string(name)
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
  }
}

///|
/// Escape a string literal for the quoted form `write_scalar` emits
/// (`"a\"b"`), so a literal containing a `"`, `\`, or a control character
/// stays unambiguous and on one line in `explain` output. A single forward
/// pass: `\` → `\\`, `"` → `\"`, and newline / carriage-return / tab →
/// `\n` / `\r` / `\t`. Mirrors the identically-named helper behind
/// `@types`' `Show` impls — kept a private duplicate here rather than a
/// shared public symbol so neither package's interface grows for a
/// presentation-only concern. Total.
fn escape_debug(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s.iter() {
    if ch == '\\' {
      buf.write_char('\\')
      buf.write_char('\\')
    } else if ch == '"' {
      buf.write_char('\\')
      buf.write_char('"')
    } else if ch == '\n' {
      buf.write_char('\\')
      buf.write_char('n')
    } else if ch == '\r' {
      buf.write_char('\\')
      buf.write_char('r')
    } else if ch == '\t' {
      buf.write_char('\\')
      buf.write_char('t')
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}
