// The `cluster_with_columns` rule — merging adjacent `WithColumns` stages
// into one — and the constant-folding rule over an expression tree. Both are
// *local* rewrites: unlike the three push-down passes, which re-order whole
// nodes and run once each in a fixed sequence, these reshape a node or its
// expressions in place, and the optimizer applies each exactly once, in one
// sweep with no fixed-point loop — why a single application reaches the
// joint fixed point (each rule is a fixed point of itself, and neither can
// enable the other) is argued once beside the sweep that runs them
// (`optimize_with`). They run after the push-down passes by design: the
// passes have already placed the nodes where clustering can see adjacency,
// and folding after projection pushdown means a folded-away column
// reference never widens a scan.

///|
/// The clustering rule: merge `Unary(Unary(inner, WithColumns(a)),
/// WithColumns(b))` into `Unary(inner, WithColumns(a ++ b))` when the merge
/// is transparent. Within one `with_columns` stage every expression is
/// evaluated against the stage's *input* — the eager verb's semantics — so
/// the outer stage's expressions must not read any name the inner stage
/// defines: below the merge point that name either does not exist or holds
/// the pre-overwrite values, so a reader would see different values (or a
/// different error) than the as-built stages give it. The outer stage also
/// must not *define* a name the inner one defines: that merge is in fact
/// equivalent (both definitions evaluate against the same input and the
/// later list entry wins the slot either way), but keeping the rule to
/// disjoint definitions keeps the argument one line — loosening it wants the
/// replacement-position reasoning written out and no pipeline has asked.
/// Evaluation order is the list order before and after, so a failing plan
/// reports the same error from the same expression. The walk is the shared
/// post-order rebuild — total, iterative, never-abort.
fn LogicalPlan::cluster_with_columns(self : LogicalPlan) -> (LogicalPlan, Bool) {
  self.rebuild_postorder(
    source => (Scan(source), false),
    (op, child) => {
      let (input, input_changed) = child
      // The merge shape: this stage defines columns over a child stage
      // that also defines columns, and the outer reads none of the inner's
      // definitions under disjoint outputs.
      match (op, input) {
        (WithColumns(outer), Unary(inner_plan, WithColumns(inner_exprs))) if outer_reads_none_of_inner(
            outer, inner_exprs,
          ) &&
          definitions_disjoint(outer, inner_exprs) => {
          // `inner ++ outer`: the inner stage's expressions first, the
          // outer's after — exactly the evaluation order of the two
          // stages.
          let merged = inner_exprs.copy()
          for expr in outer {
            merged.push(expr)
          }
          (Unary(inner_plan, WithColumns(merged)), true)
        }
        _ => (Unary(input, op), input_changed)
      }
    },
    (options, left, right) => {
      let (l, l_changed) = left
      let (r, r_changed) = right
      (Join(l, r, options), l_changed || r_changed)
    },
    (keys, exprs, below) => {
      let (input, input_changed) = below
      (Aggregate(input, keys, exprs), input_changed)
    },
    (keys, op2, below) => {
      let (input, input_changed) = below
      (AggregateAll(input, keys, op2), input_changed)
    },
  )
}

///|
/// Whether every expression in `outer` reads none of the names `inner`
/// defines — the transparency condition stated on the clustering rule.
fn outer_reads_none_of_inner(
  outer : Array[@expr.Expr],
  inner : Array[@expr.Expr],
) -> Bool {
  for expr in outer {
    for name in expr.referenced_columns() {
      for defined in inner {
        if defined.output_name() == name {
          return false
        }
      }
    }
  }
  true
}

///|
/// Whether the two stages define pairwise-disjoint output names — the
/// conservative half of the clustering rule (see its docstring for why even
/// this is stronger than strict equivalence needs).
fn definitions_disjoint(
  outer : Array[@expr.Expr],
  inner : Array[@expr.Expr],
) -> Bool {
  for a in outer {
    for b in inner {
      if a.output_name() == b.output_name() {
        return false
      }
    }
  }
  true
}
