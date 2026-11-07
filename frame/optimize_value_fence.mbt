// The value-fence. The pushdown passes' crossing gates are
// structural — row-stability, group-cell stability — and a structural
// argument covers only failures that raise on scope-independent facts (a
// dtype mismatch, a missing column). Two dtype families' refusals do not
// fit that coverage, each because an operator refuses on *values*:
// `Decimal`, whose arithmetic aligns scales with checked multiplies, whose
// cross-scale comparison lifts buffers the same way, whose `sum` folds
// with a checked add, and whose `neg` / `abs` / `round` widen or negate
// past the 18-digit envelope — and the temporal riders, whose `+` / `-`
// shift an instant by a span or take the difference of two instants, each
// step checked against the microsecond domain the rider buffers ride. A
// value-raising refusal lives on the very rows a pushdown prunes away. The
// error-faithfulness promise (a plan that fails to collect still fails
// after optimization) is what this fence keeps true for those refusals: a
// stage whose expressions combine either family's cells stays a floor,
// and so does a predicate that does.
//
// Both families share one name-propagation walk. The verbs that rename or
// reshape columns (`rename` / `rename_with` / `unpivot` / `join` / `pivot`)
// treat a dtype family's names identically, so the walk computes the two
// risk sets together, one accumulator per family — the same fusion as the
// predicate rules' three properties in one walk. The families differ only
// at the two ends: which dtypes a leaf's columns carry into their set, and
// which expression shapes carry the checked refusals
// (`expr_has_decimal_checked_op` / `expr_has_temporal_checked_op`).
//
// This walk is one of three spellings of "how a verb reshapes column
// names": `frame`'s verbs are the semantics, the exact-vocabulary walk
// `frame_op_names` (the one the joins read for positive attribution) is
// exact where it must be, and this walk over-approximates the same
// propagation (both its liberties are the fence-more direction). The
// Rename step runs the pairs sequentially over each family's subset, the
// over-approximating mirror of the exact walk's `sequential_rename` — a
// change to how `rename` spells its output reaches both walks, so the
// two are edited together.

///|
/// The value risk a plan carries, one accumulator per dtype family.
/// Walked over the shared post-order rebuild with the pure risk steps
/// below, total at any depth like the passes it serves.
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
/// One family's per-subtree accumulator the incremental risk walk carries:
/// `stage` is the family's output names of the subtree's own top stage (the
/// value the walk's arms propagate, unchanged by the row verbs that rename
/// nothing), `union` is every stage name the whole subtree contributes to
/// the plan-wide set, and `any` is whether a name-unknowable node (a
/// pivot; a file leaf) sits anywhere in it. The pair (`stage`, `union`) is
/// what the flat `FamilyRisk` folds: a subtree reports `union` at its own
/// root, and propagates `stage` to its parent's arm.
priv struct RiskAcc {
  stage : @set.Set[String]
  union : @set.Set[String]
  any : Bool
}

///|
/// The per-subtree accumulator both families carry together — one `RiskAcc`
/// apiece, propagated by the same arms, so a pass that steps the walk pays
/// it once for both.
priv struct PlanRisk {
  decimal : RiskAcc
  temporal : RiskAcc
}

///|
/// One family's flat risk: the plan-wide name union and the `any` flag the
/// crossing gates consult, rather than a per-stage snapshot. A name can be
/// a family's column at the scope an expression reads and a same-named
/// column of another dtype at another, and only the wider reading is
/// sound: the set and the flag over-approximate together, so a fence they
/// trigger is never narrower than the truth, and the queries that pay are
/// the ones whose columns ride in. A projection output counts for a family
/// when its expression so much as reads one of the family's names (or sums
/// — the `sum` of a decimal column is decimal whatever wraps it). A file
/// source's columns are just as real — a `dtypes` pin rides the text
/// readers, a footer column the parquet one — but their names are not
/// knowable on the plan, so its arms carry none and raise the flag for a
/// source that may carry them (the decimal flag only under its builder's
/// probe, `may_carry_decimal`; the temporal flag for every file source,
/// since a pin or a parquet footer can make any column temporal and the
/// plan cannot see which): above such a leaf every column read is a
/// potential family member, the pivot's conservatism applied to the leaf
/// itself.
priv struct FamilyRisk {
  names : @set.Set[String]
  any : Bool
}

///|
/// The value fence's risk bundle the crossing gates consult — one flat
/// risk per family, from one walk.
priv struct ValueRisk {
  decimal : FamilyRisk
  temporal : FamilyRisk
}

///|
/// The gates' view of a subtree's accumulators: both families' unions and
/// flags, read off the accumulator a pass pops for the subtree it is about
/// to sink into (a sunk filter or window moves rows, never names, so the
/// subtree's flat risk is the sunk plan's).
fn flat_risk(acc : PlanRisk) -> ValueRisk {
  {
    decimal: { names: acc.decimal.union, any: acc.decimal.any, },
    temporal: { names: acc.temporal.union, any: acc.temporal.any, },
  }
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
fn risk_of_scan(source : ScanSource) -> PlanRisk {
  match source {
    InMemory(df) => {
      let decimal = @set.Set([])
      let temporal = @set.Set([])
      for f in df.schema().fields() {
        let dt = f.dtype()
        if dt is @types.DataType::Decimal(_) {
          decimal.add(f.name())
        }
        if dt is @types.DataType::Date ||
          dt is @types.DataType::Timestamp ||
          dt is @types.DataType::Duration {
          temporal.add(f.name())
        }
      }
      { decimal: leaf_acc(decimal), temporal: leaf_acc(temporal), }
    }
    File(fs) => {
      // The file leaf's columns are real but not nameable here — the
      // probes (`may_carry_decimal` / `may_carry_temporal`) say only
      // whether such columns may exist — so both arms carry no names and
      // raise their family's flag when the builder's probe does: every
      // checked stage above such a leaf fences, the same
      // over-approximation `Pivot` makes for names that come from data.
      // The text sources raise a temporal flag only when a `dtypes` pin
      // carries `Date` / `Timestamp`; a parquet footer can name either
      // family without the builder reading it, so that source raises
      // both.
      let empty = @set.Set([])
      {
        decimal: { stage: empty, union: empty, any: fs.may_carry_decimal, },
        temporal: { stage: empty, union: empty, any: fs.may_carry_temporal, },
      }
    }
  }
}

///|
/// The unary step, keyed on the operation: the projection-style verbs
/// recompute both families' stage sets through their per-verb accumulators,
/// and the row verbs (filter / sort / window / gather / drop / fill / …)
/// rename nothing, so the child's accumulator is the node's own. For the
/// verbs that do drop or replace columns (`Drop`, `WithRowIndex`,
/// `Reduce`) keeping the old names is the over-approximating direction —
/// a family name that no longer exists can only fence more, never less.
/// Exhaustive on purpose, mirroring `frame_op_names` — the exact
/// vocabulary walk, which lists the same verbs as its own pass-through
/// set: a verb added to `FrameOp` fails this match until it declares here
/// whether either family's names ride through it, instead of falling into
/// a silent default.
fn risk_of_unary(op : FrameOp, below : PlanRisk) -> PlanRisk {
  match op {
    Select(exprs) | WithColumns(exprs) =>
      {
        decimal: proj_acc(exprs, below.decimal, expr_touches_decimal),
        temporal: proj_acc(exprs, below.temporal, expr_touches_temporal),
      }
    Rename(pairs) =>
      {
        decimal: rename_acc(below.decimal, pairs),
        temporal: rename_acc(below.temporal, pairs),
      }
    // The closure is total and collect runs it on exactly these column
    // names, so running it here reads the mapping rather than guessing it.
    RenameWith(f) =>
      {
        decimal: rename_with_acc(below.decimal, f),
        temporal: rename_with_acc(below.temporal, f),
      }
    Unpivot(_, _, _, value_name) =>
      {
        decimal: unpivot_acc(below.decimal, value_name),
        temporal: unpivot_acc(below.temporal, value_name),
      }
    Pivot(_, _, _, _) =>
      {
        decimal: pivot_acc(below.decimal),
        temporal: pivot_acc(below.temporal),
      }
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
/// carries (or the subtree raised the family's `any`).
fn risk_of_aggregate(
  keys : Array[@expr.Expr],
  exprs : Array[@expr.Expr],
  below : PlanRisk,
) -> PlanRisk {
  {
    decimal: agg_acc(keys, exprs, below.decimal, expr_touches_decimal),
    temporal: agg_acc(keys, exprs, below.temporal, expr_touches_temporal),
  }
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
  left : PlanRisk,
  right : PlanRisk,
) -> PlanRisk {
  let suffixed_is_left = options.how is Right
  {
    decimal: join_acc(
      left.decimal,
      right.decimal,
      if suffixed_is_left {
        left.decimal
      } else {
        right.decimal
      },
      options.suffix,
    ),
    temporal: join_acc(
      left.temporal,
      right.temporal,
      if suffixed_is_left {
        left.temporal
      } else {
        right.temporal
      },
      options.suffix,
    ),
  }
}

///|
/// A leaf's accumulator: its own columns are its stage and its whole
/// union.
fn leaf_acc(cols : @set.Set[String]) -> RiskAcc {
  { stage: cols, union: cols, any: false, }
}

///|
/// One family's accumulator through a projection-style stage (`Select` /
/// `WithColumns`): an expression's output counts when it so much as reads
/// one of the family's names the stage below carries (or the below stages
/// raised the family's `any`), and a carried name that no expression
/// redefines survives verbatim. The touch test arrives as a function
/// because the two families differ in which literals count.
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
/// One family's accumulator through a `Rename`: the pairs replayed
/// sequentially over the family's subset of the stage names — the exact
/// verb's semantics, the over-approximating mirror of the name walk's
/// `sequential_rename`. A pair whose source is absent is a no-op (its
/// source is merely outside the family — or the verb raises and the plan
/// fails at collect, where fencing is moot), and the subset never infers
/// the verb's collisions, which live against names of other families it
/// cannot see. Both liberties are the over-approximating direction: a
/// family name stays in its risk set unless a pair provably moved it.
fn rename_acc(below : RiskAcc, pairs : Array[(String, String)]) -> RiskAcc {
  let renamed = @set.Set([])
  below.stage.each(name => renamed.add(name))
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
/// One family's accumulator through a `RenameWith`: the total closure runs
/// on the family's subset of the stage names — the same calls collect
/// makes, so this is evaluation, not inspection.
fn rename_with_acc(below : RiskAcc, f : (String) -> String) -> RiskAcc {
  let renamed = @set.Set([])
  below.stage.each(name => renamed.add(f(name)))
  { stage: renamed, union: union_sets(below.union, renamed), any: below.any, }
}

///|
/// One family's accumulator through an `Unpivot`: the folded value columns
/// land in one `value_name` column; the index side keeps its names, so the
/// child's stage rides along beside it.
fn unpivot_acc(below : RiskAcc, value_name : String) -> RiskAcc {
  let cols = @set.Set([])
  below.stage.each(name => cols.add(name))
  cols.add(value_name)
  { stage: cols, union: union_sets(below.union, cols), any: below.any, }
}

///|
/// One family's accumulator through a `Pivot`: the output column names
/// come from the data it reshapes, so no name above it is provably outside
/// the family — the flag fences every checked stage there.
fn pivot_acc(below : RiskAcc) -> RiskAcc {
  {
    stage: below.stage,
    union: union_sets(below.union, below.stage),
    any: true,
  }
}

///|
/// One family's accumulator through an `Aggregate`: a key's or cell's
/// output name counts when its expression so much as reads one of the
/// family's names the subtree carries (or the subtree raised the family's
/// `any`).
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
/// One family's accumulator through a `Join`: the stages merge, the
/// clashing side's names are also offered under their suffixed spelling,
/// and both unions fold in — conservatively mirroring `frame`'s clash rule
/// (only a clashing column gains the suffix at collect; adding it for all
/// of them fences more, never less).
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
/// Fold one stage's contribution into a subtree's union: the child's union
/// plus this stage's own names (a fresh set — the child's accumulators are
/// consumed, never shared, so a caller cannot mutate them through the
/// result).
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
/// Whether any node of the expression reads a column from `risk` or is a
/// decimal literal. Iterative over an explicit stack, so expression depths
/// the engine pins walk without recursing. Exhaustive over the variant set
/// on purpose: the descent is the "touches nothing decimal" verdict, and a
/// variant added to `ExprNode` fails this match until it declares its
/// children here rather than silently inheriting it. The operator tags
/// carry no decision of their own — every member of `Unary` / `Str` / …
/// reads the same operand — so the descent rides `each_child` for all of
/// them, the arm list staying the exhaustive half.
fn expr_touches_decimal(expr : @ir.ExprNode, risk : @set.Set[String]) -> Bool {
  expr_touches_family(expr, risk, v => v is @types.Scalar::Decimal(_, _))
}

///|
/// The temporal twin of `expr_touches_decimal`: a column from `risk` or a
/// `Date` / `Timestamp` / `Duration` literal.
fn expr_touches_temporal(expr : @ir.ExprNode, risk : @set.Set[String]) -> Bool {
  expr_touches_family(expr, risk, v => {
    v is @types.Scalar::Date(_) ||
    v is @types.Scalar::Timestamp(_) ||
    v is @types.Scalar::Duration(_)
  })
}

///|
/// The shared descent behind both families' touch tests: same walk, same
/// exhaustiveness, only the literal membership differing (the closure).
/// The other literals and a literal series are leaves that name no column
/// — `each_child` walks nothing under them.
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
      // `IsIn`'s members are values, not sub-nodes (`each_child` walks the
      // operand alone), and a decimal *member* is a comparison operand the
      // checked-op walk classifies, not a decimal column read.
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
/// Whether any node of the expression is an arithmetic / comparison
/// binary, one of the comparison sugar nodes, the checked unary triple, or
/// a `Sum` aggregation — the shapes whose decimal operands carry the
/// checked refusals. The shape test alone fences nothing: an `Int` sum
/// wraps and a `Float` one absorbs, which is why the risk set decides
/// alongside it. Exhaustive over the variant set on purpose — the descent
/// is the "no checked refusal" verdict, and a variant added to `ExprNode`
/// fails this match until it declares its place here rather than silently
/// inheriting that verdict. Where a whole namespace's members share one
/// verdict the tag is matched once for all of them: every non-checked
/// unary descends (its refusals are dtype facts, scope-independent), every
/// reduction but `sum` descends (the decimal `sum` alone folds with a
/// checked add — `mean` refuses the dtype at factory time), and the string
/// namespace is dtype-gated throughout. A member that splits one of these
/// verdicts is a compile error in the fused analysis (`classify`
/// enumerates them), whose unary comment names this walk as the fence's
/// carrier.
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
          | @ir.BinOp::Hypot => node.each_child(k => stack.push(k))
        }
      // `is_between` and `is_in` are the comparison sugar: they descend into
      // the same `eval_compare` rescale a `Ge` / `Eq` takes, so a decimal
      // operand can refuse on values through them exactly as through the
      // binary spellings.
      @ir.ExprNode::IsBetween(_, _, _, _) => return true
      @ir.ExprNode::IsIn(_, _) => return true
      // `clip` runs the same rescale on its bounds selection that a
      // `Lt` / `Gt` takes, so a cross-scale decimal operand can refuse on
      // values through it exactly as through the binary spellings.
      @ir.ExprNode::Clip(_, _, _) => return true
      // The checked unary triple: `neg` / `abs` refuse on an 18-digit
      // magnitude the way the arithmetics refuse on their overflow, and
      // `round`'s widening rescale is the same checked multiply — the
      // descent must not read through them as value-safe.
      @ir.ExprNode::Unary(@ir.UnOp::Neg, _) => return true
      @ir.ExprNode::Unary(@ir.UnOp::Abs, _) => return true
      @ir.ExprNode::Unary(@ir.UnOp::Round(_), _) => return true
      @ir.ExprNode::Agg(@series.ReduceOp::Sum, _) => return true
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
      | @ir.ExprNode::Map(_, _, _)
      | @ir.ExprNode::MapBatches(_, _, _, _)
      | @ir.ExprNode::Over(_, _) => node.each_child(k => stack.push(k))
    }
  }
  false
}

///|
/// The temporal family's own checked-shape walk: whether any node of the
/// expression is an `Add` or `Sub` — the shapes whose temporal operands
/// carry the checked refusals (the instant shift `Timestamp / Date ±
/// Duration` and the instant difference `Timestamp − Timestamp` /
/// `Date − Date`, each refusing when the result leaves the microsecond
/// domain). The shape test alone fences nothing: an `Int` add wraps and a
/// `Float` one absorbs, which is why the risk set decides alongside it.
/// Exhaustive over the variant set on purpose — the descent is the "no
/// checked refusal" verdict, and a variant added to `ExprNode` fails this
/// match until it declares its place here rather than silently inheriting
/// that verdict. Every other binary member is enumerated to descend: the
/// other arithmetics refuse a temporal operand on the dtype alone (the
/// kernel's temporal table names only the two pairs above, everything
/// else declines to the numeric path) or refuse on decimal values — the
/// decimal family's own walk — the logical pair carries no values of its
/// own, and the comparisons order temporals without refusing on them; a
/// future binary with temporal semantics of its own fails this match.
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
/// Whether evaluating the expression can refuse on a *value* — one of the
/// two families' checked refusals — in the scope it runs in: the tree
/// combines decimal cells arithmetically, orders them, or sums them, or it
/// shifts / differences temporal cells. A family's `any` flag makes every
/// column read a potential member of that family.
fn value_raises_on_values(expr : @ir.ExprNode, risk : ValueRisk) -> Bool {
  value_raises_on_decimal(expr, risk) || value_raises_on_temporal(expr, risk)
}

///|
/// The decimal family's half: the tree combines decimal cells — the shapes
/// `expr_has_decimal_checked_op` lists over names the decimal risk set
/// carries.
fn value_raises_on_decimal(expr : @ir.ExprNode, risk : ValueRisk) -> Bool {
  (risk.decimal.any || expr_touches_decimal(expr, risk.decimal.names)) &&
  expr_has_decimal_checked_op(expr)
}

///|
/// The temporal family's half: the tree shifts or differences temporal
/// cells — an `Add` / `Sub` over names the temporal risk set carries.
fn value_raises_on_temporal(expr : @ir.ExprNode, risk : ValueRisk) -> Bool {
  (risk.temporal.any || expr_touches_temporal(expr, risk.temporal.names)) &&
  expr_has_temporal_checked_op(expr)
}

///|
/// The crossing-point form: whether any of a stage's expressions carries
/// either family's checked refusals. A stage that passes stays crossable
/// by every structural gate as before; one that fails is a floor.
fn stage_value_raises(exprs : Array[@expr.Expr], risk : ValueRisk) -> Bool {
  exprs.any(e => value_raises_on_values(e.node(), risk))
}
