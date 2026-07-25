///|
/// The aggregation kernel: reduce an evaluated operand over its scope to a
/// length-1 column through the shared `reducer_for` machinery, plus
/// `reduce_op_of_agg` — the map from the read-only `@ir.AggOp` to the
/// frame-local `ReduceOp`, shared with the grouped-`agg` fast path so the two
/// route each op the same way.

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
fn eval_agg(op : @ir.AggOp, operand : Series) -> Series raise @types.DataError {
  let (reducer, probe) = reducer_for(operand.storage(), reduce_op_of_agg(op))
  let cell = reducer(operand.len(), k => k)
  scalars_to_series(probe, operand.name(), [cell])
}

///|
/// Map the read-only `@ir.AggOp` (matchable here, constructible only in
/// `expr`) into the frame-local `ReduceOp` the shared reduction kernel
/// speaks. Shared by the scoped `eval_agg` and the grouped `agg`
/// single-pass fast path (`bare_col_agg`), so the two map the same op the
/// same way. Exhaustive with no wildcard: a future `AggOp` variant fails
/// compilation here rather than silently routing to a wrong reduction.
fn reduce_op_of_agg(op : @ir.AggOp) -> ReduceOp {
  match op {
    @ir.AggOp::Sum => ReduceOp::Sum
    @ir.AggOp::Mean => ReduceOp::Mean
    @ir.AggOp::Min => ReduceOp::Min
    @ir.AggOp::Max => ReduceOp::Max
    @ir.AggOp::Count => ReduceOp::Count
    @ir.AggOp::Std => ReduceOp::Std
    @ir.AggOp::Var => ReduceOp::Var
    @ir.AggOp::Median => ReduceOp::Median
    @ir.AggOp::NUnique => ReduceOp::NUnique
    @ir.AggOp::First => ReduceOp::First
    @ir.AggOp::Last => ReduceOp::Last
  }
}
