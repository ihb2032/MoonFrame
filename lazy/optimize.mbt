///|
/// The query optimizer: a fixed pipeline of **total** plan→plan rewrites —
/// pure tree walking, no raise, no abort — that `collect` runs in front of
/// the executor and `explain(optimized=true)` renders for inspection. The
/// passes and their run order are the table `optimizer_passes` right below;
/// the whole-plan rules that run after them are the table
/// `optimizer_rules`. A new pass is a rewrite function documented beside
/// its own soundness rules plus one row in its table — the prose here says
/// what the pipeline *is*, and points at the tables for what it *contains*,
/// so the two cannot drift apart. The slice pass runs first and sinks
/// row-window nodes (`head` / `tail` / `slice` / `first` / `last`) toward
/// the scan, fusing neighbouring windows into their composite where the
/// composite provably keeps the eager rows (and refusing the fusion —
/// leaving the floor — where it does not: a negative bound, offsets whose
/// sum leaves `Int32`); the predicate pass then sinks `Filter` nodes so
/// rows drop as early as possible; the projection pass last runs a
/// required-columns analysis and narrows
/// each scan — the in-memory `Scan` and the `Csv` / `Ndjson` file sources
/// alike — to the columns its consumers provably read, so dead columns never
/// ride through row-level work (and, for a file source, are never even
/// parsed). The rules then fold column-free expression subtrees to their
/// literal values and merge adjacent `with_columns` stages that commute.
/// The inviolable contract is the executor's own:
/// `execute(optimize(p))` is equal to `execute(p)` for every plan that
/// collects. No pass ever alters a user-written node's *content* (predicates,
/// expression lists, keys stay verbatim); the predicate pass re-orders whole
/// `Filter` nodes downward, and the projection pass narrows a scan two ways —
/// inserting a `Select` of bare column references over an in-memory `Scan`,
/// or writing the column set into a file source's own projection field.
///
/// Error faithfulness under re-ordering: a plan that fails to collect
/// still fails after optimization. When exactly one stage is broken, it
/// fails with the *same* `DataError` — every error the evaluator can
/// produce (`ColumnNotFound`, dtype-level `TypeMismatch`,
/// `DuplicateColumn`, the reduction-shape `InvalidOperation`) is decided
/// by names, dtypes, and expression shape, none of which the rewrites
/// disturb. When *several* stages are independently broken, sinking a
/// filter below another broken stage can change which of their errors
/// surfaces first — both are real errors of the same plan, and which one
/// wins was an artifact of stage order to begin with. The failure modes that
/// would be value-dependent — `cast`'s parse / range rejection, and the opaque
/// closure of a `map` / `map_batches`, where dropping a row could drop the very
/// cell that raises — are fenced
/// off entirely: no `Filter` ever crosses a stage whose expressions
/// contain one; the row-locality rule is the fence.
///
/// The sole deliberate exception is a file source's projection (the `Csv` /
/// `Ndjson` sources). Narrowing it to the columns its consumers read means a
/// dropped column is never parsed, so a parse error confined to one — a
/// malformed cell no stage reads — is not raised by the optimized plan, where
/// the unoptimized full read would surface it. This is the defining property
/// of projection push-down into a source: every plan that *collects* still
/// collects equal, every whole-input failure (a malformed header or line, a
/// ragged row, a missing file) still fails identically, and a parse error in a *kept* column
/// still surfaces — only an error isolated to a pruned-away column goes
/// unraised. One refinement of that last clause: an absorbed predicate reads
/// its key columns ahead of the header's order, so in a file where *several*
/// columns each hold a parse error, the one the pushed-down read names can
/// differ from the one an eager read names — the same several-broken-stages
/// rule as above, inside a single scan rather than across stages.
///
/// # The pipeline
///
/// Pass order is explicit data — the `optimizer_passes` table — not an
/// implicit fact of how calls nest, so adding a pass cannot silently change
/// what runs when. Running the predicate pass first keeps the projection
/// analysis honest: a sunk filter is just another layout-preserving node by
/// the time the projection pass sees it, so its predicate columns stay alive
/// at the scan, and the narrowing `Select` lands *under* the sunk filter.
///
/// Each pass is idempotent on its own, and `optimize` as a whole is
/// idempotent too except on one shape: a filter that can sink *past* a
/// `Select` the projection pass inserts. Each pass runs exactly once per
/// `optimize`, so a re-optimize sinks that filter below the inserted select
/// and the projection pass rebuilds around the new position — a
/// fixed-point-across-passes concern, deliberately left alone: plans are
/// immutable, and each `collect` or `explain(optimized=true)` rewrites the
/// as-built plan exactly once. The white-box tests pin every
/// pass's own idempotence and the whole-pipeline property on the shapes
/// that hold.
fn LogicalPlan::optimize(self : LogicalPlan) -> LogicalPlan {
  // A DAG-shaped plan — nested self-joins share node objects by reference —
  // is left as-built: the passes rebuild tree-wise, so rewriting would
  // materialise every shared subplan once per occurrence (2^depth new nodes
  // for nested self-joins, an OOM abort long before execution), and the
  // memoised executor already runs each shared subplan exactly once without
  // help. Tree plans — every chain the builders produce without sharing a
  // `LazyFrame` value across both sides of a join — rewrite exactly as
  // before.
  if self.has_shared_subplan() {
    return self
  }
  let mut optimized = self
  for rewrite in optimizer_passes {
    optimized = rewrite(optimized)
  }
  // The local rewrite rules then run in one sweep, no fixed-point loop:
  // each rule is a fixed point of itself after a single application
  // (clustering merges greedily bottom-up, and blocked pairs stay blocked —
  // reads and definitions only grow under the list union; folding cascades
  // children-first within its one walk, and its fold domain provably holds
  // no column reference, so no name it could unblock survives a fold), and
  // neither rule can enable the other — clustering concatenates stage lists
  // leaving every expression untouched, and folding replaces column-free
  // subtrees leaving every name (the only input clustering reads) at its
  // previous value. A future rule that *can* enable another must restore
  // the fixed-point loop this replaced.
  for rule in optimizer_rules {
    let (next, _moved) = rule(optimized)
    optimized = next
  }
  optimized
}

///|
/// The pass table, in run order — the single statement of what the optimizer
/// does and in what sequence: each entry is one total plan→plan rewrite, run
/// once, left to right. A new pass is a rewrite function (its own file, with
/// its soundness rules documented beside it) plus one row here. The slice
/// pass runs first (the window it sinks is one more layout-preserving node
/// by the time the later passes see it); the predicate pass next, keeping
/// the projection analysis honest — a sunk filter's predicate columns stay
/// alive at the scan, so the narrowing `Select` lands *under* the sunk
/// filter; the projection pass then runs the required-columns analysis and
/// narrows each scan — the in-memory `Scan` and the `Csv` / `Ndjson` file
/// sources alike — to the columns its consumers provably read, so dead
/// columns never ride through row-level work (and, for a file source, are
/// never even parsed). The projection pass runs at the plan root, so its
/// entry hands the root requirement `None`: only a by-name reader under the
/// root re-establishes a requirement of its own.
let optimizer_passes : Array[(LogicalPlan) -> LogicalPlan] = [
  plan => plan.push_slices(),
  plan => plan.push_predicates(),
  plan => plan.push_projection(None),
]

///|
/// The local rewrite rules — node- and expression-shaped rewrites the
/// passes have placed (clustering adjacent `with_columns` stages, folding
/// column-free subtrees to literals) — run in one sweep after the passes.
/// Each entry returns its plan and whether it moved anything (the flag is
/// for the caller's information; the sweep does not loop — see the
/// argument in `optimize` for why one sweep reaches the joint fixed
/// point); a new rule is a rewrite function plus one row here.
let optimizer_rules : Array[(LogicalPlan) -> (LogicalPlan, Bool)] = [
  plan => plan.cluster_with_columns(),
  plan => plan.simplify_expressions(),
]
