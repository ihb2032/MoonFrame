// Statistics on a `Series`. Split from `series.mbt` so the structural
// surface stays narrow; everything here is a pure reduction over the
// underlying column.

///|
/// Count of non-null cells.
pub fn Series::count(self : Series) -> Int {
  self.len() - self.null_count()
}

///|
/// Sum of the valid (non-null) cells of an `Int` buffer. Factored out so
/// `sum` and `mean` share a single null-skipping accumulation instead of
/// each carrying its own copy.
fn sum_int_valid(data : Array[Int64], validity : @column.Bitmap) -> Int64 {
  let valid = validity.to_bools()
  let mut acc : Int64 = 0
  for i in 0..<data.length() {
    if valid[i] {
      acc = acc + data[i]
    }
  }
  acc
}

///|
/// Sum and count of the valid, non-`NaN` cells of a `Float` buffer.
/// `NaN` is treated as missing (skipped), matching `min` / `max` and
/// `sort_by`. The column stores 64-bit `Double`, so the sum
/// accumulates directly in `Double` with no narrowing. The returned
/// count excludes both nulls and `NaN`s, which is the denominator `mean`
/// needs (`Series::count` would over-count NaN).
fn sum_count_float_valid(
  data : Array[Double],
  validity : @column.Bitmap,
) -> (Double, Int) {
  let valid = validity.to_bools()
  let mut s : Double = 0.0
  let mut c = 0
  for i in 0..<data.length() {
    if valid[i] && !data[i].is_nan() {
      s = s + data[i]
      c = c + 1
    }
  }
  (s, c)
}

///|
/// Sum of non-null cells.
///
/// - `Int` series → `Scalar::Int(sum)`, accumulated in 64-bit `Int64`
///   (so only sums past 2^63 overflow, not the old 32-bit ceiling).
/// - `Float` series → `Scalar::Float(sum)`, accumulated in 64-bit
///   `Double`. `NaN` cells are skipped (treated as missing, matching
///   `min` / `max` and `sort_by`).
/// - Empty / all-null (or all-`NaN` `Float`) numeric series →
///   `Scalar::Int(0)` or `Scalar::Float(0.0)` (additive identity).
/// - Non-numeric series (`Bool`, `String`) → `Err(TypeMismatch)`.
pub fn Series::sum(self : Series) -> @types.Scalar raise @types.DataError {
  // Match the backing array directly (total) — the `Int` / `Float` arms
  // reduce, every other dtype raises. No `*_values` raise to bridge.
  match self.storage.data() {
    @column.ColumnData::Int(data) =>
      @types.Scalar::Int(sum_int_valid(data, self.storage.validity()))
    @column.ColumnData::Float(data) => {
      let (s, _) = sum_count_float_valid(data, self.storage.validity())
      @types.Scalar::Float(s)
    }
    _ =>
      raise @types.DataError::TypeMismatch(
        "sum undefined for " + self.dtype().to_string(),
      )
  }
}

///|
/// Arithmetic mean of non-null cells, returned as `Double`.
///
/// Reductions run in 64-bit — an `Int64` sum for `Int` columns, `Double`
/// accumulation for `Float` columns — and the division is performed in
/// `Double`, so a long column does not lose precision the way a 32-bit
/// accumulation would.
///
/// - Empty / all-null numeric series → `Err(InvalidOperation(...))`.
/// - Non-numeric series → `Err(TypeMismatch(...))`.
pub fn Series::mean(self : Series) -> Double raise @types.DataError {
  let cnt = self.count()
  match self.storage.data() {
    @column.ColumnData::Int(data) =>
      if cnt == 0 {
        raise @types.DataError::InvalidOperation(
          "mean of empty/all-null series",
        )
      } else {
        // Accumulate / divide in Double, then narrow — keeps the result
        // accurate for sums beyond the 24-bit Float significand.
        sum_int_valid(data, self.storage.validity()).to_double() /
        cnt.to_double()
      }
    @column.ColumnData::Float(data) => {
      // NaN cells are skipped, so divide by the non-NaN count, not
      // `cnt` (which counts NaN as present).
      let (s, c) = sum_count_float_valid(data, self.storage.validity())
      if c == 0 {
        raise @types.DataError::InvalidOperation(
          "mean of empty / all-null / all-NaN series",
        )
      } else {
        s / c.to_double()
      }
    }
    _ =>
      raise @types.DataError::TypeMismatch(
        "mean undefined for " + self.dtype().to_string(),
      )
  }
}

///|
/// Fold the non-missing cells of a length-`n` column to an extremum.
/// `get(i)` reads cell `i`; `missing(i)` is `true` when cell `i` is
/// skipped (a null slot, plus `NaN` for `Float`); `better(candidate,
/// best)` is `true` when `candidate` should replace the running best.
/// Returns `None` when every cell is missing.
///
/// `min_value` / `max_value` share this so each per-dtype arm supplies
/// only its reader, missing test, and comparator instead of repeating
/// the `best : T?` accumulation eight times over.
fn[T] fold_extremum(
  n : Int,
  get : (Int) -> T,
  missing : (Int) -> Bool,
  better : (T, T) -> Bool,
) -> T? {
  let mut best : T? = None
  for i in 0..<n {
    if !missing(i) {
      best = match best {
        None => Some(get(i))
        Some(b) => if better(get(i), b) { Some(get(i)) } else { Some(b) }
      }
    }
  }
  best
}

///|
/// Minimum non-null cell as a `Scalar`, by the natural order of the
/// series' dtype. Total — every v0.1 dtype has an order, so it never
/// fails (the v0.1 `Result`-wrapped `min` has been dropped in v0.2).
///
/// - Empty / all-null → `Scalar::Null`.
/// - `Float` NaN is treated as missing (skipped), matching `sort_by`
///   and pandas. A series of only NaN (and/or nulls) → `Scalar::Null`.
/// - `Bool` order: `false < true`.
pub fn Series::min_value(self : Series) -> @types.Scalar {
  let valid = self.storage.validity().to_bools()
  match self.storage.data() {
    @column.ColumnData::Int(a) => {
      let best = fold_extremum(a.length(), i => a[i], i => !valid[i], (x, y) => {
        x < y
      })
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Int(b)
      }
    }
    @column.ColumnData::Float(a) => {
      // NaN is treated as missing (skipped), matching `sort_by`.
      let best = fold_extremum(
        a.length(),
        i => a[i],
        i => !valid[i] || a[i].is_nan(),
        (x, y) => x < y,
      )
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Float(b)
      }
    }
    @column.ColumnData::Bool(a) => {
      // `false < true`: a candidate beats the best only when it is `false`
      // and the best is `true`.
      let best = fold_extremum(a.length(), i => a[i], i => !valid[i], (x, y) => {
        !x && y
      })
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Bool(b)
      }
    }
    @column.ColumnData::String(a) => {
      let best = fold_extremum(a.length(), i => a[i], i => !valid[i], (x, y) => {
        @types.compare_string_lex(x, y) < 0
      })
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::String(b)
      }
    }
  }
}

///|
/// Maximum non-null cell as a `Scalar`. Mirrors `min_value` with `>` in
/// place of `<`; the `Float` NaN and empty-series rules are identical.
/// Total — the v0.1 `Result`-wrapped `max` has been dropped in v0.2.
pub fn Series::max_value(self : Series) -> @types.Scalar {
  let valid = self.storage.validity().to_bools()
  match self.storage.data() {
    @column.ColumnData::Int(a) => {
      let best = fold_extremum(a.length(), i => a[i], i => !valid[i], (x, y) => {
        x > y
      })
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Int(b)
      }
    }
    @column.ColumnData::Float(a) => {
      // NaN is treated as missing (skipped), matching `sort_by`.
      let best = fold_extremum(
        a.length(),
        i => a[i],
        i => !valid[i] || a[i].is_nan(),
        (x, y) => x > y,
      )
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Float(b)
      }
    }
    @column.ColumnData::Bool(a) => {
      // `true > false`: a candidate beats the best only when it is `true`
      // and the best is `false`.
      let best = fold_extremum(a.length(), i => a[i], i => !valid[i], (x, y) => {
        x && !y
      })
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Bool(b)
      }
    }
    @column.ColumnData::String(a) => {
      let best = fold_extremum(a.length(), i => a[i], i => !valid[i], (x, y) => {
        @types.compare_string_lex(x, y) > 0
      })
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::String(b)
      }
    }
  }
}

///|
/// Number of distinct non-null values. The value-form rendering
/// (`Scalar::to_string`) is used as the canonical key — within a
/// fixed-dtype series two cells collide only when their values are
/// equal. As a deliberate consequence, every `Float` NaN collapses to
/// a single bucket (its `to_string` is `"NaN"`), matching pandas'
/// `nunique` behaviour on NaN-only inputs.
pub fn Series::unique_count(self : Series) -> Int {
  // Distinct count of the non-null cells, keyed by `Scalar::to_string`
  // (the canonical value form): within a fixed-dtype series two cells
  // collide only when their values are equal, and every `Float` NaN
  // renders `"NaN"` so they collapse into one bucket (matching pandas'
  // `nunique`). `Map::from_array` folds the keys into a set; its size is
  // the distinct count.
  Map::from_array(
    self
    .to_scalars()
    .filter(sc => !sc.is_null())
    .map(sc => (sc.to_string(), ())),
  ).length()
}

///|
/// One-row summary `DataFrame`.
///
/// Every series produces the same six columns in the same order, so the
/// summary shape is uniform across dtypes: `count`, `null_count`,
/// `unique_count` (`Int`), then `mean` (`Double`, `Null` for non-numeric
/// or empty / all-null numeric), then `min` and `max` in the source
/// dtype (`Null` cells when the reduction has no value). Non-numeric
/// series still carry the `mean` column (always `Null`) so callers can
/// rely on a fixed layout regardless of dtype.
///
/// The dtype dispatch matches on the concrete backing array via
/// `storage.data()` — `ColumnData`'s four variants are exhaustive, so
/// there's no `Null`-dtype arm and no fallback branch to keep in sync.
///
/// Raises only because the summary frame is built through the fallible
/// `DataFrame::new`. The columns are hardcoded-unique and equal length, so
/// the constructor always succeeds — the raise is forwarded rather than
/// caught, so no panic path crosses the public API.
pub fn Series::describe(self : Series) -> DataFrame raise @types.DataError {
  let cols : Array[Series] = []
  cols.push(Series::from_ints("count", [self.count().to_int64()]))
  cols.push(Series::from_ints("null_count", [self.null_count().to_int64()]))
  cols.push(Series::from_ints("unique_count", [self.unique_count().to_int64()]))
  // `mean` is always present (Null for non-numeric / empty / all-null),
  // so the summary shape is uniform across dtypes.
  let mean_col = try self.mean() catch {
    _ => Series::from_float_options("mean", [None])
  } noraise {
    v => Series::from_float_options("mean", [Some(v)])
  }
  cols.push(mean_col)
  // `min` / `max` keep the source dtype, so dispatch on the concrete
  // backing array.
  match self.storage.data() {
    @column.ColumnData::Int(_) =>
      push_extrema(
        self,
        cols,
        fn(sc) {
          match sc {
            @types.Scalar::Int(x) => Some(x)
            _ => None
          }
        },
        Series::from_int_options,
      )
    @column.ColumnData::Float(_) =>
      push_extrema(
        self,
        cols,
        fn(sc) {
          match sc {
            @types.Scalar::Float(x) => Some(x)
            _ => None
          }
        },
        Series::from_float_options,
      )
    @column.ColumnData::Bool(_) =>
      push_extrema(
        self,
        cols,
        fn(sc) {
          match sc {
            @types.Scalar::Bool(x) => Some(x)
            _ => None
          }
        },
        Series::from_bool_options,
      )
    @column.ColumnData::String(_) =>
      push_extrema(
        self,
        cols,
        fn(sc) {
          match sc {
            @types.Scalar::String(x) => Some(x)
            _ => None
          }
        },
        Series::from_string_options,
      )
  }
  DataFrame::new(cols)
}

///|
/// Push the source-dtype `min` / `max` summary columns for `describe`.
/// `extract` projects a `min_value` / `max_value` `Scalar` into the typed
/// cell (`None` for the no-value / wrong-variant case), and `build` is the
/// matching option constructor — so the four dtype arms share one body
/// instead of four near-identical helpers.
fn[T] push_extrema(
  s : Series,
  cols : Array[Series],
  extract : (@types.Scalar) -> T?,
  build : (String, Array[T?]) -> Series,
) -> Unit {
  cols.push(build("min", [extract(s.min_value())]))
  cols.push(build("max", [extract(s.max_value())]))
}
