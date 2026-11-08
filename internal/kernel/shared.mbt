// Four blocks, all serving the kernels that operate on `Series` operands:
// the `using` seam that binds the `series` pieces the kernels read by bare
// name (the type, and the scalar-projection free function); the two cell
// gates (`zip_present` / `map_present`) that add the null layer to every
// elementwise kernel; the shared binary type-mismatch error builder; and the
// broadcast / singleton alignment helpers the frame verbs share with the
// evaluator. A kernel reads a validity mask and builds an `Option`-cell
// array, and raises the binary type-mismatch error, all without the caller
// (`frame`'s evaluator) seeing a storage backend.
//
// The kernels build on `series`: `Series` is the operand and result unit.
// Its column verbs — the validity-mask read, the row gathers, backend
// convergence — are methods, reached by dot syntax; the scalar projection
// (`scalars_to_series`) is a free function, bound unqualified here.
//
// Backend convergence is a convention the elementwise kernels keep, not a
// contract every kernel result carries. The hard contract is the values: a
// kernel result holds correct cells whichever backend carries them — the
// tag is invisible to equality. Convergence itself — a computed all-valid
// numeric column landing on the `Numeric` fast path — reaches a result one
// of two ways: through `scalars_to_series` (which converges), or by the
// explicit `try_column_to_numeric` pass the elementwise families
// (arithmetic, string, ternary) run before the result crosses the package
// line; the evaluator tests pin the converging families' landing by storage
// kind, and a new elementwise entry point owes the same assertion — one
// that forgets the pass loses only the fast path, never a value.
// Deliberately exempt are the kernels that fold into an `Option`-cell array
// and return through the nullable constructors directly — the `cum_*`
// family (`CumCount`'s output all-valid by construction), the rolling
// statistics, and `unique_counts` — which land `Builtin` even when every
// cell is present: re-walking a just-built column to relabel it buys only
// the fast path for the rest of the plan, not a value either.

///|
using @series {type Series, scalars_to_series}

///|
/// Build the cells of a binary elementwise op: index `i` is `Some(f(i))` when
/// both operands are present there, else `None` — the Arrow rule that
/// a null on either side nulls the output cell. The shared null-gate behind
/// every binary kernel in this package — arithmetic, division, the
/// `Double`-result forms (`pow`), the null-on-zero forms (`%`, `//`), and the
/// comparison kernel's nullable cell loop — so each dtype arm supplies only
/// its per-cell op. Total — `f` only reads two present cells.
fn[T] zip_present(
  n : Int32,
  lv : Array[Bool],
  rv : Array[Bool],
  f : (Int32) -> T,
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
fn[T] map_present(
  n : Int32,
  valid : Array[Bool],
  f : (Int32) -> T,
) -> Array[T?] {
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
/// `Int` / `Float`, `Builtin` for `Bool` / `String` / `Date` / `Timestamp`. `Scalar::Null` has no
/// column representation (no Null-dtype backend), so it raises `Unsupported`.
pub fn singleton_series(value : @types.Scalar) -> Series raise @types.DataError {
  match value {
    @types.Scalar::Int(v) => Series::from_ints("literal", [v])
    @types.Scalar::Float(v) => Series::from_floats("literal", [v])
    @types.Scalar::Bool(v) => Series::from_bools("literal", [v])
    @types.Scalar::String(v) => Series::from_strings("literal", [v])
    @types.Scalar::Date(v) => Series::from_date_options("literal", [Some(v)])
    @types.Scalar::Timestamp(v) =>
      Series::from_timestamp_options("literal", [Some(v)])
    @types.Scalar::Duration(v) =>
      Series::from_duration_options("literal", [Some(v)])
    @types.Scalar::Decimal(v) => Series::from_decimals("literal", [Some(v)])
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
/// the frame layer's literal-series tests (public path) and its evaluator
/// whitebox tests (through the binary tag entry).
fn broadcast_pair(
  left : Series,
  right : Series,
) -> (Series, Series) raise @types.DataError {
  let m = left.len()
  let n = right.len()
  if m == n {
    (left, right)
  } else if m == 1 {
    (left.gather_series(Array::make(n, 0)), right)
  } else if n == 1 {
    (left, right.gather_series(Array::make(m, 0)))
  } else {
    // No side is a natural baseline, so the pair answers in declaration
    // order — the lengths themselves are the diagnosis.
    raise @types.DataError::LengthMismatch(m, n)
  }
}

///|
/// Stretch one evaluation result onto a column slot of `target` rows: a
/// matching length passes through, a length-1 result (a literal or aggregation)
/// is gathered at index 0 over every row (including to zero rows). Any other
/// length raises `LengthMismatch`. Covered by the frame layer's literal-series
/// tests (public path) and its evaluator whitebox tests (directly).
pub fn broadcast_series(
  s : Series,
  target : Int32,
) -> Series raise @types.DataError {
  if s.len() == target {
    s
  } else if s.len() == 1 {
    s.gather_series(Array::make(target, 0))
  } else {
    raise @types.DataError::LengthMismatch(target, s.len())
  }
}
