// The all-valid reductions over `NumericColumn`: `sum` / `mean` / `min` /
// `max`, kept apart from the fast-path layout file so the two read apart (the
// name mirrors the series-side reducer file). The accumulations themselves
// are the shared folds in `internal/numeric` (`fold_int64_sum` /
// `fold_double_sum` / `fold_extremum`), so this module is dispatch only: each
// arm picks the fold, the reader, and the constant-true presence an
// all-valid column has.
//
// A second implementation of rules that are stated canonically elsewhere:
// The series-side reducer holds the null / `NaN` / empty-window semantics every
// column reduction follows, and `Series::sum` / `mean` / `min` / `max` route a
// `Numeric` column here instead, for the bitmap-free fold. The rules live in
// the shared fold docstrings and the series-side canonical notes; change them
// there first, and expect the backend parity tests to catch a
// divergence, since nothing about these dispatchers' types can.

///|
/// Sum of every cell.
///
/// - `Int` → `Scalar::Int`, accumulated in 64-bit `Int64` (sums past the
///   32-bit ceiling do not overflow).
/// - `Float` → `Scalar::Float`, accumulated in `Double`; a `NaN` cell
///   propagates (Polars semantics — `NaN` is a value, not missing).
/// - Empty → the additive identity (`Scalar::Int(0)` / `Scalar::Float(0.0)`).
///
/// Total. There is no missing value to skip and no non-numeric dtype to
/// reject, so — unlike `Series::sum`, which `raise`s `TypeMismatch` for
/// `Bool` / `String` — this never fails. Keeping it total rather than
/// propagating an impossible `raise` avoids a dead `Err` arm that would break
/// 100% coverage (`feedback_lib_no_abort`).
pub fn NumericColumn::sum(self : NumericColumn) -> @types.Scalar {
  match self.data {
    Int(a) =>
      @types.Scalar::Int(
        @numeric.fold_int64_sum(a.length(), i => a[i], _ => true),
      )
    Float(a) =>
      @types.Scalar::Float(
        @numeric.fold_double_sum(a.length(), i => a[i], _ => true).0,
      )
  }
}

///|
/// Arithmetic mean of every cell, as a `Double` (matching `Series::mean`).
///
/// The denominator is the cell count `len` — every slot is present, so there
/// is no non-null count to compute. A `Float` `NaN` propagates through the
/// sum to a `NaN` mean (Polars semantics); an `Int` column accumulates in
/// `Double` (`fold_double_sum` widening each cell), the mean-safe form.
///
/// `raise InvalidOperation` on an empty column: the mean of zero values is
/// undefined (`0 / 0`), a genuine failure mode (unlike `sum`'s identity), so
/// the `raise` is real rather than an impossible one — it does not leave a
/// dead arm.
pub fn NumericColumn::mean(
  self : NumericColumn,
) -> Double raise @types.DataError {
  let n = self.len()
  if n == 0 {
    raise @types.DataError::InvalidOperation("mean of empty column")
  }
  let total = match self.data {
    Int(a) =>
      @numeric.fold_double_sum(a.length(), i => a[i].to_double(), _ => true).0
    Float(a) => @numeric.fold_double_sum(a.length(), i => a[i], _ => true).0
  }
  total / n.to_double()
}

///|
/// Minimum cell as a `Scalar`, by the dtype's natural order. Total, matching
/// `Series::min`:
/// - Empty column → `Scalar::Null`.
/// - `Float` `NaN` is skipped (treated as missing for the extremum, as in
///   Polars' regular `min` — distinct from `sum` / `mean`, where it
///   propagates, and from `sort`, which orders `NaN` as the largest value).
///   An all-`NaN` `Float` column → `Scalar::Null`.
pub fn NumericColumn::min(self : NumericColumn) -> @types.Scalar {
  self.extremum(want_min=true)
}

///|
/// Maximum cell as a `Scalar`. Mirrors `min` with `>` for `<`; the
/// `Float` `NaN`-skip and empty rules are identical. Total.
pub fn NumericColumn::max(self : NumericColumn) -> @types.Scalar {
  self.extremum(want_min=false)
}

///|
/// Shared min/max kernel: the natural-order extremum over the cells, `want_min`
/// choosing `<` over `>`. `Float` `NaN` is skipped (missing for the extremum,
/// as in Polars' regular min/max; `sort` instead orders `NaN` as the largest
/// value); an empty or all-`NaN` column yields
/// `Scalar::Null`. `min` / `max` are this with `want_min` true / false — the
/// comparison is the only difference, so it is the only thing parameterised
/// (the `fold_extremum` operand type differs per dtype arm, so the closure
/// stays inline rather than shared). Total.
fn NumericColumn::extremum(
  self : NumericColumn,
  want_min~ : Bool,
) -> @types.Scalar {
  match self.data {
    Int(a) => {
      let get = i => a[i]
      let skip = fn(_i) { false }
      let better = (x, y) => if want_min { x < y } else { x > y }
      let best = @numeric.fold_extremum(a.length(), get, skip, better)
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Int(b)
      }
    }
    Float(a) => {
      let get = i => a[i]
      let skip = i => a[i].is_nan()
      let better = (x, y) => if want_min { x < y } else { x > y }
      let best = @numeric.fold_extremum(a.length(), get, skip, better)
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Float(b)
      }
    }
  }
}
