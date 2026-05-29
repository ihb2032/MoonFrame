///|
/// A one-dimensional, dtype-aware column with a name. `Series` is the
/// per-column unit behind `DataFrame`: it bundles a `BuiltinColumn`
/// (Arrow-style storage with an explicit validity bitmap) with a column
/// name, and exposes the structural, nullability, transform, and cast
/// surface that ops / IO layers rely on. Statistics live in
/// `series_stats.mbt`.
///
/// The struct is read-only from outside this package — always go
/// through the named constructors so the underlying column maintains
/// its data-and-validity invariants.
pub struct Series {
  name : String
  storage : @column.BuiltinColumn
} derive(Eq, Debug)

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Wrap an existing `BuiltinColumn` under the given name. The validity
/// bitmap (and therefore the null-count) is whatever the column already
/// carries.
pub fn Series::new(name : String, storage : @column.BuiltinColumn) -> Series {
  { name, storage }
}

///|
/// Explicit alias for `new`. Useful at call sites where readers might
/// otherwise wonder whether the caller is about to pass raw values —
/// this name picks out the case where a `BuiltinColumn` has already
/// been built.
pub fn Series::from_builtin(
  name : String,
  storage : @column.BuiltinColumn,
) -> Series {
  { name, storage }
}

///|
/// Build an `Int` series from raw values (no nulls).
pub fn Series::from_ints(name : String, values : Array[Int64]) -> Series {
  { name, storage: @column.BuiltinColumn::from_ints(values) }
}

///|
/// Build an `Int` series where `None` entries are nulls.
pub fn Series::from_int_options(
  name : String,
  values : Array[Int64?],
) -> Series {
  { name, storage: @column.BuiltinColumn::from_int_options(values) }
}

///|
/// Build a `Float` series from raw values (no nulls).
pub fn Series::from_floats(name : String, values : Array[Double]) -> Series {
  { name, storage: @column.BuiltinColumn::from_floats(values) }
}

///|
/// Build a `Float` series where `None` entries are nulls.
pub fn Series::from_float_options(
  name : String,
  values : Array[Double?],
) -> Series {
  { name, storage: @column.BuiltinColumn::from_float_options(values) }
}

///|
/// Build a `Bool` series from raw values (no nulls).
pub fn Series::from_bools(name : String, values : Array[Bool]) -> Series {
  { name, storage: @column.BuiltinColumn::from_bools(values) }
}

///|
/// Build a `Bool` series where `None` entries are nulls.
pub fn Series::from_bool_options(
  name : String,
  values : Array[Bool?],
) -> Series {
  { name, storage: @column.BuiltinColumn::from_bool_options(values) }
}

///|
/// Build a `String` series from raw values (no nulls).
pub fn Series::from_strings(name : String, values : Array[String]) -> Series {
  { name, storage: @column.BuiltinColumn::from_strings(values) }
}

///|
/// Build a `String` series where `None` entries are nulls.
pub fn Series::from_string_options(
  name : String,
  values : Array[String?],
) -> Series {
  { name, storage: @column.BuiltinColumn::from_string_options(values) }
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// Column name.
pub fn Series::name(self : Series) -> String {
  self.name
}

///|
/// Logical dtype. Delegates to the underlying column so the two never
/// drift apart.
pub fn Series::dtype(self : Series) -> @types.DataType {
  self.storage.dtype()
}

///|
/// Number of cells (valid plus null).
pub fn Series::len(self : Series) -> Int {
  self.storage.len()
}

///|
/// `true` when the series has zero cells.
pub fn Series::is_empty(self : Series) -> Bool {
  self.storage.is_empty()
}

///|
/// Number of null cells.
pub fn Series::null_count(self : Series) -> Int {
  self.storage.null_count()
}

///|
/// Fraction of cells that are null, as a `Double`. Returns `0.0` for an
/// empty series rather than a 0/0 NaN — the latter would propagate
/// through downstream summary stats.
pub fn Series::null_rate(self : Series) -> Double {
  let n = self.len()
  if n == 0 {
    0.0
  } else {
    self.null_count().to_double() / n.to_double()
  }
}

///|
/// Whether cell `i` is null. Out-of-bounds indices bubble the
/// underlying `IndexOutOfBounds` error.
pub fn Series::is_null(
  self : Series,
  i : Int,
) -> Result[Bool, @types.DataError] {
  self.storage.is_null(i)
}

///|
/// Read cell `i` as a `Scalar` (`Null` for null cells). Out-of-bounds
/// indices bubble the underlying `IndexOutOfBounds` error.
pub fn Series::get(
  self : Series,
  i : Int,
) -> Result[@types.Scalar, @types.DataError] {
  self.storage.get(i)
}

///|
/// Materialise every cell as a `Scalar` (`Null` for null cells), in order.
/// Total — reads the backing array and validity mask once. Renderers (CSV
/// / JSON / Markdown) use this to walk a column without a per-cell
/// bounds-checked `get`.
pub fn Series::to_scalars(self : Series) -> Array[@types.Scalar] {
  let valid = self.storage.validity().to_bools()
  match self.storage.data() {
    @column.ColumnData::Int(a) =>
      Array::makei(a.length(), i => {
        if valid[i] {
          @types.Scalar::Int(a[i])
        } else {
          @types.Scalar::Null
        }
      })
    @column.ColumnData::Float(a) =>
      Array::makei(a.length(), i => {
        if valid[i] {
          @types.Scalar::Float(a[i])
        } else {
          @types.Scalar::Null
        }
      })
    @column.ColumnData::Bool(a) =>
      Array::makei(a.length(), i => {
        if valid[i] {
          @types.Scalar::Bool(a[i])
        } else {
          @types.Scalar::Null
        }
      })
    @column.ColumnData::String(a) =>
      Array::makei(a.length(), i => {
        if valid[i] {
          @types.Scalar::String(a[i])
        } else {
          @types.Scalar::Null
        }
      })
  }
}

///|
/// Expose the underlying `BuiltinColumn`. Ops layers use this to reach
/// the typed (`int_values` / `float_values` / ...) accessors and
/// bypass `Scalar` boxing.
pub fn Series::storage(self : Series) -> @column.BuiltinColumn {
  self.storage
}

// ── Transforms ────────────────────────────────────────────────────────

///|
/// Return a copy of this series with a different column name. Storage
/// is shared (immutable), so this is `O(1)`.
pub fn Series::rename(self : Series, new_name : String) -> Series {
  { name: new_name, storage: self.storage }
}

///|
/// Half-open `[start, end)` slice. Bounds checks mirror
/// `BuiltinColumn::slice`; errors surface unchanged so callers receive
/// the same `IndexOutOfBounds` / `InvalidOperation` diagnostics.
pub fn Series::slice(
  self : Series,
  start : Int,
  end : Int,
) -> Result[Series, @types.DataError] {
  self.storage.slice(start, end).map(s => { name: self.name, storage: s })
}

///|
/// Gather: produce a new series whose i-th entry is `self[indices[i]]`.
/// Out-of-bounds indices surface as `IndexOutOfBounds(idx)`.
pub fn Series::take(
  self : Series,
  indices : Array[Int],
) -> Result[Series, @types.DataError] {
  self.storage.take(indices).map(s => { name: self.name, storage: s })
}

///|
/// Total contiguous slice `[start, start + len)`, rebuilt through the
/// option constructors. The caller guarantees `0 <= start` and
/// `start + len <= self.len()`; under that contract every `start + k`
/// read is in-bounds, so the row copy needs no bounds-checking `Result`
/// (it reads `data` / validity arrays the same way value comparisons read
/// `data[i]` elsewhere). Backs `head` / `tail` / `slice` row transforms.
fn slice_series(s : Series, start : Int, len : Int) -> Series {
  let valid = s.storage.validity().to_bools()
  match s.storage.data() {
    @column.ColumnData::Int(a) =>
      Series::from_int_options(
        s.name,
        Array::makei(len, k => {
          if valid[start + k] {
            Some(a[start + k])
          } else {
            None
          }
        }),
      )
    @column.ColumnData::Float(a) =>
      Series::from_float_options(
        s.name,
        Array::makei(len, k => {
          if valid[start + k] {
            Some(a[start + k])
          } else {
            None
          }
        }),
      )
    @column.ColumnData::Bool(a) =>
      Series::from_bool_options(
        s.name,
        Array::makei(len, k => {
          if valid[start + k] {
            Some(a[start + k])
          } else {
            None
          }
        }),
      )
    @column.ColumnData::String(a) =>
      Series::from_string_options(
        s.name,
        Array::makei(len, k => {
          if valid[start + k] {
            Some(a[start + k])
          } else {
            None
          }
        }),
      )
  }
}

///|
/// Total gather: position `k` of the result is `s[idx[k]]`. The caller
/// guarantees every index is in `[0, s.len())`. Backs `drop_nulls`,
/// `take`, and the row-gather DataFrame transforms.
fn gather_series(s : Series, idx : Array[Int]) -> Series {
  let valid = s.storage.validity().to_bools()
  match s.storage.data() {
    @column.ColumnData::Int(a) =>
      Series::from_int_options(
        s.name,
        idx.map(k => if valid[k] { Some(a[k]) } else { None }),
      )
    @column.ColumnData::Float(a) =>
      Series::from_float_options(
        s.name,
        idx.map(k => if valid[k] { Some(a[k]) } else { None }),
      )
    @column.ColumnData::Bool(a) =>
      Series::from_bool_options(
        s.name,
        idx.map(k => if valid[k] { Some(a[k]) } else { None }),
      )
    @column.ColumnData::String(a) =>
      Series::from_string_options(
        s.name,
        idx.map(k => if valid[k] { Some(a[k]) } else { None }),
      )
  }
}

///|
/// Drop every null cell. Returned series has `len = original.len -
/// original.null_count` and a fully-valid bitmap.
pub fn Series::drop_nulls(self : Series) -> Series {
  let valid = self.storage.validity().to_bools()
  let kept : Array[Int] = []
  for i in 0..<valid.length() {
    if valid[i] {
      kept.push(i)
    }
  }
  gather_series(self, kept)
}

///|
/// Replace every null cell with `value`. Returns
/// `Err(TypeMismatch(...))` if `value` is `Scalar::Null` (filling nulls
/// with null is meaningless) or if its dtype differs from the series'.
/// The returned series has a fully-valid bitmap.
pub fn Series::fill_null(
  self : Series,
  value : @types.Scalar,
) -> Result[Series, @types.DataError] {
  let dt = self.dtype()
  match value {
    @types.Scalar::Null =>
      Err(@types.DataError::TypeMismatch("cannot fill nulls with Null"))
    @types.Scalar::Int(v) =>
      match self.storage.int_values() {
        Err(_) =>
          Err(
            @types.DataError::TypeMismatch(
              "fill_null type Int does not match column type " + dt.to_string(),
            ),
          )
        Ok((data, validity)) => {
          let valid = validity.to_bools()
          let buf = data.mapi((i, x) => if valid[i] { x } else { v })
          Ok({ name: self.name, storage: @column.BuiltinColumn::from_ints(buf) })
        }
      }
    @types.Scalar::Float(v) =>
      match self.storage.float_values() {
        Err(_) =>
          Err(
            @types.DataError::TypeMismatch(
              "fill_null type Float does not match column type " +
              dt.to_string(),
            ),
          )
        Ok((data, validity)) => {
          let valid = validity.to_bools()
          let buf = data.mapi((i, x) => if valid[i] { x } else { v })
          Ok({
            name: self.name,
            storage: @column.BuiltinColumn::from_floats(buf),
          })
        }
      }
    @types.Scalar::Bool(v) =>
      match self.storage.bool_values() {
        Err(_) =>
          Err(
            @types.DataError::TypeMismatch(
              "fill_null type Bool does not match column type " + dt.to_string(),
            ),
          )
        Ok((data, validity)) => {
          let valid = validity.to_bools()
          let buf = data.mapi((i, x) => if valid[i] { x } else { v })
          Ok({
            name: self.name,
            storage: @column.BuiltinColumn::from_bools(buf),
          })
        }
      }
    @types.Scalar::String(v) =>
      match self.storage.string_values() {
        Err(_) =>
          Err(
            @types.DataError::TypeMismatch(
              "fill_null type String does not match column type " +
              dt.to_string(),
            ),
          )
        Ok((data, validity)) => {
          let valid = validity.to_bools()
          let buf = data.mapi((i, x) => if valid[i] { x } else { v })
          Ok({
            name: self.name,
            storage: @column.BuiltinColumn::from_strings(buf),
          })
        }
      }
  }
}

///|
/// Cast to the target dtype. Delegates to `BuiltinColumn::cast`; the
/// supported targets are `Int`, `Float`, and `String`. `Bool` and
/// `Null` targets return `Err(Unsupported(_))`.
pub fn Series::cast(
  self : Series,
  target : @types.DataType,
) -> Result[Series, @types.DataError] {
  self.storage.cast(target).map(s => { name: self.name, storage: s })
}

///|
/// Convenience: cast to `Int`. See `BuiltinColumn::to_int` for the
/// per-source-dtype semantics (truncation, range-rejection, parse
/// strictness).
pub fn Series::to_int(self : Series) -> Result[Series, @types.DataError] {
  self.storage.to_int().map(s => { name: self.name, storage: s })
}

///|
/// Convenience: cast to `Float`.
pub fn Series::to_float(self : Series) -> Result[Series, @types.DataError] {
  self.storage.to_float().map(s => { name: self.name, storage: s })
}

///|
/// Convenience: cast to `String`. The output series keeps the same
/// name.
///
/// `BuiltinColumn::to_string_column` is total today (every dtype has a
/// value-form rendering), so the `.map` below only ever takes the `Ok`
/// branch — the `Err` stays inside `Result::map`. The signature stays
/// `Result`-shaped for parity with `to_int` / `to_float`, both of which do
/// have failure paths.
pub fn Series::to_string_series(
  self : Series,
) -> Result[Series, @types.DataError] {
  self.storage.to_string_column().map(s => { name: self.name, storage: s })
}
