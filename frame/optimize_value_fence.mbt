// The value-fence. The pushdown passes' crossing gates are
// structural — row-stability, group-cell stability — and a structural
// argument covers only failures that raise on scope-independent facts (a
// dtype mismatch, a missing column). One dtype family's refusals do not
// fit that coverage, because its operators refuse on *values*: the
// temporal riders, whose `+` / `-` shift an instant by a span or take
// the difference of two instants, each step checked against the
// microsecond domain the rider buffers ride. A value-raising refusal
// lives on the very rows a pushdown prunes away. The error-faithfulness
// promise (a plan that fails to collect still fails after optimization)
// is what this fence keeps true for those refusals: a stage whose
// expressions combine the family's cells stays a floor, and so does a
// predicate that does.
//
// The decimal family this fence once carried is gone with the dtype it
// guarded: the IEEE decimal's arithmetic refuses on no value (an
// overflow is ±∞, a lost magnitude a signed zero, an impossible quantum
// a NaN — values, the whole point of the reshape), so there is no
// decimal refusal for a sunk predicate to swallow. The temporal family
// keeps its checked domain, and the walk below is its own.
//
// This walk is one of three spellings of "how a verb reshapes column
// names": `frame`'s verbs are the semantics, the exact-vocabulary walk
// `frame_op_names` (the one the joins read for positive attribution) is
// exact where it must be, and this walk over-approximates the same
// propagation (both its liberties are the fence-more direction). The
// Rename step runs the pairs sequentially, the over-approximating
// mirror of the exact walk's `sequential_rename` — a change to how
// `rename` spells its output reaches both walks, so the two are edited
// together.

///|
/// The value risk a plan carries. Walked over the shared post-order
/// rebuild with the pure risk steps below, total at any depth like the
/// passes it serves.
fn value_risk_in_plan(plan : LogicalPlan) -> ValueRisk {
  flat_risk(
    plan.rebuild_postorder(
      risk_of_scan,
      risk_of_unary,
      risk_of_join,
      risk_of_aggregate,
      (_, _, below) => below,
    ),
  )
}

///|
/// The per-subtree accumulator the incremental risk walk carries:
/// `stage` is the family's output names of the subtree's own top stage
/// (the value the walk's arms propagate, unchanged by the row verbs that
/// rename nothing), `union` is every stage name the whole subtree
/// contributes to the plan-wide set, and `any` is whether a
/// name-unknowable node (a pivot; a file leaf) sits anywhere in it. The
/// pair (`stage`, `union`) is what the flat `ValueRisk` folds: a
/// subtree reports `union` at its own root, and propagates `stage` to
/// its parent's arm.
priv struct RiskAcc {
  stage : @set.Set[String]
  union : @set.Set[String]
  any : Bool
}

///|
/// The walk's flat risk: the plan-wide name union and the `any` flag the
/// crossing gates consult, rather than a per-stage snapshot. A name can
/// be a family column at the scope an expression reads and a
/// same-named column of another dtype at another, and only the wider
/// reading is sound: the set and the flag over-approximate together, so
/// a fence they trigger is never narrower than the truth, and the
/// queries that pay are the ones whose columns ride in. A projection
/// output counts when its expression so much as reads one of the
/// family's names. A file source's columns are just as real — a
/// `dtypes` pin rides the text readers, a footer column the parquet
/// one — but their names are not knowable on the plan, so its arm
/// carries none and raises the flag for a source that may carry them:
/// above such a leaf every column read is a potential family member,
/// the pivot's conservatism applied to the leaf itself.
priv struct ValueRisk {
  names : @set.Set[String]
  any : Bool
}

///|
/// The gates' view of a subtree's accumulator: the union and the flag,
/// read off the accumulator a pass pops for the subtree it is about to
/// sink into (a sunk filter or window moves rows, never names, so the
/// subtree's flat risk is the sunk plan's).
fn flat_risk(acc : RiskAcc) -> ValueRisk {
  { names: acc.union, any: acc.any, }
}

///|
/// One node's step of the bottom-up risk walk, in the pure form the shared
/// rebuild and the pushdown passes' hooks read: the (already processed)
/// children's accumulators arrive as values, not stack slots, so the same
/// single-source steps serve the standalone walk and the passes' threaded
/// accumulators alike, keeping every pass Θ(N) in the plan (a stack of F
/// filters once paid one full walk each, Θ(F·N)). The row verbs and
/// `AggregateAll` are pass-throughs: the child's accumulator returns as
/// the node's own, exactly as the child's value stayed unread.
fn risk_of_scan(source : ScanSource) -> RiskAcc {
  match source {
    InMemory(df) => {
      let cols = @set.Set([])
      for f in df.schema().fields() {
        let dt = f.dtype()
        if dt is @types.DataType::Date ||
          dt is @types.DataType::Timestamp ||
          dt is @types.DataType::Duration {
          cols.add(f.name())
        }
      }
      leaf_acc(cols)
    }
    File(fs) => {
      // The file leaf's columns are real but not nameable here — the
      // probe (`may_carry_temporal`) says only whether such columns may
      // exist — so the arm carries no names and raises the flag when
      // the builder's probe does: every checked stage above such a leaf
      // fences, the same over-approximation `Pivot` makes for names
      // that come from data. The text sources raise the flag only when
      // a `dtypes` pin carries `Date` / `Timestamp`; a parquet footer
      // can name the family without the builder reading it, so that
      // source raises it unconditionally.
      let empty = @set.Set([])
      { stage: empty, union: empty, any: fs.may_carry_temporal, }
    }
  }
}

///|
/// The unary step, keyed on the operation: the projection-style verbs
/// recompute the stage set through their per-verb accumulators, and the
/// row verbs (filter / sort / window / gather / drop / fill / …) rename
/// nothing, so the child's accumulator is the node's own. For the verbs
/// that do drop or replace columns (`Drop`, `WithRowIndex`, `Reduce`)
/// keeping the old names is the over-approximating direction — a family
/// name that no longer exists can only fence more, never less.
/// Exhaustive on purpose, mirroring `frame_op_names` — the exact
/// vocabulary walk, which lists the same verbs as its own pass-through
/// set: a verb added to `FrameOp` fails this match until it declares
/// here whether the family's names ride through it, instead of falling
/// into a silent default.
fn risk_of_unary(op : FrameOp, below : RiskAcc) -> RiskAcc {
  match op {
    Select(exprs) | WithColumns(exprs) =>
      proj_acc(exprs, below, expr_touches_temporal)
    Rename(pairs) => rename_acc(below, pairs)
    // The closure is total and collect runs it on exactly these column
    // names, so running it here reads the mapping rather than guessing it.
    RenameWith(f) => rename_with_acc(below, f)
    Unpivot(_, _, _, value_name) => unpivot_acc(below, value_name)
    Pivot(_, _, _, _) => pivot_acc(below)
    Filter(_)
    | Sort(_)
    | Head(_)
    | Tail(_)
    | Slice(_, _)
    | GatherEvery(_, _)
    | TopK(_, _, _)
    | BottomK(_, _, _)
    | Drop(_)
    | Unique(_, _)
    | Reverse
    | WithRowIndex(_, _)
    | DropNulls(_)
    | FillNull(_)
    | FillNullDir(_, _)
    | FillNan(_)
    | Reduce(_) => below
  }
}

///|
/// The aggregate step: a key's or cell's output name counts when its
/// expression so much as reads one of the family's names the subtree
/// carries (or the subtree raised the `any` flag).
fn risk_of_aggregate(
  keys : Array[@expr.Expr],
  exprs : Array[@expr.Expr],
  below : RiskAcc,
) -> RiskAcc {
  agg_acc(keys, exprs, below, expr_touches_temporal)
}

///|
/// The join step. A right join leads with the right frame's columns and
/// suffixes a clashing *left* one — the swapped-left-join spelling — so
/// the suffixed offering switches sides with `how`; the unsuffixed pair
/// carries every non-clashing name either way. A whole-frame aggregation
/// (`AggregateAll`) reuses its input column names, so its step is the
/// pass-through the shared rebuild's last hook spells inline.
fn risk_of_join(
  options : JoinOptions,
  left : RiskAcc,
  right : RiskAcc,
) -> RiskAcc {
  let suffixed = if options.how is Right { left } else { right }
  join_acc(left, right, suffixed, options.suffix)
}

///|
/// A leaf's accumulator: its own columns are its stage and its whole
/// union.
fn leaf_acc(cols : @set.Set[String]) -> RiskAcc {
  { stage: cols, union: cols, any: false, }
}

///|
/// The accumulator through a projection-style stage (`Select` /
/// `WithColumns`): an expression's output counts when it so much as
/// reads one of the family's names the stage below carries (or the
/// below stages raised the `any` flag), and a carried name that no
/// expression redefines survives verbatim.
fn proj_acc(
  exprs : Array[@expr.Expr],
  below : RiskAcc,
  touches : (@ir.ExprNode, @set.Set[String]) -> Bool,
) -> RiskAcc {
  let cols = @set.Set([])
  let defined = @set.Set([])
  for e in exprs {
    defined.add(e.output_name())
    if below.any || touches(e.node(), below.stage) {
      cols.add(e.output_name())
    }
  }
  below.stage.each(name => if !defined.contains(name) { cols.add(name) })
  { stage: cols, union: union_sets(below.union, cols), any: below.any, }
}

///|
/// The accumulator through a `Rename`: the pairs replayed sequentially
/// over the family's subset of the stage names — the exact verb's
/// semantics, the over-approximating mirror of the name walk's
/// `sequential_rename`. A pair whose source is absent is a no-op (its
/// source is merely outside the family — or the verb raises and the
/// plan fails at collect, where fencing is moot), and the subset never
/// infers the verb's collisions, which live against names of other
/// dtypes it cannot see. Both liberties are the over-approximating
/// direction: a family name stays in the risk set unless a pair
/// provably moved it.
fn rename_acc(below : RiskAcc, pairs : Array[(String, String)]) -> RiskAcc {
  let renamed = @set.Set([])
  for name in below.stage {
    renamed.add(name)
  }
  // Indexed access rather than a tuple pattern: the coverage reporter's
  // parser cannot parse a tuple pattern in a `for` header, and a source it
  // cannot parse fails the coverage gate.
  for pair in pairs {
    let old_name = pair.0
    let new_name = pair.1
    if renamed.contains(old_name) {
      renamed.remove(old_name)
      renamed.add(new_name)
    }
  }
  { stage: renamed, union: union_sets(below.union, renamed), any: below.any, }
}

///|
/// The accumulator through a `RenameWith`: the total closure runs on the
/// family's subset of the stage names — the same calls collect makes, so
/// this is evaluation, not inspection.
fn rename_with_acc(below : RiskAcc, f : (String) -> String) -> RiskAcc {
  let renamed = @set.Set([])
  for name in below.stage {
    renamed.add(f(name))
  }
  { stage: renamed, union: union_sets(below.union, renamed), any: below.any, }
}

///|
/// The accumulator through an `Unpivot`: the folded value columns land
/// in one `value_name` column; the index side keeps its names, so the
/// child's stage rides along beside it.
fn unpivot_acc(below : RiskAcc, value_name : String) -> RiskAcc {
  let cols = @set.Set([])
  for name in below.stage {
    cols.add(name)
  }
  cols.add(value_name)
  { stage: cols, union: union_sets(below.union, cols), any: below.any, }
}

///|
/// The accumulator through a `Pivot`: the output column names come from
/// the data it reshapes, so no name above it is provably outside the
/// family — the flag fences every checked stage there.
fn pivot_acc(below : RiskAcc) -> RiskAcc {
  {
    stage: below.stage,
    union: union_sets(below.union, below.stage),
    any: true,
  }
}

///|
/// The accumulator through an `Aggregate`: a key's or cell's output
/// name counts when its expression so much as reads one of the family's
/// names the subtree carries (or the subtree raised the `any` flag).
fn agg_acc(
  keys : Array[@expr.Expr],
  exprs : Array[@expr.Expr],
  below : RiskAcc,
  touches : (@ir.ExprNode, @set.Set[String]) -> Bool,
) -> RiskAcc {
  let cols = @set.Set([])
  for e in keys {
    if below.any || touches(e.node(), below.stage) {
      cols.add(e.output_name())
    }
  }
  for e in exprs {
    if below.any || touches(e.node(), below.stage) {
      cols.add(e.output_name())
    }
  }
  { stage: cols, union: union_sets(below.union, cols), any: below.any, }
}

///|
/// The accumulator through a `Join`: the stages merge, the clashing
/// side's names are also offered under their suffixed spelling, and
/// both unions fold in — conservatively mirroring `frame`'s clash rule
/// (only a clashing column gains the suffix at collect; adding it for
/// all of them fences more, never less).
fn join_acc(
  left : RiskAcc,
  right : RiskAcc,
  suffixed : RiskAcc,
  suffix : String,
) -> RiskAcc {
  let merged = @set.Set([])
  left.stage.each(name => merged.add(name))
  right.stage.each(name => merged.add(name))
  suffixed.stage.each(name => merged.add(name + suffix))
  let union = @set.Set([])
  left.union.each(name => union.add(name))
  right.union.each(name => union.add(name))
  merged.each(name => union.add(name))
  { stage: merged, union, any: left.any || right.any, }
}

///|
/// Fold one stage's contribution into a subtree's union: the child's
/// union plus this stage's own names (a fresh set — the child's
/// accumulators are consumed, never shared, so a caller cannot mutate
/// them through the result).
fn union_sets(
  below_union : @set.Set[String],
  stage : @set.Set[String],
) -> @set.Set[String] {
  let union = @set.Set([])
  below_union.each(name => union.add(name))
  stage.each(name => union.add(name))
  union
}

///|
/// Whether any node of the expression reads a column from `risk` or is
/// a `Date` / `Timestamp` / `Duration` literal — the family's touch
/// test. Iterative over an explicit stack, so expression depths the
/// engine pins walk without recursing. Exhaustive over the variant set
/// on purpose: the descent is the "touches nothing temporal" verdict,
/// and a variant added to `ExprNode` fails this match until it declares
/// its children here rather than silently inheriting it. The operator
/// tags carry no decision of their own — every member of `Unary` /
/// `Str` / … reads the same operand — so the descent rides
/// `each_child` for all of them, the arm list staying the exhaustive
/// half.
fn expr_touches_temporal(expr : @ir.ExprNode, risk : @set.Set[String]) -> Bool {
  expr_touches_family(expr, risk, v => {
    v is @types.Scalar::Date(_) ||
    v is @types.Scalar::Timestamp(_) ||
    v is @types.Scalar::Duration(_)
  })
}

///|
/// The shared descent behind the touch test: the same walk, the same
/// exhaustiveness, the literal membership the closure. The other
/// literals and a literal series are leaves that name no column —
/// `each_child` walks nothing under them.
fn expr_touches_family(
  expr : @ir.ExprNode,
  risk : @set.Set[String],
  lit : (@types.Scalar) -> Bool,
) -> Bool {
  let stack : Array[@ir.ExprNode] = [expr]
  while stack.length() > 0 {
    let node = pop_top(stack)
    match node {
      @ir.ExprNode::Col(name) => if risk.contains(name) { return true }
      @ir.ExprNode::Lit(value) => if lit(value) { return true }
      // A literal series is a leaf that names no column.
      @ir.ExprNode::LitSeries(_) => ()
      // The descent rides `each_child` — the one spelling of the tree's
      // shape — while the arm list stays exhaustive: a variant added to
      // `ExprNode` fails this match until it declares whether the family
      // touches it, rather than silently inheriting the descent. An
      // `IsIn`'s members are values, not sub-nodes (`each_child` walks
      // the operand alone).
      @ir.ExprNode::Binary(_, _, _)
      | @ir.ExprNode::Unary(_, _)
      | @ir.ExprNode::Agg(_, _)
      | @ir.ExprNode::Str(_, _)
      | @ir.ExprNode::Positional(_, _)
      | @ir.ExprNode::Cast(_, _)
      | @ir.ExprNode::Alias(_, _)
      | @ir.ExprNode::Diff(_, _)
      | @ir.ExprNode::Ternary(_, _, _)
      | @ir.ExprNode::FillNull(_, _)
      | @ir.ExprNode::FillNan(_, _)
      | @ir.ExprNode::Clip(_, _, _)
      | @ir.ExprNode::IsIn(_, _)
      | @ir.ExprNode::IsBetween(_, _, _, _)
      | @ir.ExprNode::Map(_, _, _)
      | @ir.ExprNode::MapBatches(_, _, _, _)
      | @ir.ExprNode::Over(_, _) => node.each_child(k => stack.push(k))
    }
  }
  false
}

///|
/// The checked-shape walk: whether any node of the expression is an
/// `Add` or `Sub` — the shapes whose temporal operands carry the
/// checked refusals (the instant shift `Timestamp / Date ± Duration`
/// and the instant difference `Timestamp − Timestamp` / `Date − Date`,
/// each refusing when the result leaves the microsecond domain). The
/// shape test alone fences nothing: an `Int` add wraps and a `Float`
/// one absorbs, which is why the risk set decides alongside it.
/// Exhaustive over the variant set on purpose — the descent is the "no
/// checked refusal" verdict, and a variant added to `ExprNode` fails
/// this match until it declares its place here rather than silently
/// inheriting that verdict. Every other binary member is enumerated to
/// descend: the other arithmetics refuse a temporal operand on the
/// dtype alone (the kernel's temporal table names only the two pairs
/// above, everything else declines to the numeric path), the logical
/// pair carries no values of its own, and the comparisons order
/// temporals without refusing on them; a future binary with temporal
/// semantics of its own fails this match.
fn expr_has_temporal_checked_op(expr : @ir.ExprNode) -> Bool {
  let stack : Array[@ir.ExprNode] = [expr]
  while stack.length() > 0 {
    let node = pop_top(stack)
    match node {
      @ir.ExprNode::Binary(@ir.BinOp::Add, _, _)
      | @ir.ExprNode::Binary(@ir.BinOp::Sub, _, _) => return true
      @ir.ExprNode::Binary(
        @ir.BinOp::Mul
        | @ir.BinOp::Div
        | @ir.BinOp::FloorDiv
        | @ir.BinOp::Mod
        | @ir.BinOp::Pow
        | @ir.BinOp::Eq
        | @ir.BinOp::Ne
        | @ir.BinOp::Lt
        | @ir.BinOp::Le
        | @ir.BinOp::Gt
        | @ir.BinOp::Ge
        | @ir.BinOp::And
        | @ir.BinOp::Or
        | @ir.BinOp::Atan2
        | @ir.BinOp::Hypot,
        _,
        _
      ) => node.each_child(k => stack.push(k))
      // The leaves carry no operand to check.
      @ir.ExprNode::Col(_)
      | @ir.ExprNode::Lit(_)
      | @ir.ExprNode::LitSeries(_) => ()
      // The descent rides `each_child`, the arm list staying the
      // exhaustive half (a variant added to `ExprNode` declares its place
      // among the decisions above or here).
      @ir.ExprNode::Unary(_, _)
      | @ir.ExprNode::Agg(_, _)
      | @ir.ExprNode::Str(_, _)
      | @ir.ExprNode::Positional(_, _)
      | @ir.ExprNode::Cast(_, _)
      | @ir.ExprNode::Alias(_, _)
      | @ir.ExprNode::Ternary(_, _, _)
      | @ir.ExprNode::FillNull(_, _)
      | @ir.ExprNode::FillNan(_, _)
      | @ir.ExprNode::Diff(_, _)
      | @ir.ExprNode::Clip(_, _, _)
      | @ir.ExprNode::IsIn(_, _)
      | @ir.ExprNode::IsBetween(_, _, _, _)
      | @ir.ExprNode::Map(_, _, _)
      | @ir.ExprNode::MapBatches(_, _, _, _)
      | @ir.ExprNode::Over(_, _) => node.each_child(k => stack.push(k))
    }
  }
  false
}

///|
/// Whether evaluating the expression can refuse on a *value* — the
/// temporal family's checked refusals — in the scope it runs in: the
/// tree shifts or differences temporal cells. The `any` flag makes
/// every column read a potential member of the family.
fn value_raises_on_values(expr : @ir.ExprNode, risk : ValueRisk) -> Bool {
  (risk.any || expr_touches_temporal(expr, risk.names)) &&
  expr_has_temporal_checked_op(expr)
}

///|
/// The crossing-point form: whether any of a stage's expressions
/// carries the family's checked refusals. A stage that passes stays
/// crossable by every structural gate as before; one that fails is a
/// floor.
fn stage_value_raises(exprs : Array[@expr.Expr], risk : ValueRisk) -> Bool {
  exprs.any(e => value_raises_on_values(e.node(), risk))
}
