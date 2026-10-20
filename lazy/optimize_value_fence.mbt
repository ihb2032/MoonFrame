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
/// The decimal risk a plan carries: the union of each stage's decimal
/// output names over the whole tree, plus an `any` flag. The crossing gates
/// consult this one set rather than a per-stage snapshot because a name
/// can be a decimal column at the scope an expression reads and a
/// same-named non-decimal column at another, and only the wider reading is
/// sound: the set and the flag over-approximate together, so a fence they
/// trigger is never narrower than the truth, and the queries that pay are
/// the ones decimal columns ride in. A projection output counts as decimal
/// when its expression so much as reads a decimal column or sums (the `sum`
/// of a decimal column is decimal whatever wraps it). The file source infers
/// no decimal columns today (its dtype probes stop at `Int` / `Float` /
/// `Bool` / `String` / `Date` / `Timestamp`), so its arm starts empty — a
/// rider reaching file inference revisits it.
///
/// The names must survive every verb that renames or reshapes columns, or a
/// stage above it reads a name the set never learned: a `rename` applies its
/// pairs, a `rename_with` runs its closure on the real column names (the
/// same calls collect makes — the closure is total, so this is evaluation,
/// not inspection), an `unpivot` folds its value columns into one named
/// column, and a `join` unions both sides and adds every right name's
/// suffixed form, mirroring `frame`'s clash rule conservatively (only a
/// clashing right column gains the suffix at collect; adding it for all of
/// them fences more, never less). A `pivot` is the one reshaper whose output
/// names come from data, so it raises `any` — above a pivot no name is
/// provably non-decimal, and every decimal-checked stage fences. Walked
/// over the shared post-order with an explicit value stack, total at any
/// depth like the passes it serves.
fn decimal_names_in_plan(plan : LogicalPlan) -> DecimalRisk {
  let out : @set.Set[String] = @set.Set([])
  let mut any = false
  let values : Array[DecimalRisk] = []
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
        values.push({ names: cols, any: false, })
      }
      Scan(File(_)) => values.push({ names: @set.Set([]), any: false, })
      Unary(_, Select(exprs)) => {
        let below = pop_top(values)
        below.names.each(name => out.add(name))
        let cols = @set.Set([])
        let defined = @set.Set([])
        for e in exprs {
          defined.add(e.output_name())
          if below.any || expr_touches_decimal(e.node(), below.names) {
            cols.add(e.output_name())
          }
        }
        below.names.each(name => if !defined.contains(name) { cols.add(name) })
        values.push({ names: cols, any: below.any, })
      }
      Unary(_, WithColumns(exprs)) => {
        let below = pop_top(values)
        below.names.each(name => out.add(name))
        let cols = @set.Set([])
        let defined = @set.Set([])
        for e in exprs {
          defined.add(e.output_name())
          if below.any || expr_touches_decimal(e.node(), below.names) {
            cols.add(e.output_name())
          }
        }
        below.names.each(name => if !defined.contains(name) { cols.add(name) })
        values.push({ names: cols, any: below.any, })
      }
      Unary(_, Rename(pairs)) => {
        let below = pop_top(values)
        below.names.each(name => out.add(name))
        let renamed = @set.Set([])
        below.names.each(name => {
          let mut target = name
          // Indexed access rather than a tuple pattern: the coverage
          // reporter's parser cannot parse a tuple pattern in a `for`
          // header, and a source it cannot parse fails the coverage
          // gate.
          for pair in pairs {
            if pair.0 == name {
              target = pair.1
              break
            }
          }
          renamed.add(target)
        })
        values.push({ names: renamed, any: below.any, })
      }
      // The closure is total and collect runs it on exactly these column
      // names, so running it here reads the mapping rather than guessing it.
      Unary(_, RenameWith(f)) => {
        let below = pop_top(values)
        below.names.each(name => out.add(name))
        let renamed = @set.Set([])
        below.names.each(name => renamed.add(f(name)))
        values.push({ names: renamed, any: below.any, })
      }
      // The folded value columns land in one `value_name` column; the index
      // side keeps its names, so the child's set rides along beside it.
      Unary(_, Unpivot(_, _, _, value_name)) => {
        let below = pop_top(values)
        below.names.each(name => out.add(name))
        let cols = @set.Set([])
        below.names.each(name => cols.add(name))
        cols.add(value_name)
        values.push({ names: cols, any: below.any, })
      }
      // A pivot's output column names come from the data it reshapes, so no
      // name above it is provably non-decimal: the flag fences every
      // decimal-checked stage there.
      Unary(_, Pivot(_, _, _, _)) => {
        let below = pop_top(values)
        below.names.each(name => out.add(name))
        any = true
        values.push({ names: below.names, any: true, })
      }
      // The row verbs (filter / sort / window / gather / drop / …) rename
      // nothing, so the child's risk stays the top of the stack unread.
      Unary(_, _) => ()
      Aggregate(_, keys, exprs) => {
        let below = pop_top(values)
        below.names.each(name => out.add(name))
        let cols = @set.Set([])
        for e in keys {
          if below.any || expr_touches_decimal(e.node(), below.names) {
            cols.add(e.output_name())
          }
        }
        for e in exprs {
          if below.any || expr_touches_decimal(e.node(), below.names) {
            cols.add(e.output_name())
          }
        }
        values.push({ names: cols, any: below.any, })
      }
      // A whole-frame aggregation reuses its input column names (each
      // non-key column aggregates under its own name), so the child's set
      // passing through is exact, not merely conservative — and the pushdown
      // passes never cross one anyway.
      AggregateAll(_, _, _) => ()
      Join(_, _, options) => {
        let right = pop_top(values)
        let left = pop_top(values)
        left.names.each(name => out.add(name))
        right.names.each(name => out.add(name))
        let merged = @set.Set([])
        left.names.each(name => merged.add(name))
        right.names.each(name => merged.add(name))
        right.names.each(name => merged.add(name + options.suffix))
        values.push({ names: merged, any: left.any || right.any, })
      }
    }
  }
  let root = pop_top(values)
  root.names.each(name => out.add(name))
  { names: out, any: any || root.any, }
}

///|
/// The decimal names a stage's expressions are checked against, plus the
/// pivot-raised flag that makes every column a suspect.
priv struct DecimalRisk {
  names : @set.Set[String]
  any : Bool
}

///|
/// Whether any node of the expression reads a column from `risk` or is a
/// decimal literal. Iterative over an explicit stack, so expression depths
/// the engine pins walk without recursing.
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
/// binary, one of the comparison sugar nodes, or a `Sum` aggregation —
/// the shapes whose decimal operands carry the checked refusals. The shape
/// test alone fences nothing: an `Int` sum wraps and a `Float` one absorbs,
/// which is why the risk set decides alongside it.
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
      // `is_between` and `is_in` are the comparison sugar: they descend into
      // the same `eval_compare` rescale a `Ge` / `Eq` takes, so a decimal
      // operand can refuse on values through them exactly as through the
      // binary spellings.
      @ir.ExprNode::IsBetween(_, _, _, _) => return true
      @ir.ExprNode::IsIn(_, _) => return true
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
/// cells arithmetically, orders them, or sums them. The pivot-raised `any`
/// makes every column read a potential decimal one.
fn value_raises_on_decimal(expr : @ir.ExprNode, risk : DecimalRisk) -> Bool {
  (risk.any || expr_touches_decimal(expr, risk.names)) &&
  expr_has_decimal_checked_op(expr)
}

///|
/// The crossing-point form: whether any of a stage's expressions carries
/// the decimal checked refusals. A stage that passes stays crossable by
/// every structural gate as before; one that fails is a floor.
fn stage_value_raises(exprs : Array[@expr.Expr], risk : DecimalRisk) -> Bool {
  exprs.any(e => value_raises_on_decimal(e.node(), risk))
}
