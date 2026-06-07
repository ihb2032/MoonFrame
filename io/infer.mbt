// Shared per-column dtype inference and typed-column construction for the
// CSV and JSON readers. Both readers walk an abstract "cell source" (a CSV
// row matrix indexed by column, or a JSON record array indexed by key) and
// pick the narrowest dtype that accepts every non-null probe, in the same
// priority order Int → Float → Bool → String. Factoring the skeleton here
// keeps that order — the windowed-inference rule (with `infer_schema_rows
// <= 0` meaning "scan every row", Polars' `infer_schema_length=None`) and
// the build-time parse-failure policy (`OnParseError`: raise vs. null the
// offending cell) — defined in exactly one place; each reader supplies only
// its own cell accessor, null test, per-dtype probes, and error wording.

///|
/// The four dtypes inference can pick. `Null` is intentionally absent —
/// inference never produces it, so the builder match stays exhaustive
/// without an unreachable arm.
priv enum InferredDtype {
  InferInt
  InferFloat
  InferBool
  InferString
}

///|
/// What a reader does when a non-null cell fails to parse under the dtype
/// that inference locked in for its column — in practice a value past the
/// inference window that doesn't fit (e.g. a `String` in a column inferred
/// `Int` from its first rows).
///
/// - `Raise` (every reader's default) — surface the cell's `ParseError`,
///   failing the whole read. The strict, lossless behaviour: a malformed
///   cell is never silently dropped.
/// - `Null` — downgrade the offending cell to a null cell and keep going,
///   the resilient behaviour Polars exposes as `ignore_errors=True` (pandas
///   tolerates the same). The column keeps its inferred dtype; only the
///   unparseable cells become null.
///
/// Shared by `CsvReadOptions` / `JsonReadOptions` / `NdjsonReadOptions` and
/// consumed in `build_typed_column`'s parse-failure branch, so the three
/// readers agree on the policy.
pub(all) enum OnParseError {
  Raise
  Null
} derive(Eq, Debug)

///|
/// Pick the narrowest dtype that accepts every non-null cell in the first
/// `limit` rows, in priority order `Int → Float → Bool → String`. A
/// `limit <= 0` lifts the cap and scans every row (Polars'
/// `infer_schema_length=None`), so a dtype that only becomes clear deep in
/// the data is inferred rather than guessed from a prefix.
///
/// `cell(i)` reads the raw cell at row `i`; `is_null(c)` reports whether it
/// is a null cell (skipped by inference); `is_int` / `is_float` / `is_bool`
/// report whether a non-null cell parses as that dtype. A probe window
/// that is entirely null falls back to `String` (no signal to
/// disambiguate). A column that eliminates Int, Float, and Bool is
/// `String` whether it is pure-string or mixed, so once all three are out
/// we stop probing early — the remaining cells cannot change the outcome.
fn[Cell] infer_dtype(
  n : Int,
  limit : Int,
  cell : (Int) -> Cell,
  is_null : (Cell) -> Bool,
  is_int : (Cell) -> Bool,
  is_float : (Cell) -> Bool,
  is_bool : (Cell) -> Bool,
) -> InferredDtype {
  let scan = if limit <= 0 || limit > n { n } else { limit }
  let mut all_int = true
  let mut all_float = true
  let mut all_bool = true
  let mut saw_any = false
  for i in 0..<scan {
    let c = cell(i)
    if is_null(c) {
      continue
    }
    saw_any = true
    if all_int && !is_int(c) {
      all_int = false
    }
    if all_float && !is_float(c) {
      all_float = false
    }
    if all_bool && !is_bool(c) {
      all_bool = false
    }
    if !all_int && !all_float && !all_bool {
      break
    }
  }
  if !saw_any {
    InferString
  } else if all_int {
    InferInt
  } else if all_float {
    InferFloat
  } else if all_bool {
    InferBool
  } else {
    InferString
  }
}

///|
/// Materialise one typed column from an abstract cell source. `cell(i)`
/// reads the raw cell, `is_null(c)` maps a null cell to `None`, `parse(c)`
/// converts a non-null cell to `Some(value)` (or `None` when it doesn't fit
/// the locked-in dtype), and `build` wraps the option array into a
/// `Series`. Used for the parseable dtypes (`Int` / `Float` / `Bool`); the
/// `String` fallback is built inline by each reader because its `parse`
/// never fails (so it needs no `err`).
///
/// A non-null cell that `parse` rejects is handled per `on_parse_error`:
/// `Raise` surfaces `err(i, c)` (the strict default, failing the read),
/// `Null` downgrades it to a null cell so the read continues with the
/// column's inferred dtype intact (Polars' `ignore_errors`).
fn[Cell, T] build_typed_column(
  name : String,
  n : Int,
  cell : (Int) -> Cell,
  is_null : (Cell) -> Bool,
  parse : (Cell) -> T?,
  err : (Int, Cell) -> @types.DataError,
  on_parse_error : OnParseError,
  build : (String, Array[T?]) -> @frame.Series,
) -> @frame.Series raise @types.DataError {
  let values : Array[T?] = Array::makei(n, i => {
    let c = cell(i)
    if is_null(c) {
      None
    } else {
      match parse(c) {
        Some(x) => Some(x)
        None =>
          match on_parse_error {
            Raise => raise err(i, c)
            Null => None
          }
      }
    }
  })
  build(name, values)
}
