// Cell gates and the shared error builder used across the vectorized kernels.
// They are `series`-level, not `frame`-level: a kernel reads a validity mask and
// builds an `Option`-cell array, and raises the binary type-mismatch error, all
// without the caller (`frame`'s evaluator) seeing a storage backend.
//
// The kernels build on `series`: `Series` is the operand and result unit, and the
// seams bound below let a kernel read a column's validity mask, converge an
// all-valid numeric result back onto the fast path, and build a result column from
// scalars. This `using` import binds them unqualified so the kernels read them by
// bare name.

///|
using @series {
  type Series,
  gather_series,
  validity_bools,
  try_column_to_numeric,
  scalars_to_series,
}

///|
/// Build the cells of a binary elementwise op: index `i` is `Some(f(i))` when
/// both operands are present there, else `None` — the Arrow / Polars rule that
/// a null on either side nulls the output cell. The shared null-gate behind
/// every binary numeric kernel in this package — arithmetic, division, the
/// `Double`-result forms (`pow`), and the null-on-zero forms (`%`, `//`) — so
/// each dtype arm supplies only its per-cell op. Total — `f` only reads two
/// present cells.
fn[T] zip_present(
  n : Int,
  lv : Array[Bool],
  rv : Array[Bool],
  f : (Int) -> T,
) -> Array[T?] {
  Array::makei(n, i => if lv[i] && rv[i] { Some(f(i)) } else { None })
}

///|
/// Build the cells of a unary elementwise op: index `i` is `Some(f(i))` when the
/// operand is present there, else `None` — a null cell maps to a null result.
/// The shared null-gate behind every unary kernel in this package — the numeric
/// unary ops (`eval_unary_num`, so `neg` through `round`), logical-not, the NaN
/// probes, `is_in`, and the string namespace — so each arm supplies
/// only its per-cell map. The single-operand sibling of `zip_present`. Total —
/// `f` only reads a present cell.
fn[T] map_present(n : Int, valid : Array[Bool], f : (Int) -> T) -> Array[T?] {
  Array::makei(n, i => if valid[i] { Some(f(i)) } else { None })
}

///|
/// Build the structured error a binary numeric / ordering kernel raises when
/// its operands are not a supported pair. `TypeMismatch(Operation(...))` keeps the operation
/// and both dtypes programmable while its `message()` preserves the historical
/// `cannot <verb> <left> and <right>` wording. (`eval_logic` names the Bool
/// requirement instead, so it keeps its own error shape.)
fn binary_type_mismatch_error(
  verb : String,
  left : Series,
  right : Series,
) -> @types.DataError {
  @types.DataError::TypeMismatch(
    @types.TypeMismatchDetail::Operation(verb, left.dtype(), right.dtype()),
  )
}

///|
/// A length-1 `Series` holding one scalar, named `"literal"`. Each scalar lands
/// on whatever backend its `Series::from_*` constructor picks — `Numeric` for
/// `Int` / `Float`, `Builtin` for `Bool` / `String`. `Scalar::Null` has no
/// column representation (no Null-dtype backend), so it raises `Unsupported`.
pub fn singleton_series(value : @types.Scalar) -> Series raise @types.DataError {
  match value {
    @types.Scalar::Int(v) => Series::from_ints("literal", [v])
    @types.Scalar::Float(v) => Series::from_floats("literal", [v])
    @types.Scalar::Bool(v) => Series::from_bools("literal", [v])
    @types.Scalar::String(v) => Series::from_strings("literal", [v])
    @types.Scalar::Null =>
      raise @types.DataError::Unsupported(
        "cannot evaluate a Null literal: no Null-dtype column backend",
      )
  }
}

///|
/// Align two evaluation results for an elementwise kernel: equal lengths pass
/// through, a length-1 side is broadcast (gathered at index 0) to the other
/// side's length — including to zero rows, where the empty gather never touches
/// the value. Two `lit_series` of differing length reach the mismatch arm and
/// raise `LengthMismatch` (keeping the helper total). Covered by
/// `frame/lit_series_test.mbt` (public path) and `frame/expr_eval_wbtest.mbt` (directly).
pub fn broadcast_pair(
  left : Series,
  right : Series,
) -> (Series, Series) raise @types.DataError {
  let m = left.len()
  let n = right.len()
  if m == n {
    (left, right)
  } else if m == 1 {
    (gather_series(left, Array::make(n, 0)), right)
  } else if n == 1 {
    (left, gather_series(right, Array::make(m, 0)))
  } else {
    raise @types.DataError::LengthMismatch
  }
}

///|
/// Stretch one evaluation result onto a column slot of `target` rows: a
/// matching length passes through, a length-1 result (a literal or aggregation)
/// is gathered at index 0 over every row (including to zero rows). Any other
/// length raises `LengthMismatch`. Covered by `frame/lit_series_test.mbt` (public
/// path) and `frame/expr_eval_wbtest.mbt` (directly).
pub fn broadcast_series(
  s : Series,
  target : Int,
) -> Series raise @types.DataError {
  if s.len() == target {
    s
  } else if s.len() == 1 {
    gather_series(s, Array::make(target, 0))
  } else {
    raise @types.DataError::LengthMismatch
  }
}
