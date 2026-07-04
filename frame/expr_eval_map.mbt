///|
/// The `map` escape hatch (`map_elements` / `map_many`): apply an opaque host
/// closure row by row across the already-evaluated inputs, then project the
/// result cells onto a dtype — the first non-null cell fixes it
/// (`infer_cells_dtype`), an `Int`/`Float` mix promotes to `Float`
/// (`promote_mixed_int_float`), and an all-null result falls back to the
/// leftmost input's backend. `infer_cells_dtype` is shared with grouped `agg`.

///|
/// Apply a `Map` node's opaque closure `f` across its already-evaluated
/// inputs — the evaluator pushes each input's `Series` onto the value stack
/// before this combiner runs, so a failing input (unknown column, dtype
/// mismatch) has already propagated. The inputs are stretched to a common
/// height: any column-tall input fixes it (all share the node's `scope`, so a
/// non-1 length is `|scope|`), while all-length-1 inputs (or none at all) keep
/// height 1 — the literal / aggregation broadcast rule. Each row hands `f` one
/// cell per input, in order, a null cell as `Scalar::Null`; `f` runs for every
/// row and may `raise`.
///
/// The output dtype is inferred from the first non-null `Scalar` the closure
/// returns, then `scalars_to_series` projects the cells onto it (an off-type
/// cell becomes null; an all-valid numeric result converges onto `Numeric`).
/// An all-null or empty result has no non-null cell to fix the dtype, so it
/// falls back to the leftmost input's column backend and yields an all-null
/// (or empty) column of that dtype — matching Polars' tolerance of a
/// null-returning map. Only a column-less map with no non-null cell (e.g.
/// `map_many([], _ => Null)`) has no dtype witness and raises `Unsupported`,
/// like the `Null` literal. The column is named after the leftmost input (or
/// `"literal"` when there are none), agreeing with `Expr::output_name`; the
/// consuming verb renames it through `expr_output_name` regardless.
fn eval_map_apply(
  evaluated : Array[Series],
  f : (Array[@types.Scalar]) -> @types.Scalar raise @types.DataError,
) -> Series raise @types.DataError {
  let mut height = 1
  for s in evaluated {
    if s.len() != 1 {
      height = s.len()
    }
  }
  let columns : Array[Array[@types.Scalar]] = []
  for s in evaluated {
    columns.push(broadcast_series(s, height).to_scalars())
  }
  let width = columns.length()
  let cells : Array[@types.Scalar] = []
  for i in 0..<height {
    cells.push(f(Array::makei(width, k => columns[k][i])))
  }
  let name = if evaluated.is_empty() { "literal" } else { evaluated[0].name() }
  // A closure returning a mix of `Int` and `Float` unifies to `Float`, as the
  // arithmetic engine does, rather than nulling the minority type.
  let cells = promote_mixed_int_float(cells)
  // No non-null cell fixes the dtype when either the scope is empty (a 0-row
  // frame with a column input calls the closure zero times) or every result
  // cell is null. In both cases fall back to the leftmost input's own column
  // backend as the dtype witness (its array contents are ignored:
  // `scalars_to_series` reads the probe's variant only), yielding an empty or
  // all-null column of that dtype rather than raising — so `map` survives an
  // empty frame, and an all-null map matches Polars' tolerance of a
  // null-returning closure, mirroring that input's dtype as `name` already
  // mirrors its name. Only a column-less map (no input to borrow a backend
  // from, e.g. `map_many([], _ => Null)`) has no witness and raises
  // `Unsupported`, like a `Null` literal.
  let probe = match infer_cells_dtype(cells) {
    Some(p) => Some(p)
    None => evaluated.get(0).map(lead => lead.storage().data())
  }
  match probe {
    Some(p) => scalars_to_series(p, name, cells)
    None =>
      raise @types.DataError::Unsupported(
        "cannot infer the dtype of a map result with no non-null cell and no column input: no Null-dtype column backend",
      )
  }
}

///|
/// The output-column dtype probe for a list of result cells: the first
/// non-null cell fixes the dtype (`Int` / `Float` / `Bool` / `String`); an
/// all-null or empty cell list yields `None`. Shared by the `Map` evaluator
/// (which falls back to the leftmost input's backend, raising only when there
/// is no column input at all) and grouped `agg` (which falls back to the
/// reduction's empty-scope probe).
fn infer_cells_dtype(cells : Array[@types.Scalar]) -> @column.ColumnData? {
  for cell in cells {
    match cell {
      @types.Scalar::Int(_) => return Some(@column.ColumnData::Int([]))
      @types.Scalar::Float(_) => return Some(@column.ColumnData::Float([]))
      @types.Scalar::Bool(_) => return Some(@column.ColumnData::Bool([]))
      @types.Scalar::String(_) => return Some(@column.ColumnData::String([]))
      @types.Scalar::Null => ()
    }
  }
  None
}

///|
/// Whether the map result cells mix `Int` and `Float` — the one heterogeneity
/// the engine resolves by promotion (`Int -> Float`, as in `eval_arith` /
/// `eval_ternary`) rather than by nulling the minority type. `Bool` / `String`
/// never promote, so a mix involving them is not flagged here.
fn map_mixes_int_and_float(cells : Array[@types.Scalar]) -> Bool {
  let mut has_int = false
  let mut has_float = false
  for c in cells {
    match c {
      @types.Scalar::Int(_) => has_int = true
      @types.Scalar::Float(_) => has_float = true
      _ => ()
    }
  }
  has_int && has_float
}

///|
/// Promote a mixed `Int`/`Float` cell list to all-`Float` — the engine's
/// `Int -> Float` unification (as in `eval_arith` / `eval_ternary`) — so the
/// minority type is promoted rather than nulled by the first-non-null-cell
/// projection in `infer_cells_dtype`. A mix involving `Bool` / `String` never
/// promotes and is returned unchanged.
fn promote_mixed_int_float(
  cells : Array[@types.Scalar],
) -> Array[@types.Scalar] {
  if map_mixes_int_and_float(cells) {
    cells.map(c => {
      match c {
        @types.Scalar::Int(v) => @types.Scalar::Float(v.to_double())
        _ => c
      }
    })
  } else {
    cells
  }
}
