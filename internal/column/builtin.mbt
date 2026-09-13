///|
/// Apache Arrow style columnar storage used by `Series`.
///
/// The column splits values from validity. `data` is a typed array of raw
/// values (no `Option` boxing); `validity` is a bit-packed `Bitmap` where
/// `1 = valid, 0 = null`, matching Arrow's binary layout. Null slots in
/// `data` carry a per-dtype placeholder (`Int = 0`, `Float = 0.0`,
/// `Bool = false`, `String = ""`). The cell-at-a-time API consults `validity`
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
/// seam (see `storage.mbt`) — a `Series` simply holds one of the two backends
/// behind it, and reaches this one through `ColumnStorage`.
///
/// Numeric columns are 64-bit: the `Int` variant stores `Int64` and the
/// `Float` variant stores `Double`, matching `Scalar`'s payloads and the
/// pandas / polars `int64` / `float64` defaults so reductions neither
/// silently overflow nor lose precision.
pub struct BuiltinColumn {
  priv data : ColumnData
  priv validity : Bitmap
} derive(Debug)

///|

///|
pub extend BuiltinColumn with Debug::{to_repr}

///|
/// Backing storage discriminated by dtype. The element type is the raw
/// value; nullability is tracked in the enclosing column's `validity`
/// bitmap.
pub(all) enum ColumnData {
  Int(ArrayView[Int64])
  Float(ArrayView[Double])
  Bool(ArrayView[Bool])
  String(ArrayView[String])
} derive(Debug)

///|

///|
pub extend ColumnData with Debug::{to_repr}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build an `Int` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_ints(values : Array[Int64]) -> BuiltinColumn {
  { data: Int(values.copy()), validity: Bitmap::all_valid(values.length()), }
}

///|
/// Build an `Int` column where `None` entries are nulls. `None` slots
/// receive `0` as the data placeholder; public APIs never expose it.
pub fn BuiltinColumn::from_int_options(values : Array[Int64?]) -> BuiltinColumn {
  {
    data: Int(values.map(v => v.unwrap_or(0))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `Float` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_floats(values : Array[Double]) -> BuiltinColumn {
  { data: Float(values.copy()), validity: Bitmap::all_valid(values.length()), }
}

///|
/// Build a `Float` column where `None` entries are nulls. `None` slots
/// receive `0.0` as the data placeholder.
pub fn BuiltinColumn::from_float_options(
  values : Array[Double?],
) -> BuiltinColumn {
  {
    data: Float(values.map(v => v.unwrap_or(0.0))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `Bool` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_bools(values : Array[Bool]) -> BuiltinColumn {
  { data: Bool(values.copy()), validity: Bitmap::all_valid(values.length()), }
}

///|
/// Build a `Bool` column where `None` entries are nulls. `None` slots
/// receive `false` as the data placeholder.
pub fn BuiltinColumn::from_bool_options(values : Array[Bool?]) -> BuiltinColumn {
  {
    data: Bool(values.map(v => v.unwrap_or(false))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `String` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_strings(values : Array[String]) -> BuiltinColumn {
  { data: String(values.copy()), validity: Bitmap::all_valid(values.length()), }
}

///|
/// Build a `String` column where `None` entries are nulls. `None` slots
/// receive `""` as the data placeholder.
pub fn BuiltinColumn::from_string_options(
  values : Array[String?],
) -> BuiltinColumn {
  {
    data: String(values.map(v => v.unwrap_or(""))),
    validity: Bitmap::from_options(values),
  }
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// The column's logical `DataType`, read from the `data` arm.
fn BuiltinColumn::dtype(self : BuiltinColumn) -> @types.DataType {
  match self.data {
    Int(_) => @types.DataType::Int
    Float(_) => @types.DataType::Float
    Bool(_) => @types.DataType::Bool
    String(_) => @types.DataType::String
  }
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
fn BuiltinColumn::validity(self : BuiltinColumn) -> Bitmap {
  self.validity
}

///|
/// Number of cells.
fn BuiltinColumn::len(self : BuiltinColumn) -> Int {
  match self.data {
    Int(a) => a.length()
    Float(a) => a.length()
    Bool(a) => a.length()
    String(a) => a.length()
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
    match self.data {
      Int(a) => @types.Scalar::Int(a[index])
      Float(a) => @types.Scalar::Float(a[index])
      Bool(a) => @types.Scalar::Bool(a[index])
      String(a) => @types.Scalar::String(a[index])
    }
  }
}

// ── Sub-views ─────────────────────────────────────────────────────────

///|
/// Half-open `[start, end)` slice. Requires `0 <= start <= end <= len`.
///
/// Errors (checked in this order):
/// - `IndexOutOfBounds(start)` when `start < 0`.
/// - `IndexOutOfBounds(end)` when `end` is outside `[0, len]`.
/// - `InvalidOperation("slice start > end: ...")` when `start > end`.
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
    Int(a) => Int(Array::makei(n, i => a[start + i]))
    Float(a) => Float(Array::makei(n, i => a[start + i]))
    Bool(a) => Bool(Array::makei(n, i => a[start + i]))
    String(a) => String(Array::makei(n, i => a[start + i]))
  }
  { data: data_out, validity: self.validity.slice_view(start, n), }
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
    Int(a) => Int(indices.map(i => a[i]))
    Float(a) => Float(indices.map(i => a[i]))
    Bool(a) => Bool(indices.map(i => a[i]))
    String(a) => String(indices.map(i => a[i]))
  }
  // Indices are already validated against the same `len`, so gather the
  // validity bits through the unchecked `take_view` — no second O(n) bounds
  // scan, and no unreachable raise arm.
  { data: data_out, validity: self.validity.take_view(indices), }
}
