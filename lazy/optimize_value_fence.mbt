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
//
// This walk is one of three spellings of "how a verb reshapes column
// names": `frame`'s verbs are the semantics, the exact-vocabulary walk
// `frame_op_names` (the one the joins read for positive attribution) is
// exact where it must be, and this walk over-approximates the same
// propagation (both its liberties are the fence-more direction). The
// Rename step runs the pairs sequentially over the decimal subset, the
// over-approximating mirror of the exact walk's `sequential_rename` — a
// change to how `rename` spells its output reaches both walks, so the
// two are edited together.

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
  let risks : Array[PlanRisk] = []
  for node in plan.post_order() {
    risks.push(plan_risk_step(node, risks))
  }
  let acc = pop_top(risks)
  { names: acc.union, any: acc.any, }
}

///|
/// The per-subtree accumulator the incremental risk walk carries: `stage`
/// is the decimal output names of the subtree's own top stage (the value
/// the walk's arms propagate, unchanged by the row verbs that rename
/// nothing), `union` is every stage name the whole subtree contributes to
/// the plan-wide set, and `any` is whether a `Pivot` sits anywhere in it.
/// The pair (`stage`, `union`) is what the flat `DecimalRisk` folds: a
/// subtree reports `union` at its own root, and propagates `stage` to its
/// parent's arm.
priv struct PlanRisk {
  stage : @set.Set[String]
  union : @set.Set[String]
  any : Bool
}

///|
/// One node's step of the bottom-up risk walk: pops the (already
/// processed) children's accumulators off `risks` and pushes this
/// subtree's — the same per-arm propagation the walk used to spell inside
/// its own loop, factored out so the pushdown passes can run it alongside
/// their rebuild stacks and know each rebuilt subtree's risk without
/// re-walking it (a stack of F filters paid one full walk each, Θ(F·N);
/// the shared step keeps every pass Θ(N)). The row verbs and
/// `AggregateAll` are pass-throughs: the child's accumulator pops and
/// returns as the node's own, exactly as the child's value stayed on the
/// walk's stack unread.
fn plan_risk_step(node : LogicalPlan, risks : Array[PlanRisk]) -> PlanRisk {
  match node {
    Scan(InMemory(df)) => {
      let cols = @set.Set([])
      for f in df.schema().fields() {
        if f.dtype() is @types.DataType::Decimal(_) {
          cols.add(f.name())
        }
      }
      { stage: cols, union: cols, any: false, }
    }
    Scan(File(_)) => {
      let empty = @set.Set([])
      { stage: empty, union: empty, any: false, }
    }
    Unary(_, Select(exprs)) => {
      let below = pop_top(risks)
      let stage = stage_of_exprs(exprs, below)
      { stage, union: union_with(below, stage), any: below.any, }
    }
    Unary(_, WithColumns(exprs)) => {
      let below = pop_top(risks)
      let stage = stage_of_exprs(exprs, below)
      { stage, union: union_with(below, stage), any: below.any, }
    }
    Unary(_, Rename(pairs)) => {
      let below = pop_top(risks)
      // `DataFrame::rename` applies its pairs sequentially, so a decimal
      // name can ride several steps to its final one — a first-match
      // mapping loses exactly that. The replay here runs over the
      // *decimal subset*, not the frame's full name set: a pair whose
      // source is absent is a no-op (its source is merely non-decimal —
      // or the verb raises and the plan fails at collect, where fencing
      // is moot), and the subset never infers the verb's collisions,
      // which live against non-decimal names it cannot see. Both
      // liberties are the over-approximating direction: a decimal name
      // stays in the risk set unless a pair provably moved it.
      let renamed = @set.Set([])
      below.stage.each(name => renamed.add(name))
      // Indexed access rather than a tuple pattern: the coverage
      // reporter's parser cannot parse a tuple pattern in a `for`
      // header, and a source it cannot parse fails the coverage gate.
      for pair in pairs {
        let old_name = pair.0
        let new_name = pair.1
        if renamed.contains(old_name) {
          renamed.remove(old_name)
          renamed.add(new_name)
        }
      }
      { stage: renamed, union: union_with(below, renamed), any: below.any, }
    }
    // The closure is total and collect runs it on exactly these column
    // names, so running it here reads the mapping rather than guessing it.
    Unary(_, RenameWith(f)) => {
      let below = pop_top(risks)
      let renamed = @set.Set([])
      below.stage.each(name => renamed.add(f(name)))
      { stage: renamed, union: union_with(below, renamed), any: below.any, }
    }
    // The folded value columns land in one `value_name` column; the index
    // side keeps its names, so the child's stage rides along beside it.
    Unary(_, Unpivot(_, _, _, value_name)) => {
      let below = pop_top(risks)
      let cols = @set.Set([])
      below.stage.each(name => cols.add(name))
      cols.add(value_name)
      { stage: cols, union: union_with(below, cols), any: below.any, }
    }
    // A pivot's output column names come from the data it reshapes, so no
    // name above it is provably non-decimal: the flag fences every
    // decimal-checked stage there.
    Unary(_, Pivot(_, _, _, _)) => {
      let below = pop_top(risks)
      { stage: below.stage, union: union_with(below, below.stage), any: true, }
    }
    // The row verbs (filter / sort / window / gather / drop / fill / …)
    // rename nothing, so the child's accumulator is the node's own. For
    // the verbs that do drop or replace columns (`Drop`, `WithRowIndex`,
    // `Reduce`) keeping the old names is the over-approximating direction
    // — a decimal name that no longer exists can only fence more, never
    // less. Exhaustive on purpose, mirroring `frame_op_names` — the exact
    // vocabulary walk, which lists the same verbs as its own pass-through
    // set: a verb added to `FrameOp` fails this match until it declares
    // here whether decimal names ride through it, instead of falling into
    // a silent default.
    Unary(_, Filter(_))
    | Unary(_, Sort(_))
    | Unary(_, Head(_))
    | Unary(_, Tail(_))
    | Unary(_, Slice(_, _))
    | Unary(_, GatherEvery(_, _))
    | Unary(_, TopK(_, _, _))
    | Unary(_, BottomK(_, _, _))
    | Unary(_, Drop(_))
    | Unary(_, Unique(_, _))
    | Unary(_, Reverse)
    | Unary(_, WithRowIndex(_, _))
    | Unary(_, DropNulls(_))
    | Unary(_, FillNull(_))
    | Unary(_, FillNullDir(_, _))
    | Unary(_, FillNan(_))
    | Unary(_, Reduce(_)) => pop_top(risks)
    Aggregate(_, keys, exprs) => {
      let below = pop_top(risks)
      let cols = @set.Set([])
      for e in keys {
        if below.any || expr_touches_decimal(e.node(), below.stage) {
          cols.add(e.output_name())
        }
      }
      for e in exprs {
        if below.any || expr_touches_decimal(e.node(), below.stage) {
          cols.add(e.output_name())
        }
      }
      { stage: cols, union: union_with(below, cols), any: below.any, }
    }
    // A whole-frame aggregation reuses its input column names (each
    // non-key column aggregates under its own name), so the child's set
    // passing through is exact, not merely conservative — and the pushdown
    // passes never cross one anyway.
    AggregateAll(_, _, _) => pop_top(risks)
    Join(_, _, options) => {
      let right = pop_top(risks)
      let left = pop_top(risks)
      let merged = @set.Set([])
      left.stage.each(name => merged.add(name))
      right.stage.each(name => merged.add(name))
      right.stage.each(name => merged.add(name + options.suffix))
      let union = @set.Set([])
      left.union.each(name => union.add(name))
      right.union.each(name => union.add(name))
      merged.each(name => union.add(name))
      { stage: merged, union, any: left.any || right.any, }
    }
  }
}

///|
/// The decimal output names of a projection-style stage (`Select` /
/// `WithColumns`): an expression's output counts when it so much as reads
/// a decimal name the stage below carries (or the below stages raised
/// `any`), and a carried name that no expression redefines survives
/// verbatim.
fn stage_of_exprs(
  exprs : Array[@expr.Expr],
  below : PlanRisk,
) -> @set.Set[String] {
  let cols = @set.Set([])
  let defined = @set.Set([])
  for e in exprs {
    defined.add(e.output_name())
    if below.any || expr_touches_decimal(e.node(), below.stage) {
      cols.add(e.output_name())
    }
  }
  below.stage.each(name => if !defined.contains(name) { cols.add(name) })
  cols
}

///|
/// Fold one stage's contribution into a subtree's union: the child's union
/// plus this stage's own names (a fresh set — the child's accumulators are
/// consumed, never shared, so a caller cannot mutate them through the
/// result).
fn union_with(below : PlanRisk, stage : @set.Set[String]) -> @set.Set[String] {
  let union = @set.Set([])
  below.union.each(name => union.add(name))
  stage.each(name => union.add(name))
  union
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
      _ => node.each_child(kid => stack.push(kid))
    }
  }
  false
}

///|
/// Whether any node of the expression is an arithmetic / comparison
/// binary, one of the comparison sugar nodes, the checked unary pair, or a
/// `Sum` aggregation — the shapes whose decimal operands carry the checked
/// refusals. The shape test alone fences nothing: an `Int` sum wraps and a
/// `Float` one absorbs, which is why the risk set decides alongside it.
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
          // `and` / `or` reads as value-safe. The math pair `atan2` / `hypot`
          // refuses a decimal operand on the dtype alone (decimal is not
          // numeric), a scope-independent fact — value-safe for the same
          // reason, so it walks too.
          @ir.BinOp::And
          | @ir.BinOp::Or
          | @ir.BinOp::Atan2
          | @ir.BinOp::Hypot =>
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
      // The checked unary pair: `neg` / `abs` refuse on an 18-digit
      // magnitude the way the arithmetics refuse on their overflow, and
      // the descent must not read through them as value-safe.
      @ir.ExprNode::Unary(@ir.UnOp::Neg, _) => return true
      @ir.ExprNode::Unary(@ir.UnOp::Abs, _) => return true
      @ir.ExprNode::Agg(@series.ReduceOp::Sum, _) => return true
      _ => node.each_child(kid => stack.push(kid))
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
