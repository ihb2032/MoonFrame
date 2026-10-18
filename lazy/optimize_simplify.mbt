// The constant-folding rule: replace a column-free subtree with the literal
// it always evaluates to. Folding is *fold-or-keep* — the candidate subtree
// is evaluated through the engine's own evaluator (the `evaluate_column_free`
// seam), and only a successful evaluation replaces the subtree; a raising
// one leaves it verbatim, so the errors a failing plan reports come from the
// same expression at the same stage as as-built. The folded value and the
// collected value are the same computation by construction — one evaluator,
// one input — so this pass cannot diverge from execution.

///|
/// One subtree's fold outcome: the (possibly rewritten) node, whether the
/// subtree is now a bare literal, and whether anything below or at this node
/// changed. The literal flag is what a parent reads to decide whether it has
/// become a fold candidate itself; `changed` drives the fixed-point loop.
priv struct Folded {
  node : @ir.ExprNode
  lit : Bool
  changed : Bool
}

///|
/// Fold an expression's column-free subtrees into literals. The foldable
/// vocabulary is the row-local pointwise operators — arithmetic, comparison,
/// logic, the unary transforms, the string namespace, casts, the alias
/// wrapper, ternaries, fills, and the set/interval probes — because for
/// those, evaluating a column-free instance once on an empty frame is
/// exactly what evaluating it at collect time does (a column-free tree is
/// length-1 at any scope height, the all-constant projection rule).
/// Deliberately outside it: a `Col` (reads a frame), an `Agg` (its cell
/// reduces a whole scope, not the empty one the fold would consult), a
/// `LitSeries` (it *is* data, of its own length), a `Positional` (its cells
/// move with the broadcast height a scope gives its operand), and a `Map` /
/// `MapBatches` (the closure would run at optimize time and stop running at
/// collect — an observable change for an impure closure, and `explain`
/// already runs the optimizer, so it would run twice). Their subtrees are
/// left untouched as whole units. The walk is the analysis pattern —
/// discovery, reverse for children-first, classify from the children's
/// outcomes — iterative and total at any depth.
fn fold_expr(expr : @expr.Expr) -> (@expr.Expr, Bool) {
  let discover : Array[@ir.ExprNode] = [expr.node()]
  let order : Array[@ir.ExprNode] = []
  let arities : Array[Int32] = []
  for ;; {
    match discover.pop() {
      None => break
      Some(node) =>
        // The excluded shapes are not descended into: their subtrees are
        // opaque units to this rule (see the header for each reason), so
        // their children never enter the walk.
        if fold_descends(node) {
          let kids = node.children()
          order.push(node)
          arities.push(kids.length())
          for k in kids {
            discover.push(k)
          }
        } else {
          order.push(node)
          arities.push(-1)
        }
    }
  }
  let values : Array[Folded] = []
  for i = order.length() - 1; i >= 0; i = i - 1 {
    let node = order[i]
    if arities[i] < 0 {
      // An excluded unit, or a bare column: kept verbatim, never literal.
      values.push({ node, lit: node is @ir.ExprNode::Lit(_), changed: false, })
      continue
    }
    // Pop the children's outcomes and restore input order — the value stack
    // yields them last-first, and unlike the fused analysis (whose verdicts
    // are order-blind conjunctions) the rebuild below slots children
    // positionally: a `Binary`'s operands and an `IsBetween`'s operand and
    // bounds are not interchangeable.
    let popped : Array[Folded] = []
    for _ in 0..<arities[i] {
      popped.push(values[values.length() - 1])
      let _ = values.pop()
    }
    let kids : Array[Folded] = Array::makei(popped.length(), k => {
      popped[popped.length() - 1 - k]
    })
    values.push(fold_node(node, kids))
  }
  let top = values[values.length() - 1]
  (@expr.Expr::of_node(top.node), top.changed)
}

///|
/// Whether the walk descends into this node's children. The only opaque
/// units are the closure carriers — a `Map` / `MapBatches` subtree is left
/// whole, so its inputs are never walked (the header of `fold_expr` states
/// why). An `Agg` / `Positional` node cannot fold itself, but its operand
/// subtree is ordinary pointwise material: a literal-only subtree inside it
/// folds like anywhere else, so the walk descends and `fold_node` fences
/// only the node's own fold.
fn fold_descends(node : @ir.ExprNode) -> Bool {
  match node {
    @ir.ExprNode::Col(_)
    | @ir.ExprNode::Lit(_)
    | @ir.ExprNode::LitSeries(_)
    | @ir.ExprNode::Map(_, _, _)
    | @ir.ExprNode::MapBatches(_, _, _, _) => false
    @ir.ExprNode::Binary(_, _, _)
    | @ir.ExprNode::Unary(_, _)
    | @ir.ExprNode::Str(_, _)
    | @ir.ExprNode::Cast(_, _)
    | @ir.ExprNode::Alias(_, _)
    | @ir.ExprNode::Ternary(_, _, _)
    | @ir.ExprNode::FillNull(_, _)
    | @ir.ExprNode::FillNan(_, _)
    | @ir.ExprNode::IsIn(_, _)
    | @ir.ExprNode::IsBetween(_, _, _, _)
    | @ir.ExprNode::Agg(_, _)
    | @ir.ExprNode::Positional(_, _) => true
  }
}

///|
/// One node's fold step: rebuild it over its (already folded) children, and
/// when every child is now a literal, try the fold itself — the engine
/// evaluator decides, and a raising evaluation keeps the node as rebuilt.
/// This is the one place a *rewrite of expression content* happens anywhere
/// in the optimizer; its license is the fold-or-keep contract on the file
/// header (same evaluator, same input, or no change at all).
fn fold_node(node : @ir.ExprNode, kids : Array[Folded]) -> Folded {
  let all_lit = kids.all(k => k.lit)
  let below_changed = kids.any(k => k.changed)
  // The node rebuilt over folded children, when any child moved.
  let rebuilt : @ir.ExprNode = if below_changed {
    let new_kids = kids.map(k => k.node)
    rebuild_over(node, new_kids)
  } else {
    node
  }
  // `Alias` is a naming boundary: the alias is the column's output name, so
  // folding the node away would rename it (a `1 as one` that folds to a bare
  // literal changes the collected schema). Its children fold; the node
  // itself stays. An `Agg` reduces a whole scope and a `Positional` reads
  // the broadcast height — neither may consult the empty frame the fold
  // uses — and a bare `Lit` is already a literal (folding it again would
  // report a change that moved nothing).
  if all_lit &&
    !(node is @ir.ExprNode::Alias(_, _) ||
    node is @ir.ExprNode::Agg(_, _) ||
    node is @ir.ExprNode::Positional(_, _) ||
    node is @ir.ExprNode::Lit(_)) {
    match @frame.evaluate_column_free(@expr.Expr::of_node(rebuilt)) {
      // A null result stays a subtree: `Lit(Null)` is the one literal the
      // engine cannot materialise (no Null-dtype column backend), so
      // folding to it would turn a collectable null cell into an
      // `Unsupported` the as-built plan never raises.
      Some(@types.Scalar::Null) =>
        return { node: rebuilt, lit: false, changed: below_changed, }
      Some(value) =>
        return { node: @ir.ExprNode::Lit(value), lit: true, changed: true, }
      None =>
        // The fold raises, so the subtree stays — the error it carries must
        // surface at collect exactly where the as-built plan reports it.
        return { node: rebuilt, lit: false, changed: below_changed, }
    }
  }
  { node: rebuilt, lit: false, changed: below_changed, }
}

///|
/// Rebuild one foldable node over new children, verbatim payloads. The
/// excluded shapes never reach this (they are not descended into), and their
/// arms keep the node unchanged as a defensive identity — a future variant
// added to `ExprNode` fails both this match and `fold_descends`'s until it

///|
/// picks a side.
fn rebuild_over(
  node : @ir.ExprNode,
  kids : Array[@ir.ExprNode],
) -> @ir.ExprNode {
  match node {
    @ir.ExprNode::Binary(op, _, _) => Binary(op, kids[0], kids[1])
    @ir.ExprNode::Unary(op, _) => Unary(op, kids[0])
    @ir.ExprNode::Str(op, _) => Str(op, kids[0])
    @ir.ExprNode::Cast(_, target) => Cast(kids[0], target)
    @ir.ExprNode::Alias(_, name) => Alias(kids[0], name)
    @ir.ExprNode::Ternary(_, _, _) => Ternary(kids[0], kids[1], kids[2])
    @ir.ExprNode::FillNull(_, _) => FillNull(kids[0], kids[1])
    @ir.ExprNode::FillNan(_, _) => FillNan(kids[0], kids[1])
    @ir.ExprNode::IsIn(_, members) => IsIn(kids[0], members)
    @ir.ExprNode::IsBetween(_, _, _, closed) =>
      IsBetween(kids[0], kids[1], kids[2], closed)
    @ir.ExprNode::Agg(op, _) => Agg(op, kids[0])
    @ir.ExprNode::Positional(op, _) => Positional(op, kids[0])
    // The shapes the walk never descends into and the childless leaves —
    // no folded child can sit under them, so this is a structural identity.
    // The wildcard is deliberate: the descent gate (fold_descends)
    // is where a future variant fails compilation until it picks a side; here the
    // silent default (keep the node verbatim) is the conservative one.
    _ => node
  }
}

///|
/// Fold one expression when its rewrite is available — the `Option` shape
/// keeps "unchanged" cheap for the caller (no second array built for the
/// common no-fold expression).
fn fold_one(expr : @expr.Expr) -> (@expr.Expr?, Bool) {
  let (folded, changed) = fold_expr(expr)
  if changed {
    (Some(folded), true)
  } else {
    (None, false)
  }
}

///|
/// Fold every expression in a list, rebuilding the list only when something
/// moved.
fn fold_list(exprs : Array[@expr.Expr]) -> (Array[@expr.Expr], Bool) {
  let mut changed = false
  let out : Array[@expr.Expr] = []
  for expr in exprs {
    let (folded, moved) = fold_one(expr)
    match folded {
      Some(f) => {
        out.push(f)
        changed = true
      }
      None => out.push(expr)
    }
    changed = changed || moved
  }
  if changed {
    (out, true)
  } else {
    (exprs, false)
  }
}

///|
/// The folding rule over a plan: every expression a stage carries — a
/// filter's predicate, a selection's or `with_columns` list, a sort's or
/// top-k keys, an aggregate's keys and aggregations — has its column-free
/// subtrees folded. Node order and stage shape are untouched, so the
/// push-down passes' placement decisions survive verbatim; only expression
/// content moves, under the fold-or-keep contract. Join expressions are
/// deliberately left for a later batch (the key pairs ride inside the
/// options record, and no query shape has asked yet). The walk is the
/// shared post-order rebuild — total, iterative.
fn LogicalPlan::simplify_expressions(self : LogicalPlan) -> (LogicalPlan, Bool) {
  let values : Array[LogicalPlan] = []
  let mut changed = false
  for node in self.post_order() {
    match node {
      Scan(_) => values.push(node)
      Unary(_, op) => {
        let (new_op, op_changed) = op.map_exprs(e => fold_one(e))
        changed = changed || op_changed
        values.push(Unary(pop_top(values), new_op))
      }
      Join(_, _, options) => rejoin(values, options)
      Aggregate(_, keys, exprs) => {
        let (new_keys, k_changed) = fold_list(keys)
        let (new_exprs, e_changed) = fold_list(exprs)
        changed = changed || k_changed || e_changed
        values.push(Aggregate(pop_top(values), new_keys, new_exprs))
      }
      AggregateAll(_, keys, op2) => {
        let (new_keys, k_changed) = fold_list(keys)
        changed = changed || k_changed
        values.push(AggregateAll(pop_top(values), new_keys, op2))
      }
    }
  }
  (pop_top(values), changed)
}

///|
/// Apply a rewrite to every expression a unary frame operation carries,
/// rebuilding the operation only when a rewrite came back. The foldable
/// half of the `FrameOp` vocabulary; the remaining ops carry no expressions
/// (or, for `Drop` / `Unique` / `DropNulls`, only bare column-reference
/// lists with nothing to fold) and pass through as themselves.
fn FrameOp::map_exprs(
  self : FrameOp,
  f : (@expr.Expr) -> (@expr.Expr?, Bool),
) -> (FrameOp, Bool) {
  match self {
    Select(exprs) => {
      let (out, changed) = map_expr_list(exprs, f)
      (Select(out), changed)
    }
    WithColumns(exprs) => {
      let (out, changed) = map_expr_list(exprs, f)
      (WithColumns(out), changed)
    }
    Filter(predicate) => {
      let (out, changed) = map_expr_list([predicate], f)
      (Filter(out[0]), changed)
    }
    Sort(by) => {
      let mut changed = false
      let out : Array[(@expr.Expr, Bool, Bool)] = []
      for key in by {
        let (expr, desc, nulls) = key
        let (folded, moved) = f(expr)
        match folded {
          Some(e) => {
            out.push((e, desc, nulls))
            changed = true
          }
          None => out.push(key)
        }
        changed = changed || moved
      }
      (Sort(out), changed)
    }
    TopK(n, by, nulls) => {
      let (out, changed) = map_expr_list(by, f)
      (TopK(n, out, nulls), changed)
    }
    BottomK(n, by, nulls) => {
      let (out, changed) = map_expr_list(by, f)
      (BottomK(n, out, nulls), changed)
    }
    Drop(_)
    | Rename(_)
    | RenameWith(_)
    | Reverse
    | WithRowIndex(_, _)
    | Head(_)
    | Tail(_)
    | Slice(_, _)
    | GatherEvery(_, _)
    | Unique(_, _)
    | DropNulls(_)
    | FillNull(_)
    | FillNullDir(_, _)
    | FillNan(_)
    | Pivot(_, _, _, _)
    | Unpivot(_, _, _, _)
    | Reduce(_) => (self, false)
  }
}

///|
/// Apply a rewrite to every expression in a list under a `changed` flag.
fn map_expr_list(
  exprs : Array[@expr.Expr],
  f : (@expr.Expr) -> (@expr.Expr?, Bool),
) -> (Array[@expr.Expr], Bool) {
  let mut changed = false
  let out : Array[@expr.Expr] = []
  for expr in exprs {
    let (folded, moved) = f(expr)
    match folded {
      Some(e) => {
        out.push(e)
        changed = true
      }
      None => out.push(expr)
    }
    changed = changed || moved
  }
  (out, changed)
}
