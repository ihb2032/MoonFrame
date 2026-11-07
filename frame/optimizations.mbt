// The optimizer's caller-facing switch — `LazyFrame::collect`'s
// `optimizations~` option. Each field gates one pass or rule of the
// pipeline (`optimize_with` reads the table through these), every one
// defaulting to on, so the default `collect` runs the pipeline exactly as
// it always has and a caller can turn a stage off to pin a behaviour. The
// switch lives on `collect` alone: `explain(optimized=true)` renders the
// default pipeline's rewrite and takes no stage flags, so it cannot show
// the plan a stage-off `collect` runs. The join-side narrowing and
// pushthrough ride the `projection_pushdown` flag — they are that pass's
// own Join arm, not a stage of their own.

///|
/// Which optimizer stages a `collect` runs. Every field defaults to
/// `true`; a `false` leaves the plan as built for that stage. The stages
/// are independent rewrites of the same plan, so any subset runs soundly —
/// turning one off costs the optimisation, never the semantics (the
/// error-fidelity contract in `LazyFrame::collect`'s docstring is what the
/// *on* stages preserve; turning a stage off only removes rewrites).
pub struct Optimizations {
  /// The slice / head / tail pushdown — `slice` / `head` / `tail` sinking
  /// below layout-preserving stages.
  slice_pushdown : Bool
  /// The predicate pushdown — filters sinking toward the scan, including
  /// the split of a join's filter into its sides.
  predicate_pushdown : Bool
  /// The projection pushdown — scans narrowed to the columns their
  /// consumers read, including the join-side narrowing and pushthrough.
  projection_pushdown : Bool
  /// The `with_columns` clustering rule — adjacent stages fused.
  cluster_with_columns : Bool
  /// The constant-folding rule — literal-only subtrees folded.
  simplify_expressions : Bool
}

///|
/// Every stage on — the pipeline `collect` has always run.
pub fn Optimizations::Optimizations() -> Optimizations {
  {
    slice_pushdown: true,
    predicate_pushdown: true,
    projection_pushdown: true,
    cluster_with_columns: true,
    simplify_expressions: true,
  }
}
