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
/// left untouched as whole units. The walk rides the shared gated
/// post-order fold — `fold_descends` is the opacity gate, iterative and
/// total at any depth.
fn fold_expr(expr : @expr.Expr) -> (@expr.Expr, Bool) {
  let top = expr
    .node()
    .fold_postorder_opaque(
      fold_descends,
      // An excluded unit, or a bare column: kept verbatim, never literal.
      node => { node, lit: node is @ir.ExprNode::Lit(_), changed: false, },
      (node, kids) => fold_node(node, kids),
    )
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
    | @ir.ExprNode::Diff(_, _)
    | @ir.ExprNode::Clip(_, _, _)
    | @ir.ExprNode::IsIn(_, _)
    | @ir.ExprNode::IsBetween(_, _, _, _)
    | @ir.ExprNode::Agg(_, _)
    | @ir.ExprNode::Positional(_, _) => true
    // A window is a closed unit like a closure carrier: folding inside it
    // would rewrite a per-group subtree against the whole frame's
    // literals, a different question than the one its cells answer.
    @ir.ExprNode::Over(_, _) => false
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
  // The node rebuilt over folded children, when any child moved — the
  // shared shape rebuild, exhaustive over the variant set in the AST
  // package (`rebuild_children`); the shapes the walk never descends into
  // never reach it, their subtrees having moved nothing.
  let rebuilt : @ir.ExprNode = if below_changed {
    let new_kids = kids.map(k => k.node)
    node.rebuild_children(new_kids)
  } else {
    node
  }
  // `Alias` is a naming boundary: the alias is the column's output name, so
  // folding the node away would rename it (a `1 as one` that folds to a bare
  // literal changes the collected schema). Its children fold; the node
  // itself stays. An `Agg` reduces a whole scope, a `Positional` reads the
  // broadcast height, and a `Diff` reads its neighbour rows — none may
  // consult the empty frame the fold uses — and a bare `Lit` is already a
  // literal (folding it again would report a change that moved nothing).
  if all_lit &&
    !(node is @ir.ExprNode::Alias(_, _) ||
    node is @ir.ExprNode::Agg(_, _) ||
    node is @ir.ExprNode::Positional(_, _) ||
    node is @ir.ExprNode::Diff(_, _) ||
    node is @ir.ExprNode::Lit(_)) {
    match evaluate_column_free(@expr.Expr::of_node(rebuilt)) {
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
  self.rebuild_postorder(
    source => (Scan(source), false),
    (op, child) => {
      let (input, input_changed) = child
      let (new_op, op_changed) = op.map_exprs(e => fold_one(e))
      (Unary(input, new_op), input_changed || op_changed)
    },
    (options, left, right) => {
      let (l, l_changed) = left
      let (r, r_changed) = right
      (Join(l, r, options), l_changed || r_changed)
    },
    (keys, exprs, below) => {
      let (input, input_changed) = below
      let (new_keys, k_changed) = fold_list(keys)
      let (new_exprs, e_changed) = fold_list(exprs)
      (
        Aggregate(input, new_keys, new_exprs),
        input_changed || k_changed || e_changed,
      )
    },
    (keys, op2, below) => {
      let (input, input_changed) = below
      let (new_keys, k_changed) = fold_list(keys)
      (AggregateAll(input, new_keys, op2), input_changed || k_changed)
    },
  )
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
