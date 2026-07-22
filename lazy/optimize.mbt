///|
/// The query optimizer: two **total** plan→plan rewrites — pure tree
/// walking, no raise, no abort — that `collect` runs in front of the
/// executor and `explain(optimized=true)` renders for inspection. The
/// predicate pass runs first and sinks `Filter` nodes toward the scan so
/// rows drop as early as possible; the projection pass then runs a
/// required-columns analysis and narrows each scan — the in-memory `Scan`
/// and the `ScanCsv` / `ScanNdjson` file sources alike — to the columns its
/// consumers provably read, so dead columns never ride through row-level work
/// (and, for a file source, are never even parsed). The inviolable contract
/// is the executor's own: `execute(optimize(p))` is bitwise-equal to
/// `execute(p)` for every plan that collects. Neither pass ever alters a
/// user-written node's *content* (predicates, expression lists, keys stay
/// verbatim); the predicate pass re-orders whole `Filter` nodes downward, and
/// the projection pass narrows a scan two ways — inserting a `Select` of bare
/// column references over an in-memory `Scan`, or writing the column set into
/// a file source's own projection field.
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
/// wins was an artifact of stage order to begin with. The one failure
/// mode that would be value-dependent — `cast`'s parse / range rejection,
/// where dropping a row could drop the very cell that raises — is fenced
/// off entirely: no `Filter` ever crosses a stage whose expressions
/// contain a `Cast` (see `row_stable`).
///
/// The sole deliberate exception is a file source's projection (`ScanCsv` /
/// `ScanNdjson`). Narrowing it to the columns its consumers read means a
/// dropped column is never parsed, so a parse error confined to one — a
/// malformed cell no stage reads — is not raised by the optimized plan, where
/// the unoptimized full read would surface it. This is the defining property
/// of projection push-down into a source (and matches Polars' `scan_csv` /
/// `scan_ndjson`): every plan that *collects* still collects bitwise-equal,
/// every whole-input failure (a malformed header or line, a ragged row, a
/// missing file) still fails identically, and a parse error in a *kept* column
/// still surfaces unchanged — only an error isolated to a pruned-away column
/// goes unraised.
///
/// # The predicate pass
///
/// A filter may sink below a stage only when dropping rows first provably
/// cannot change the stage's output on the surviving rows, its errors, or
/// the filter's own verdicts:
///
/// - `Select` — crossed when every selected expression is `row_stable`
///   *and* the selection preserves its input's row count (it reads at
///   least one column, mapping rows one-to-one rather than collapsing to a
///   single literal row: an all-constant selection collapses any input,
///   even zero rows, to one row, so a dropping filter must stay above it),
///   and every column the predicate reads appears in the selection as a
///   *bare* `col(name)` (so the predicate sees the same values below, and
///   a predicate the selection would have starved of its column still
///   fails identically — a computed or renamed column fences the filter
///   above).
/// - `WithColumns` — crossed under the same `row_stable` rule when the
///   stage *defines* none of the predicate's columns (a defined name has
///   different values — or no existence at all — below the stage; its
///   pass-through columns are identical on both sides by construction).
/// - `Aggregate` — crossed when the predicate is `row_stable` and reads
///   only *bare-column* keys (a key written as `col(name)`: every row of a
///   group shares its key tuple, so filtering groups after aggregation and
///   filtering their rows before it drop exactly the same groups, in the
///   same first-appearance order — and a bare key's output column holds its
///   input column verbatim, so the predicate reads identical values below).
///   The predicate must also be `signed_zero_safe`: a `Float` key folds `-0.0`
///   and `+0.0` into one group, yet the group's output row keeps its
///   representative's signed key, and division and a negative exponent are the
///   operators that tell the two apart (`1/+0.0 = +inf` vs `1/-0.0 = -inf`,
///   `(+0.0) ** -1 = +inf` vs `(-0.0) ** -1 = -inf`), so such a predicate could
///   drop only part of a folded group below the aggregate and change its
///   surviving reduction.
///   Every key must also be `row_stable`, not only the ones the predicate
///   reads: each key is materialised as an output column (and joins the
///   grouping tuple). An aggregate key broadcasts a whole-scope reduction,
///   so a filtered scope would silently recompute its output cell; a cast /
///   map / lit-series key is value-raising or positional per `row_stable`.
///   All four must stay above the filter.
///   A *derived* key (any non-`Col` expression) outputs a computed column
///   whose name need not exist in the input at all, so a predicate over it
///   stays above; predicates over aggregation *outputs* read non-key names
///   and stay above the same way. Every aggregation must also be
///   `group_cell_stable` — its per-group cell can neither be null nor raise
///   on values: `sum` / `count` over a `row_stable` operand and non-null
///   literals qualify (a `sum(col.cast(…))` does not — its operand can raise
///   on the cells it meets), `mean` /
///   `min` / `max` do not (an all-null group yields a null cell, and
///   dropping that group would flip the stitched column's backend from
///   `Builtin` to `Numeric`, which the structural `Series` equality
///   observes), and `cast` does not (a dropped group could be the one whose
///   value fails to convert).
/// - Everything else stops the descent. `Head` / `Tail` / `Slice` pick
///   rows by *position*, and filtering re-numbers positions. `Sort` and
///   another `Filter` are value-safe to cross for row-stable predicates
///   but are deliberately left in place: crossing a filter re-orders
///   which predicate evaluates first, and crossing a sort buys nothing
///   until the executor can exploit sortedness. `Join` needs column
///   provenance through suffix renaming to split a predicate across its
///   sides, deferred with the projection pass's join narrowing — but
///   both sides restart their own descent, so filters inside either
///   side still sink. The in-memory `Scan` is the floor. A **file source**
///   goes one step further: the predicate is absorbed into the `ScanCsv` /
///   `ScanNdjson` node itself, so the reader prunes rows while parsing (see
///   `@io.read_csv_pruned`) and no `Filter` node remains above the leaf.
///   Only the first predicate is absorbed — combining two would reorder
///   which operand's evaluation error surfaces first — so a second filter
///   stays a node above the scan.
///
/// # The projection pass
///
/// A top-down "required columns" analysis:
///
/// - `None` — the consumer may observe this node's *entire* output
///   (the plan root, or anything under a barrier node): its layout must
///   survive untouched, so no narrowing happens at this node's leaves
///   unless a descendant re-establishes a requirement of its own.
/// - `Some(s)` — the consumer reads only the named columns, **by name**,
///   and is insensitive to the node's column order and to extra columns.
///   Only the two by-name readers originate this: `Select` and
///   `Aggregate`, whose outputs are fully determined by their expression
///   / key lists. The layout-preserving nodes (`Filter` / `Sort` /
///   `Head` / `Tail` / `Slice`) pass the requirement through, widened by
///   the columns they read themselves; `WithColumns` subtracts the names
///   its expressions *define* (those need not exist in its input) and
///   adds the names they *read*. `Join` stays a barrier — splitting a
///   requirement across two sides whose outputs interleave under suffix
///   renaming is column provenance, deferred — but both sides restart
///   their own pass, so a `Select` deep under a join still narrows its
///   own scan.
///
/// Why the order insensitivity matters: narrowing a `with_columns` input
/// can turn an in-place column *replacement* into an *append* (the
/// replaced name no longer exists in the narrowed input), perturbing the
/// intermediate column order. That perturbation is only ever visible to
/// the requirement's originator — a by-name reader — never to the plan
/// root, which always starts at `None`. The `Aggregate` executor reads
/// its keys in key-list order, not input order, so it qualifies too.
///
/// Running the predicate pass first keeps the analysis honest: a sunk
/// filter is just another layout-preserving node by the time the
/// projection pass sees it, so its predicate columns stay alive at the
/// scan, and the narrowing `Select` lands *under* the sunk filter.
///
/// Deliberately deferred: pruning dead expressions from `Select` /
/// `WithColumns` lists (changes which expressions evaluate, hence which
/// *errors* a failing plan reports), narrowing or predicate-splitting
/// through `Join`, sinking filters below `Sort`, and streaming a file source
/// (the reader still tokenises the whole file; push-down skips the *typed*
/// build of dropped rows, not the read). `optimize` is also not idempotent — re-optimizing an
/// already-rewritten plan would stack another (harmless) narrowing select
/// over an in-memory `Scan` (a file source's in-place projection just
/// recomputes to the same set) — which is moot in practice: plans are
/// immutable, and each `collect` or `explain(optimized=true)` call rewrites
/// the as-built plan exactly once.
fn optimize(plan : LogicalPlan) -> LogicalPlan {
  // A DAG-shaped plan — nested self-joins share node objects by reference —
  // is left as-built: both passes rebuild tree-wise, so rewriting would
  // materialise every shared subplan once per occurrence (2^depth new nodes
  // for nested self-joins, an OOM abort long before execution), and the
  // memoised executor already runs each shared subplan exactly once without
  // help. Tree plans — every chain the builders produce without sharing a
  // `LazyFrame` value across both sides of a join — rewrite exactly as
  // before.
  if has_shared_subplan(plan) {
    return plan
  }
  push_projection(push_predicates(plan), None)
}
