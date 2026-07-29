// `frame` builds on `series`: `Series` is the per-column unit `DataFrame`
// wraps, and the column-level helpers bound below — row gather / slice, the
// validity-mask read, the mask-to-row-indices read, the two-column
// coalesce, backend
// convergence (`preserve_backend` / `try_column_to_numeric`), the shared
// reduction dispatch (`reducer_for` / `scalars_to_series` / `ReduceOp`), and
// the composite-key cell encoding (`key_cell` / `KeyCell`) — live in `series`
// because each one reads a column's private representation or builds a column
// through it, and `Series` owns that representation.
// Method coherence pins the *methods* there; these are free functions, and
// what pins them is that moving one out would mean either handing the storage
// upward again or importing `series` from a package `series` imports — which
// the layering guard now refuses in both directions. This `using` import
// binds them unqualified here so the
// DataFrame transforms, the expression evaluator, `group_by` and `join` read
// them by bare name exactly as when they were frame-local. (`sort` calls the
// sort kernel `@series.`-qualified instead — the binding list is what a file
// needs, not a rule about which files may use it.)
//
// Each of them hands back a `Series`, a freshly built array, or a scalar —
// never a live column's own buffer. That is the boundary's real content: this
// package decides what a verb means, and cannot reach in and change what a
// column *is*. The two helpers that did pass a raw buffer across it
// (`rebuild_options`' typed-array closures, and a `Bool` mask's cells) are
// package-private to `series` now, behind `coalesce_columns` and
// `mask_true_indices`.

///|
using @series {
  type Series,
  type KeyCell,
  type ReduceOp,
  gather_series,
  gather_series_opt,
  slice_series,
  validity_bools,
  mask_true_indices,
  coalesce_columns,
  preserve_backend,
  try_column_to_numeric,
  reducer_for,
  scalars_to_series,
  key_cell,
}
