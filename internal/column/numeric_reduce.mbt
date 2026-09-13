// The all-valid reductions over `NumericColumn`: `sum` / `mean` / `min` /
// `max` and the fold kernels behind them — split from `numeric.mbt` so the
// fast-path layout and the folds over it read apart (the name mirrors
// `series/reduce.mbt`).
//
// A second implementation of rules that are stated canonically elsewhere:
// `series/reduce.mbt` holds the null / `NaN` / empty-window semantics every
// column reduction follows, and `Series::sum` / `mean` / `min` / `max` route a
// `Numeric` column here instead, for the bitmap-free fold. The docstrings below
// therefore restate those rules for a direct `@column` caller — change them
// there first, and expect `series/backend_parity_test.mbt` to be what catches a
// divergence, since nothing about this file's types can.

///|
/// Plain `Int64` fold over the whole array — every slot is present, so unlike
/// the general `Builtin`-backend reduction there is no `validity().to_bools()`
/// and no per-slot `if valid[i]` branch. Used by `sum`, which keeps the `Int`
/// dtype (so sums past 2^63 overflow — the price of an exact integer sum).
/// `mean`, whose output is `Double`, widens through `fold_int_as_double`
/// instead: an `Int64` accumulator there would wrap past 2^63 and flip the
/// mean's sign even though `Double` represents the true value.
fn fold_int64(a : ArrayView[Int64]) -> Int64 {
  let mut acc : Int64 = 0
  for x in a {
    acc = acc + x
  }
  acc
}

///|
/// Fold an `Int64` array into a `Double`, widening each cell before adding.
/// The accumulator behind `mean` for an `Int` column: because the mean's output
/// is `Double`, accumulating in `Double` from the start cannot wrap past 2^63
/// (which would flip the sign, yielding a mean outside `[min, max]`), unlike
/// `fold_int64`. Matches Polars, which computes an `Int`-column mean in f64.
fn fold_int_as_double(a : ArrayView[Int64]) -> Double {
  let mut acc : Double = 0.0
  for x in a {
    acc = acc + x.to_double()
  }
  acc
}

///|
/// Plain `Double` fold over the whole array. `NaN` participates (it is a
/// present value, not missing), so a single `NaN` cell propagates to a `NaN`
/// total — Polars `sum` / `mean` semantics. Shared by `sum` and `mean`.
fn fold_double(a : ArrayView[Double]) -> Double {
  let mut acc : Double = 0.0
  for x in a {
    acc = acc + x
  }
  acc
}

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
    Int(a) => @types.Scalar::Int(fold_int64(a))
    Float(a) => @types.Scalar::Float(fold_double(a))
  }
}

///|
/// Arithmetic mean of every cell, as a `Double` (matching `Series::mean`).
///
/// The denominator is the cell count `len` — every slot is present, so there
/// is no non-null count to compute. A `Float` `NaN` propagates through the
/// sum to a `NaN` mean (Polars semantics).
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
    Int(a) => fold_int_as_double(a)
    Float(a) => fold_double(a)
  }
  total / n.to_double()
}

///|
/// Minimum cell as a `Scalar`, by the dtype's natural order. Total, matching
/// `Series::min`:
/// - Empty column → `Scalar::Null`.
/// - `Float` `NaN` is skipped (treated as missing for the extremum, as in
///   `sort` and Polars' regular `min` — distinct from `sum` / `mean`,
///   where it propagates). An all-`NaN` `Float` column → `Scalar::Null`.
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
/// as in `sort` / Polars' regular min/max); an empty or all-`NaN` column yields
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
