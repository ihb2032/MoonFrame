// The decimal value-fence. The pushdown passes' crossing gates are
// structural — row-stability, group-cell stability — and a structural
// argument covers only failures that raise on scope-independent facts (a
// dtype mismatch, a missing column). `Decimal` is the one dtype whose
// failures do not fit that coverage: its arithmetic aligns scales with
// checked multiplies, its cross-scale comparison lifts buffers the same
// way, and its `sum` folds with a checked add — each refusing on *values*
// past the 18-digit envelope, and a value-raising refusal lives on the very
// rows a pushdown prunes away. The error-faithfulness promise (a plan that
// fails to collect still fails after optimization) is what this fence
// keeps true for those refusals: a stage whose expressions combine decimal
// cells stays a floor, and so does a predicate that does.

///|
/// Every column name that is decimal anywhere in the plan — the union of
/// each stage's decimal outputs over the whole tree. The crossing gates
/// consult this one set rather than a per-stage snapshot because a name
/// can be a decimal column at the scope an expression reads and a
/// same-named non-decimal column at another, and only the wider reading is
/// sound: the set over-approximates, so a fence it triggers is never
/// narrower than the truth, and the queries that pay are the ones decimal
/// columns ride in. A projection output counts as decimal when its
/// expression so much as reads a decimal column or sums (the `sum` of a
/// decimal column is decimal whatever wraps it). The file source infers no
/// decimal columns today (its dtype probes stop at `Int` / `Float` /
/// `Bool` / `String` / `Date` / `Timestamp`), so its arm starts empty — a
/// rider reaching file inference revisits it. Walked over the shared
/// post-order with an explicit value stack, total at any depth like the
/// passes it serves.
fn decimal_names_in_plan(plan : LogicalPlan) -> @set.Set[String] {
  let out : @set.Set[String] = @set.Set([])
  let values : Array[@set.Set[String]] = []
  for node in plan.post_order() {
    match node {
      Scan(InMemory(df)) => {
        let cols = @set.Set([])
        for f in df.schema().fields() {
          if f.dtype() is @types.DataType::Decimal(_) {
            cols.add(f.name())
          }
        }
        cols.each(name => out.add(name))
        values.push(cols)
      }
      Scan(File(_)) => values.push(@set.Set([]))
      Unary(_, Select(exprs)) => {
        let below = pop_top(values)
        below.each(name => out.add(name))
        let cols = @set.Set([])
        let defined = @set.Set([])
        for e in exprs {
          defined.add(e.output_name())
          if expr_touches_decimal(e.node(), below) {
            cols.add(e.output_name())
          }
        }
        below.each(name => if !defined.contains(name) { cols.add(name) })
        values.push(cols)
      }
      Unary(_, WithColumns(exprs)) => {
        let below = pop_top(values)
        below.each(name => out.add(name))
        let cols = @set.Set([])
        let defined = @set.Set([])
        for e in exprs {
          defined.add(e.output_name())
          if expr_touches_decimal(e.node(), below) {
            cols.add(e.output_name())
          }
        }
        below.each(name => if !defined.contains(name) { cols.add(name) })
        values.push(cols)
      }
      // The row verbs (filter / sort / window / gather) rename nothing, so
      // the child's set stays the top of the stack unread.
      Unary(_, _) => ()
      Aggregate(_, keys, exprs) => {
        let below = pop_top(values)
        below.each(name => out.add(name))
        let cols = @set.Set([])
        for e in keys {
          if expr_touches_decimal(e.node(), below) {
            cols.add(e.output_name())
          }
        }
        for e in exprs {
          if expr_touches_decimal(e.node(), below) {
            cols.add(e.output_name())
          }
        }
        values.push(cols)
      }
      // A whole-frame aggregation keeps no input names; the conservative
      // pass-through below costs nothing because the pushdown passes
      // never cross one, so its set is only ever read by a stage above
      // that fences on the union anyway.
      AggregateAll(_, _, _) => ()
      Join(_, _, _) => {
        ignore(pop_top(values))
        ignore(pop_top(values))
        values.push(@set.Set([]))
      }
    }
  }
  ignore(pop_top(values))
  out
}

///|
/// Whether any node of the expression reads a column from `risk` or is a
/// decimal literal. Iterative over an explicit stack, so expression depths
// the engine pins walk without recursing.
fn expr_touches_decimal(expr : @ir.ExprNode, risk : @set.Set[String]) -> Bool {
  let stack : Array[@ir.ExprNode] = [expr]
  while stack.length() > 0 {
    let node = pop_top(stack)
    match node {
      @ir.ExprNode::Col(name) => if risk.contains(name) { return true }
      @ir.ExprNode::Lit(@types.Scalar::Decimal(_, _)) => return true
      _ =>
        for kid in node.children() {
          stack.push(kid)
        }
    }
  }
  false
}

///|
/// Whether any node of the expression is an arithmetic / comparison
/// binary or a `Sum` aggregation — the shapes whose decimal operands carry
/// the checked refusals. The shape test alone fences nothing: an `Int`
/// sum wraps and a `Float` one absorbs, which is why the risk set decides
/// alongside it.
fn expr_has_decimal_checked_op(expr : @ir.ExprNode) -> Bool {
  let stack : Array[@ir.ExprNode] = [expr]
  while stack.length() > 0 {
    let node = pop_top(stack)
    match node {
      @ir.ExprNode::Binary(op, _, _) =>
        match op {
          @ir.BinOp::Add
          | @ir.BinOp::Sub
          | @ir.BinOp::Mul
          | @ir.BinOp::Div
          | @ir.BinOp::FloorDiv
          | @ir.BinOp::Mod
          | @ir.BinOp::Pow
          | @ir.BinOp::Eq
          | @ir.BinOp::Ne
          | @ir.BinOp::Lt
          | @ir.BinOp::Le
          | @ir.BinOp::Gt
          | @ir.BinOp::Ge => return true
          // The logical pair carries no values of its own: the descent must
          // keep walking through it or a decimal comparison joined by
          // `and` / `or` reads as value-safe.
          @ir.BinOp::And | @ir.BinOp::Or =>
            for kid in node.children() {
              stack.push(kid)
            }
        }
      @ir.ExprNode::Agg(@series.ReduceOp::Sum, _) => return true
      _ =>
        for kid in node.children() {
          stack.push(kid)
        }
    }
  }
  false
}

///|
/// Whether evaluating the expression can refuse on a *value* — the decimal
/// checked refusals — in the scope it runs in: the tree combines decimal
/// cells arithmetically, orders them, or sums them.
fn value_raises_on_decimal(
  expr : @ir.ExprNode,
  risk : @set.Set[String],
) -> Bool {
  expr_touches_decimal(expr, risk) && expr_has_decimal_checked_op(expr)
}

///|
/// The crossing-point form: whether any of a stage's expressions carries
/// the decimal checked refusals. A stage that passes stays crossable by
/// every structural gate as before; one that fails is a floor.
fn stage_value_raises(
  exprs : Array[@expr.Expr],
  risk : @set.Set[String],
) -> Bool {
  exprs.any(e => value_raises_on_decimal(e.node(), risk))
}
