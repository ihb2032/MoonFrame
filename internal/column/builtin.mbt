///|
/// Apache Arrow style columnar storage used by `Series`.
///
/// The column splits values from validity. `data` is a typed array of raw
/// values (no `Option` boxing); `validity` is a bit-packed `Bitmap` where
/// `1 = valid, 0 = null`, matching Arrow's binary layout. Null slots in
/// `data` carry a per-dtype placeholder (`I64 = 0`, `F64 = 0.0`,
/// `Bool = false`, `Utf8 = ""`). The cell-at-a-time API consults `validity`
/// first — `get` answers `Null` rather than `0`, and every `Scalar` a caller
/// receives is masked that way — so no placeholder reaches a value the library
/// hands out. The bulk reader does not mask, and cannot: `data()` returns the
/// dense buffer as it is, placeholders included, paired with the validity that
/// says which slots mean anything. Reading one without the other is the
/// mistake it exists to make possible (a vectorized kernel walks both), and
/// `placeholders_normalized` is what
/// asserts the buffer keeps the canonical placeholder at every null slot.
///
/// A `ColumnStorage` abstraction (plus a `NumericColumn` for
/// unboxed-numeric fast paths) sits above this layer at the `Series` backend
/// seam — a `Series` simply holds one of the two backends
/// behind it, and reaches this one through `ColumnStorage`.
///
/// Numeric columns are 64-bit: the `I64` variant stores `Int64` and the
/// `F64` variant stores `Double`, matching `Scalar`'s payloads and the
/// pandas / polars `int64` / `float64` defaults so reductions neither
/// silently overflow nor lose precision.
pub struct BuiltinColumn {
  /// The logical dtype the column carries — the *identity* half of the
  /// column, independent of the `data` variant (the *representation* half):
  /// a `Date` column is `I64`-typed cells under a `Date` dtype, which is the
  /// whole point of the split. Set by every constructor; the invariant
  /// `dtype.physical()` agrees with the `data` variant is constructor-guaranteed.
  priv dtype : @types.DataType
  priv data : ColumnData
  priv validity : @buffer.Bitmap
} derive(Debug)

///|

///|
pub extend BuiltinColumn with Debug::{to_repr}

///|
/// Backing storage discriminated by dtype. The element type is the raw
/// value; nullability is tracked in the enclosing column's `validity`
/// bitmap.
pub(all) enum ColumnData {
  I64(ArrayView[Int64])
  F64(ArrayView[Double])
  Bool(ArrayView[Bool])
  Utf8(@buffer.Utf8Array)
} derive(Debug)

///|

///|
pub extend ColumnData with Debug::{to_repr}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build an `Int` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_ints(values : Array[Int64]) -> BuiltinColumn {
  {
    dtype: @types.DataType::Int,
    data: I64(values.copy()),
    validity: @buffer.Bitmap::all_valid(values.length()),
  }
}

///|
/// Build an `Int` column where `None` entries are nulls. `None` slots
/// receive `0` as the data placeholder; public APIs never expose it.
pub fn BuiltinColumn::from_int_options(values : Array[Int64?]) -> BuiltinColumn {
  {
    dtype: @types.DataType::Int,
    data: I64(values.map(v => v.unwrap_or(0))),
    validity: @buffer.Bitmap::from_options(values),
  }
}

///|
/// Build a `Float` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_floats(values : Array[Double]) -> BuiltinColumn {
  {
    dtype: @types.DataType::Float,
    data: F64(values.copy()),
    validity: @buffer.Bitmap::all_valid(values.length()),
  }
}

///|
/// Build a `Float` column where `None` entries are nulls. `None` slots
/// receive `0.0` as the data placeholder.
pub fn BuiltinColumn::from_float_options(
  values : Array[Double?],
) -> BuiltinColumn {
  {
    dtype: @types.DataType::Float,
    data: F64(values.map(v => v.unwrap_or(0.0))),
    validity: @buffer.Bitmap::from_options(values),
  }
}

///|
/// Build a `Bool` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_bools(values : Array[Bool]) -> BuiltinColumn {
  {
    dtype: @types.DataType::Bool,
    data: Bool(values.copy()),
    validity: @buffer.Bitmap::all_valid(values.length()),
  }
}

///|
/// Build a `Bool` column where `None` entries are nulls. `None` slots
/// receive `false` as the data placeholder.
pub fn BuiltinColumn::from_bool_options(values : Array[Bool?]) -> BuiltinColumn {
  {
    dtype: @types.DataType::Bool,
    data: Bool(values.map(v => v.unwrap_or(false))),
    validity: @buffer.Bitmap::from_options(values),
  }
}

///|
/// Build a `String` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_strings(values : Array[String]) -> BuiltinColumn {
  {
    dtype: @types.DataType::String,
    data: Utf8(@buffer.Utf8Array::from_strings(values)),
    validity: @buffer.Bitmap::all_valid(values.length()),
  }
}

///|
/// Build a `String` column where `None` entries are nulls. `None` slots
/// receive `""` as the data placeholder.
pub fn BuiltinColumn::from_string_options(
  values : Array[String?],
) -> BuiltinColumn {
  {
    dtype: @types.DataType::String,
    data: Utf8(@buffer.Utf8Array::from_string_options(values)),
    validity: @buffer.Bitmap::from_options(values),
  }
}

///|
/// Build a column of an `I64`-riding logical dtype (a dtype whose registry
/// `physical` is `I64`: `Int`, or a date-like dtype such as `Date`) from
/// optional raw cells, `None` entries nulls with the `0` placeholder. `dtype`
/// fixes the column's *identity* — the cells are the same `Int64` buffer for
/// every `I64` rider; what differs is the per-dtype lift in `scalar_of`, which turns a
/// raw cell back into the dtype own `Scalar` on read. The caller must pass a
/// dtype whose physical is `I64` (every caller is a constructor of one
/// specific dtype, so the agreement is by construction).
pub fn BuiltinColumn::from_i64_options(
  dtype : @types.DataType,
  values : Array[Int64?],
) -> BuiltinColumn {
  {
    dtype,
    data: I64(values.map(v => v.unwrap_or(0))),
    validity: @buffer.Bitmap::from_options(values),
  }
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// The column's logical `DataType` — the identity the column was built with,
/// not something derived from the buffer (a `Date` column reads `Date`, though
/// its cells are `I64`-typed).
fn BuiltinColumn::dtype(self : BuiltinColumn) -> @types.DataType {
  self.dtype
}

///|
/// The raw backing storage, discriminated by dtype. `ColumnData` is
/// `pub(all)`, so the consumers that read a column in bulk (`series` and
/// `internal/kernel`, both through `ColumnStorage`) match the concrete element
/// type once and read every value totally, in a single vectorized pass. The
/// element arrays are the column own, shared rather than copied, and
/// read-only by rule — the seam guard refuses an assignment into one.
fn BuiltinColumn::data(self : BuiltinColumn) -> ColumnData {
  self.data
}

///|
/// The validity bitmap (`1 = valid`). Paired with `data` for callers that
/// read every slot in order: `validity().to_bools()` materialises the mask
/// once so a bounded loop indexes it totally, instead of catching a
/// per-slot `is_valid` raise. The bitmap is shared (read-only).
fn BuiltinColumn::validity(self : BuiltinColumn) -> @buffer.Bitmap {
  self.validity
}

///|
/// Number of cells.
fn BuiltinColumn::len(self : BuiltinColumn) -> Int {
  match self.data {
    I64(a) => a.length()
    F64(a) => a.length()
    Bool(a) => a.length()
    Utf8(a) => a.len()
  }
}

///|
/// `true` when the column has no cells.
fn BuiltinColumn::is_empty(self : BuiltinColumn) -> Bool {
  self.len() == 0
}

///|
/// Number of null cells (the count of zero bits in `validity`).
fn BuiltinColumn::null_count(self : BuiltinColumn) -> Int {
  self.validity.null_count()
}

///|
/// `raise IndexOutOfBounds` if `index` is outside `[0, len)`.
fn BuiltinColumn::is_null(
  self : BuiltinColumn,
  index : Int,
) -> Bool raise @types.DataError {
  self.validity.is_null(index)
}

///|
/// Read a single cell as a `Scalar`. Out-of-bounds index
/// `raise IndexOutOfBounds`.
fn BuiltinColumn::get(
  self : BuiltinColumn,
  index : Int,
) -> @types.Scalar raise @types.DataError {
  if self.validity.is_null(index) {
    @types.Scalar::Null
  } else {
    scalar_of(self.dtype, self.data, index)
  }
}

///|
/// Lift one valid cell of a column's buffer to its logical `Scalar`. The
/// physical variants map to their payload `Scalar`s, except `I64` — the
/// buffer logical dtypes share — where the dtype decides: the registry's
/// riders (`Int` identity, `Date` epoch) lift their own way. This is the one
/// place identity and representation meet on the read side; the write half is
/// `from_i64_options`. `index` must address a valid (present) slot — callers
/// check validity first, so no null placeholder can leak out as a value.
pub fn scalar_of(
  dtype : @types.DataType,
  data : ColumnData,
  index : Int,
) -> @types.Scalar {
  match data {
    I64(a) =>
      if dtype is @types.DataType::Date {
        @types.Scalar::Date(a[index])
      } else {
        @types.Scalar::Int(a[index])
      }
    F64(a) => @types.Scalar::Float(a[index])
    Bool(a) => @types.Scalar::Bool(a[index])
    Utf8(a) => @types.Scalar::String(a.get(index))
  }
}

// ── Sub-views ─────────────────────────────────────────────────────────

///|
/// Half-open `[start, end)` slice. Requires `0 <= start <= end <= len`.
///
/// Errors (checked in this order):
/// - `IndexOutOfBounds(start)` when `start < 0`.
/// - `IndexOutOfBounds(end)` when `end` is outside `[0, len]`.
/// - `InvalidOperation("slice start > end: .")` when `start > end`.
///
/// `start > len` is not a separate case: it can only occur together with
/// `end > len` (→ `IndexOutOfBounds(end)`) or `start > end`
/// (→ `InvalidOperation`), both already rejected above.
fn BuiltinColumn::slice(
  self : BuiltinColumn,
  start : Int,
  end : Int,
) -> BuiltinColumn raise @types.DataError {
  validate_slice_bounds(start, end, self.len())
  self.slice_unchecked(start, end)
}

///|
/// Total `[start, end)` slice — the shared core behind `slice` (which
/// validates the bounds then calls this). Copies the row data and takes a
/// zero-copy validity view (`Bitmap::slice_view`). The caller must guarantee
/// `0 <= start <= end <= len`; `slice` enforces that, and `ColumnStorage`'s
/// total `slice_total` clamps before delegating, so this never reads out of
/// bounds.
fn BuiltinColumn::slice_unchecked(
  self : BuiltinColumn,
  start : Int,
  end : Int,
) -> BuiltinColumn {
  let n = end - start
  let data_out : ColumnData = match self.data {
    I64(a) => I64(Array::makei(n, i => a[start + i]))
    F64(a) => F64(Array::makei(n, i => a[start + i]))
    Bool(a) => Bool(Array::makei(n, i => a[start + i]))
    Utf8(a) => Utf8(a.slice_view(start, n))
  }
  {
    dtype: self.dtype,
    data: data_out,
    validity: self.validity.slice_view(start, n),
  }
}

///|
/// Gather: produce a new column whose i-th entry is `self[indices[i]]`.
/// Any out-of-bounds index `raise IndexOutOfBounds(idx)`.
fn BuiltinColumn::take(
  self : BuiltinColumn,
  indices : Array[Int],
) -> BuiltinColumn raise @types.DataError {
  validate_gather_indices(indices, self.len())
  let data_out : ColumnData = match self.data {
    I64(a) => I64(indices.map(i => a[i]))
    F64(a) => F64(indices.map(i => a[i]))
    Bool(a) => Bool(indices.map(i => a[i]))
    Utf8(a) => Utf8(a.take_view(indices))
  }
  // Indices are already validated against the same `len`, so gather the
  // validity bits through the unchecked `take_view` — no second O(n) bounds
  // scan, and no unreachable raise arm.
  {
    dtype: self.dtype,
    data: data_out,
    validity: self.validity.take_view(indices),
  }
}
