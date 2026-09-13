///|
/// The closure escape hatches — the one way a host function enters an
/// expression tree. The three share one framework, stated once in full on
/// `map_elements`: the closure is opaque to introspection, rendering, and
/// the optimizer, which treats the node as a value barrier no filter sinks
/// across, and the output dtype and name follow the leftmost input.
/// `map_batches` (batched, optionally a per-group reduction) and `map_many`
/// (multi-input, a free function) are deltas on it. Evaluation lives in
/// `frame/expr_eval.mbt`; the whitebox rendering coverage in
/// `map_batches_wbtest.mbt`.

///|
/// Apply a host closure to each row of `self` — the single-input escape
/// hatch (Polars' `map_elements`). Where the operators and methods above
/// cover the documented algebra, `map_elements` reaches past it: `f`
/// receives the operand's cell as a `@types.Scalar` (a null cell as
/// `Scalar::Null`) and returns the output cell. `label` names the step in
/// `explain` / `Show` output — the function itself is opaque to
/// introspection, to rendering, and to the optimizer, which treats the node as
/// a barrier because it cannot see through the closure.
///
/// Building the node is total; `f` runs at evaluation, once per row, and
/// may `raise` (the error propagates from the consuming verb). The output
/// column's dtype is that of the first non-null `Scalar` the closure
/// returns, except that a closure returning both `Int` and `Float` cells
/// promotes the column to `Float` — the engine's `Int → Float` rule — rather
/// than nulling whichever type came second. An all-null (or empty) result has
/// no such cell, so its dtype
/// falls back to `self`'s own dtype, yielding an all-null (or empty)
/// column of that dtype rather than the `Unsupported` a bare `Null` literal
/// raises (Polars' tolerance of a null-returning map). Only the dtype is
/// borrowed; the result's backend follows its own content, as every computed
/// column's does. The result is
/// named after `self` (its leftmost column), so `with_alias` renames it.
/// Use it inside `with_columns` / `select` / `filter` like any other
/// expression; the optimizer treats it as a value barrier (it can raise on
/// values), so no filter sinks across it.
pub fn Expr::map_elements(
  self : Expr,
  label~ : String,
  f : (@types.Scalar) -> @types.Scalar raise @types.DataError,
) -> Expr {
  Expr::of(@ir.ExprNode::Map(label, [self.node], vs => f(vs[0])))
}

///|
/// Apply a host closure to `self`'s whole evaluated column at once — the
/// batched escape hatch (Polars' `map_batches`). Where `map_elements` hands
/// `f` one `@types.Scalar` per row, `map_batches` hands it the entire
/// `@series.Series` and takes back a `Series`, so a vectorised kernel (a
/// cumulative sum, a rank, a rolling window) runs once over the column rather
/// than cell by cell. `label` names the step in `explain` / `Show`; the
/// closure is opaque to introspection, to rendering, and to the optimizer,
/// which treats the node as a barrier because it cannot see through it.
///
/// Building the node is total; `f` runs at evaluation and may `raise`. The
/// returned series rides the same length contract as `lit_series`: a
/// frame-tall result passes through, a length-1 result broadcasts, any other
/// length raises `LengthMismatch` in the consuming verb. The result is named
/// after `self`, so `with_alias` renames it, and its backend is canonicalised
/// (an all-valid numeric result lands on `Numeric`) so `collect ≡ execute`.
///
/// Set `returns_scalar` when `f` reduces its input to a length-1 series: it
/// marks the node as a per-group reduction so it is accepted as a custom
/// aggregation inside `group_by(...).agg([...])`, where `f` receives each
/// group's rows and must return a length-1 series (a non-length-1 result
/// raises `LengthMismatch` at collect). Left `false` (the default), the node
/// is a plain row-wise expression and the optimizer treats it — like
/// `map_elements` — as a value-and-shape barrier that no filter sinks across.
pub fn Expr::map_batches(
  self : Expr,
  label~ : String,
  returns_scalar? : Bool = false,
  f : (@series.Series) -> @series.Series raise @types.DataError,
) -> Expr {
  Expr::of(
    @ir.ExprNode::MapBatches(label, [self.node], returns_scalar, vs => f(vs[0])),
  )
}

///|
/// Apply a host closure across several input columns, row by row — the
/// multi-input escape hatch, and the reified replacement for the original
/// closure `filter` predicate: `f` is handed one `@types.Scalar` per input
/// in `inputs` order (null cells as `Scalar::Null`) and is called for every
/// row, so a row predicate is a `map_many(..., f)` returning a `Bool`. A
/// free function rather than a method (there is no single `self`); `inputs`
/// may mix columns, literals, and aggregations, the length-1 results
/// broadcasting over the row count. Same opacity, totality, dtype
/// inference, naming (after the leftmost input), and value-barrier rules as
/// `map_elements` — with the dtype fallback reading the leftmost input,
/// whatever it is, so only an empty `inputs` leaves an all-null result with no
/// witness and raises `Unsupported`. The `inputs` array is copied, so mutating
/// it after construction cannot alter the built expression.
pub fn map_many(
  label~ : String,
  inputs : Array[Expr],
  f : (Array[@types.Scalar]) -> @types.Scalar raise @types.DataError,
) -> Expr {
  Expr::of(@ir.ExprNode::Map(label, inputs.map(e => e.node), f))
}
