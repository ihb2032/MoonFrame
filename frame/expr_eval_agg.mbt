///|
/// The aggregation kernel: reduce an evaluated operand over its scope to a
/// length-1 column through the shared `reducer_for` machinery — the same
/// `ReduceOp` vocabulary the AST's `Agg` node carries, shared with the
/// grouped-`agg` fast path so both route each op the same way.

///|
/// Reduce an evaluated operand (length `|scope|`) to a length-1 column — the
/// point where group scopes (E4) and whole-frame scopes share one path.
/// Delegates to the shared `reducer_for` kernel (the same one `Series::sum` /
/// `mean` / `min` / `max` and the grouped `agg` reduce through),
/// then projects the reduced `Scalar` into a length-1 column with
/// `scalars_to_series`. Inherits the kernel's dtype / null / `NaN` rules:
/// - `Sum`: `Int → Int`, `Float → Float`, nulls skipped, `NaN` propagates;
///   an empty / all-null operand sums to the additive identity. Non-numeric
///   raises `TypeMismatch`.
/// - `Mean`: always `Float`, nulls skipped from both numerator and
///   denominator, `NaN` propagates. An empty / all-null operand yields a
///   **null cell** — deliberately not `Series::mean`'s `InvalidOperation`,
///   because a per-group reduction must produce a value slot for an all-null
///   group (Polars `mean` semantics). Non-numeric raises `TypeMismatch`.
/// - `Min` / `Max`: total over every dtype in the operand's own dtype, `NaN`
///   skipped; empty / all-null / all-`NaN` reduces to a null cell.
/// - `Count`: the non-null cell count, never null.
/// Numeric outputs converge onto the `Numeric` backend, the expression-engine
/// convention for computed columns; consumers broadcast the length-1 result
/// back over their scope.
fn eval_agg(op : ReduceOp, operand : Series) -> Series raise @types.DataError {
  let (reducer, probe) = reducer_for(operand, op)
  let cell = reducer(operand.len(), k => k)
  scalars_to_series(probe, operand.name(), [cell])
}
