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
/// Depth-first, left-to-right accumulation behind `referenced_columns`.
fn collect_columns(expr : Expr, acc : @set.Set[String]) -> Unit {
  match expr {
    Col(name) => acc.add(name)
    Lit(_) => ()
    Binary(_, l, r) => {
      collect_columns(l, acc)
      collect_columns(r, acc)
    }
    Unary(_, e) | Agg(_, e) | Cast(e, _) | Alias(e, _) =>
      collect_columns(e, acc)
    Ternary(c, t, f) => {
      collect_columns(c, acc)
      collect_columns(t, acc)
      collect_columns(f, acc)
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
      logger.write_string(v)
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
