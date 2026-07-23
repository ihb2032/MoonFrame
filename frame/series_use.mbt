// `frame` builds on `series`: `Series` is the per-column unit `DataFrame`
// wraps, and the column-level helpers bound below — row gather / slice / count
// clamp, the validity-mask read, the option-constructor rebuild combinator,
// backend
// convergence (`preserve_backend` / `try_column_to_numeric`), the shared
// reduction dispatch (`reducer_for` / `scalars_to_series` / `ReduceOp`), and
// the composite-key cell encoding (`key_cell` / `KeyCell`) — live in `series`
// because the `Series` methods that need them must, by method coherence, sit
// beside the type. This `using` import binds them unqualified here so the
// DataFrame transforms, the expression evaluator, `group_by`, `join`, and
// `sort` read them by bare name exactly as when they were frame-local.

///|
using @series {
  type Series,
  type KeyCell,
  type ReduceOp,
  gather_series,
  gather_series_opt,
  slice_series,
  clamp_take,
  validity_bools,
  rebuild_options,
  preserve_backend,
  try_column_to_numeric,
  reducer_for,
  scalars_to_series,
  key_cell,
}
