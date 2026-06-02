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
pub fn Series::is_null(self : Series, i : Int) -> Bool raise @types.DataError {
  self.storage.is_null(i)
}

///|
/// Read cell `i` as a `Scalar` (`Null` for null cells). Out-of-bounds
/// indices bubble the underlying `IndexOutOfBounds` error.
pub fn Series::get(
  self : Series,
  i : Int,
) -> @types.Scalar raise @types.DataError {
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
) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.slice(start, end) }
}

///|
/// Gather: produce a new series whose i-th entry is `self[indices[i]]`.
/// Out-of-bounds indices surface as `IndexOutOfBounds(idx)`.
pub fn Series::take(
  self : Series,
  indices : Array[Int],
) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.take(indices) }
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
/// Build the fill buffer for `fill_null`: keep each valid cell, replace
/// every null slot (`valid[i] == false`) with `v`. The four per-dtype
/// arms share this closure instead of repeating the `mapi` verbatim.
fn[T] fill_buffer(data : Array[T], valid : Array[Bool], v : T) -> Array[T] {
  data.mapi((i, x) => if valid[i] { x } else { v })
}

///|
/// Replace every null cell with `value`. `raise TypeMismatch(...)` if
/// `value` is `Scalar::Null` (filling nulls with null is meaningless) or
/// if its dtype differs from the series'. The returned series has a
/// fully-valid bitmap.
pub fn Series::fill_null(
  self : Series,
  value : @types.Scalar,
) -> Series raise @types.DataError {
  let dt = self.dtype()
  let valid = self.storage.validity().to_bools()
  match value {
    @types.Scalar::Null =>
      raise @types.DataError::TypeMismatch("cannot fill nulls with Null")
    @types.Scalar::Int(v) =>
      match self.storage.data() {
        @column.ColumnData::Int(data) => {
          let buf = fill_buffer(data, valid, v)
          { name: self.name, storage: @column.BuiltinColumn::from_ints(buf) }
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            "fill_null type Int does not match column type " + dt.to_string(),
          )
      }
    @types.Scalar::Float(v) =>
      match self.storage.data() {
        @column.ColumnData::Float(data) => {
          let buf = fill_buffer(data, valid, v)
          { name: self.name, storage: @column.BuiltinColumn::from_floats(buf) }
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            "fill_null type Float does not match column type " + dt.to_string(),
          )
      }
    @types.Scalar::Bool(v) =>
      match self.storage.data() {
        @column.ColumnData::Bool(data) => {
          let buf = fill_buffer(data, valid, v)
          { name: self.name, storage: @column.BuiltinColumn::from_bools(buf) }
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            "fill_null type Bool does not match column type " + dt.to_string(),
          )
      }
    @types.Scalar::String(v) =>
      match self.storage.data() {
        @column.ColumnData::String(data) => {
          let buf = fill_buffer(data, valid, v)
          { name: self.name, storage: @column.BuiltinColumn::from_strings(buf) }
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            "fill_null type String does not match column type " + dt.to_string(),
          )
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
) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.cast(target) }
}

///|
/// Convenience: cast to `Int`. See `BuiltinColumn::to_int` for the
/// per-source-dtype semantics (truncation, range-rejection, parse
/// strictness).
pub fn Series::to_int(self : Series) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.to_int() }
}

///|
/// Convenience: cast to `Float`.
pub fn Series::to_float(self : Series) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.to_float() }
}

///|
/// Convenience: cast to `String`. The output series keeps the same
/// name. Total — `BuiltinColumn::to_string_column` never fails (every
/// dtype has a value-form rendering), unlike `to_int` / `to_float`.
pub fn Series::to_string_series(self : Series) -> Series {
  { name: self.name, storage: self.storage.to_string_column() }
}
