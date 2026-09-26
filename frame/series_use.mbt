// `frame` builds on `series`: `Series` is the per-column unit `DataFrame`
// wraps. The column-level verbs it calls — row gather / slice, the
// validity-mask read, the mask-to-row-indices read, the two-column coalesce,
// backend convergence (`preserve_backend` / `try_column_to_numeric`), the
// shared reduction dispatch (`reducer_for`) — are `Series` methods, reached
// by dot syntax from anywhere the type is visible, so they need no binding
// here. What the `using` import below binds are the pieces that are *not*
// methods and cannot become them: the types `Series` / `KeyCell` / `ReduceOp`
// (method coherence pins a type's methods to its own package, but a bare name
// for the type itself does not come with the import), the shared reduction
// projection (`scalars_to_series`, whose first argument is a dtype rather
// than a column), and the composite-key cell encoding (`key_cell`). Moving
// one of those out would mean either handing the storage upward again or
// importing `series` from a package `series` imports — which the layering
// guard refuses in both directions.
//
// Every one of them hands back a `Series`, a freshly built array, or a
// scalar — never a live column's own buffer. That is the boundary's real
// content: this package decides what a verb means, and cannot reach in and
// change what a column *is*. The two helpers that did pass a raw buffer
// across it (`rebuild_options`' typed-array closures, and a `Bool` mask's
// cells) are package-private to `series` now, behind `coalesce_columns` and
// `mask_true_indices`.

///|
using @series {
  type Series,
  type KeyCell,
  type ReduceOp,
  scalars_to_series,
  key_cell,
}
