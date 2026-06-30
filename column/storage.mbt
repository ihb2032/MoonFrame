///|
/// Pluggable column-storage seam. `ColumnStorage` is the closed enum a
/// `Series` holds instead of a bare `BuiltinColumn` (the v0.3 core breaking
/// change, wired in S3): one arm per backend, each forwarding the shared
/// accessor surface to the column it wraps.
///
/// The design discipline is **transparent forwarding**: every accessor here
/// matches both arms and delegates to the identically-named method on the
/// underlying column, so the call sites that read a column through
/// `.storage().data()` / `.storage().validity()` (in `drop_nulls` /
/// `group_by` / `join` / `sort`) keep compiling verbatim once
/// `Series::storage()` flips its return type. The `Numeric` arm has no
/// stored bitmap, so `validity()` synthesises an all-valid one on demand
/// (`Bitmap::all_valid(len)`) — the one point the two backends diverge.
///
/// Two shapes of accessor:
///   * **structural / value reads** (`dtype` / `len` / `get` / `slice` /
///     `take` / `*_values` …) forward to both arms; `slice` / `take` keep
///     the backend (a sub-range of an all-valid `Numeric` column is itself
///     all-valid, so it stays `Numeric` — the fast path survives the
///     transform).
///   * **cross-dtype transforms** (`cast`) route
///     through `to_builtin()` and let `BuiltinColumn` do the work, returning
///     a `Builtin`-backed result rather than re-implementing the whole cast
///     machine on the `Numeric` arm. This keeps `NumericColumn`'s surface
///     lean (the numeric fast path only); a caller that wants the result
///     back on the `Numeric` backend re-converges with `to_numeric()`.
///
/// `to_numeric()` is the convergence direction: an all-valid Int / Float
/// `Builtin` column moves onto `NumericColumn`; a column with nulls or a
/// non-numeric dtype `raise`s rather than silently losing information.

///|
/// Which backend a `ColumnStorage` (or `Series`) currently uses. `ArrowLike`
/// from the original `moonframe.txt` draft is intentionally absent —
/// post-P3.5 `Builtin` *is* the Arrow layout (data + validity bitmap,
/// `1 = valid`), so a separate variant would be an empty shell.
pub(all) enum StorageKind {
  Builtin
  Numeric
} derive(Eq, Debug)

///|
/// A column behind one of the pluggable backends. `Builtin` is the
/// general-purpose Arrow column (any dtype, nullable); `Numeric` is the
/// all-valid unboxed numeric fast path.
pub(all) enum ColumnStorage {
  Builtin(BuiltinColumn)
  Numeric(NumericColumn)
} derive(Debug)

///|
/// Content-based structural equality: two columns are equal when they have the
/// same dtype, the same length, and — cell by cell — the same null-ness and (at
/// the valid cells) the same value, *regardless of backend*. So a `Builtin` and
/// a `Numeric` column holding the same all-valid Int / Float data compare
/// equal, where a backend-tag-sensitive `derive(Eq)` reported two logically
/// identical columns unequal merely because one took the `Numeric` fast path
/// and the other did not (`gather` vs `slice`, `from_ints` vs an all-`Some`
/// `from_int_options`, …). This drives `Series` and `DataFrame` equality (both
/// `derive(Eq)` over their fields, reaching here), so `df.head(2) ==
/// df.filter(...)` reflects content, not representation. A valid `NaN` cell
/// still makes a column unequal to an identical one (`NaN != NaN`, matching
/// `Double` equality); only null-ness and equal values decide the rest.
pub impl Eq for ColumnStorage with fn equal(self, other) {
  if self.len() != other.len() {
    return false
  }
  let av = self.validity().to_bools()
  let bv = other.validity().to_bools()
  match (self.data(), other.data()) {
    (ColumnData::Int(a), ColumnData::Int(b)) =>
      storage_cells_equal(a, b, av, bv, (x, y) => x == y)
    (ColumnData::Float(a), ColumnData::Float(b)) =>
      storage_cells_equal(a, b, av, bv, (x, y) => x == y)
    (ColumnData::Bool(a), ColumnData::Bool(b)) =>
      storage_cells_equal(a, b, av, bv, (x, y) => x == y)
    (ColumnData::String(a), ColumnData::String(b)) =>
      storage_cells_equal(a, b, av, bv, (x, y) => x == y)
    // Different dtypes (different `ColumnData` variants) are never equal.
    _ => false
  }
}

///|
/// Per-cell equality for `ColumnStorage::equal`: parallel value arrays `a` /
/// `b` (equal length by the caller's check) and their validity `av` / `bv`. A
/// cell pair is equal when both are null, or both valid with `eq`-equal values;
/// a valid-vs-null pair is unequal. `eq` is the dtype's value comparison, so
/// `Float` keeps `NaN != NaN`.
fn[T] storage_cells_equal(
  a : Array[T],
  b : Array[T],
  av : Array[Bool],
  bv : Array[Bool],
  eq : (T, T) -> Bool,
) -> Bool {
  for i in 0..<a.length() {
    if av[i] != bv[i] {
      return false
    }
    if av[i] && !eq(a[i], b[i]) {
      return false
    }
  }
  true
}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Wrap a `BuiltinColumn` (any dtype, possibly nullable).
pub fn ColumnStorage::from_builtin(column : BuiltinColumn) -> ColumnStorage {
  Builtin(column)
}

///|
/// Wrap an all-valid `NumericColumn`.
pub fn ColumnStorage::from_numeric(column : NumericColumn) -> ColumnStorage {
  Numeric(column)
}

// ── Inspection (transparent forwarding, both arms) ────────────────────

///|
/// Which backend is in use — the discriminant `Series::storage_kind`
/// surfaces (S3).
pub fn ColumnStorage::kind(self : ColumnStorage) -> StorageKind {
  match self {
    Builtin(_) => StorageKind::Builtin
    Numeric(_) => StorageKind::Numeric
  }
}

///|
/// The column's logical `DataType`, forwarded to the active backend.
pub fn ColumnStorage::dtype(self : ColumnStorage) -> @types.DataType {
  match self {
    Builtin(c) => c.dtype()
    Numeric(c) => c.dtype()
  }
}

///|
/// Number of cells, forwarded to the active backend.
pub fn ColumnStorage::len(self : ColumnStorage) -> Int {
  match self {
    Builtin(c) => c.len()
    Numeric(c) => c.len()
  }
}

///|
/// `true` when the column has no cells.
pub fn ColumnStorage::is_empty(self : ColumnStorage) -> Bool {
  match self {
    Builtin(c) => c.is_empty()
    Numeric(c) => c.is_empty()
  }
}

///|
/// Number of null cells — always `0` on the `Numeric` arm — forwarded to the
/// active backend.
pub fn ColumnStorage::null_count(self : ColumnStorage) -> Int {
  match self {
    Builtin(c) => c.null_count()
    Numeric(c) => c.null_count()
  }
}

///|
/// The raw backing storage, discriminated by dtype. Forwarded so the
/// `col.storage().data()` reads in `group_by` / `join` / `sort` keep
/// compiling unchanged after the `Series.storage` flip.
///
/// This returns the column's *live* backing array (no copy), and `ColumnData`
/// is `pub(all)` so the engine can `match` it across packages. Treat the array
/// as read-only: mutating it in place would corrupt the column (and any other
/// column that shares the buffer through zero-copy conversion such as
/// `to_numeric`). Columns are logically immutable; this accessor exists for
/// reading, not editing.
pub fn ColumnStorage::data(self : ColumnStorage) -> ColumnData {
  match self {
    Builtin(c) => c.data()
    Numeric(c) => c.data()
  }
}

///|
/// The validity bitmap (`1 = valid`). The `Numeric` arm has no stored
/// bitmap, so it synthesises an all-valid one sized to the column — the one
/// point the two backends diverge. Forwarded so the
/// `col.storage().validity().to_bools()` reads in `drop_nulls` / `group_by`
/// / `join` / `sort` keep compiling unchanged after the flip.
pub fn ColumnStorage::validity(self : ColumnStorage) -> Bitmap {
  match self {
    Builtin(c) => c.validity()
    Numeric(c) => Bitmap::all_valid(c.len())
  }
}

// ── Cell access ───────────────────────────────────────────────────────

///|
/// Whether cell `index` is null. Out-of-bounds index `raise
/// IndexOutOfBounds`. The `Numeric` arm is structurally always valid (its
/// `is_null` only does the bounds check), so the two backends agree on the
/// diagnostic.
pub fn ColumnStorage::is_null(
  self : ColumnStorage,
  index : Int,
) -> Bool raise @types.DataError {
  match self {
    Builtin(c) => c.is_null(index)
    Numeric(c) => c.is_null(index)
  }
}

///|
/// Read a single cell as a `Scalar`. Out-of-bounds index
/// `raise IndexOutOfBounds`.
pub fn ColumnStorage::get(
  self : ColumnStorage,
  index : Int,
) -> @types.Scalar raise @types.DataError {
  match self {
    Builtin(c) => c.get(index)
    Numeric(c) => c.get(index)
  }
}

// ── Sub-views (backend-preserving) ────────────────────────────────────

///|
/// Half-open `[start, end)` slice, keeping the backend: a sub-range of an
/// all-valid `Numeric` column is itself all-valid, so it stays `Numeric`
/// (no bitmap to repack). Bounds diagnostics match `BuiltinColumn::slice` /
/// `NumericColumn::slice`.
pub fn ColumnStorage::slice(
  self : ColumnStorage,
  start : Int,
  end : Int,
) -> ColumnStorage raise @types.DataError {
  match self {
    Builtin(c) => Builtin(c.slice(start, end))
    Numeric(c) => Numeric(c.slice(start, end))
  }
}

///|
/// Total `[start, end)` slice — the no-raise counterpart of `slice`. Keeps
/// the backend and shares the validity buffer (zero-copy view) on the
/// `Builtin` arm, exactly as `slice` does, but out-of-range bounds are
/// clamped into `[0, len]` (with `end` lifted to at least `start`) so it is
/// genuinely total: it never raises and never aborts on a stray index. This
/// is the single slice path behind the total row transforms `head` / `tail`
/// / `DataFrame::slice`, which validate their window once against `nrows`
/// before slicing each column — so the clamp is a no-op for them, while
/// keeping this public entry abort-free for any other caller
/// (`feedback_lib_no_abort`).
pub fn ColumnStorage::slice_total(
  self : ColumnStorage,
  start : Int,
  end : Int,
) -> ColumnStorage {
  let len = self.len()
  let s = clamp_bound(start, len)
  let e0 = clamp_bound(end, len)
  let e = if e0 < s { s } else { e0 }
  match self {
    Builtin(c) => Builtin(c.slice_unchecked(s, e))
    Numeric(c) => Numeric(c.slice_unchecked(s, e))
  }
}

///|
/// Clamp an index into `[0, len]` — the valid range for a half-open slice
/// bound. Backs `slice_total`'s total guarantee.
fn clamp_bound(i : Int, len : Int) -> Int {
  if i < 0 {
    0
  } else if i > len {
    len
  } else {
    i
  }
}

///|
/// Gather: output cell `i` is `self[indices[i]]`, keeping the backend (a
/// gather of an all-valid `Numeric` column is still all-valid). Any
/// out-of-bounds index `raise IndexOutOfBounds(idx)`.
pub fn ColumnStorage::take(
  self : ColumnStorage,
  indices : Array[Int],
) -> ColumnStorage raise @types.DataError {
  match self {
    Builtin(c) => Builtin(c.take(indices))
    Numeric(c) => Numeric(c.take(indices))
  }
}

// ── Typed accessors (zero-boxing; forwarded to both arms) ─────────────

///|
/// Raw `Int64` array + validity bitmap (the `Numeric` arm synthesises an
/// all-valid one). `raise TypeMismatch` on a non-`Int` column.
pub fn ColumnStorage::int_values(
  self : ColumnStorage,
) -> (Array[Int64], Bitmap) raise @types.DataError {
  match self {
    Builtin(c) => c.int_values()
    Numeric(c) => c.int_values()
  }
}

///|
/// Like `int_values` but for `Float` columns.
pub fn ColumnStorage::float_values(
  self : ColumnStorage,
) -> (Array[Double], Bitmap) raise @types.DataError {
  match self {
    Builtin(c) => c.float_values()
    Numeric(c) => c.float_values()
  }
}

///|
/// Like `int_values` but for `Bool` columns. A `Numeric` column is never
/// `Bool`, so its arm always `raise TypeMismatch`.
pub fn ColumnStorage::bool_values(
  self : ColumnStorage,
) -> (Array[Bool], Bitmap) raise @types.DataError {
  match self {
    Builtin(c) => c.bool_values()
    Numeric(c) => c.bool_values()
  }
}

///|
/// Like `int_values` but for `String` columns. A `Numeric` column is never
/// `String`, so its arm always `raise TypeMismatch`.
pub fn ColumnStorage::string_values(
  self : ColumnStorage,
) -> (Array[String], Bitmap) raise @types.DataError {
  match self {
    Builtin(c) => c.string_values()
    Numeric(c) => c.string_values()
  }
}

// ── Materialise ───────────────────────────────────────────────────────

///|
/// The column as a `BuiltinColumn` (the general-purpose Arrow backend).
/// Total: a `Builtin` is already one; a `Numeric` widens losslessly via
/// `NumericColumn::to_builtin` (an all-valid bitmap is synthesised). The
/// escape hatch the cross-dtype transforms route through.
pub fn ColumnStorage::to_builtin(self : ColumnStorage) -> BuiltinColumn {
  match self {
    Builtin(c) => c
    Numeric(c) => c.to_builtin()
  }
}

///|
/// Render every cell to its `String` value-form, yielding a `String`
/// `BuiltinColumn`. Total — every dtype has a value-form rendering. The
/// result is non-numeric so it is necessarily a `BuiltinColumn`.
pub fn ColumnStorage::to_string_column(self : ColumnStorage) -> BuiltinColumn {
  match self {
    Builtin(c) => c.to_string_column()
    Numeric(c) => c.to_string_column()
  }
}

// ── Cross-dtype transforms (borrow the Builtin road) ──────────────────

///|
/// Cast to `target` — the single cross-dtype conversion — routing through
/// `to_builtin()` so `BuiltinColumn`'s cast machine is reused rather than
/// duplicated on the `Numeric` arm. The result is `Builtin`-backed;
/// re-converge with `to_numeric()` if a numeric target should land back on
/// the fast path. Supported targets and failure modes match
/// `BuiltinColumn::cast`.
pub fn ColumnStorage::cast(
  self : ColumnStorage,
  target : @types.DataType,
) -> ColumnStorage raise @types.DataError {
  ColumnStorage::from_builtin(self.to_builtin().cast(target))
}

// ── Converge onto the Numeric backend ─────────────────────────────────

///|
/// Move an all-valid Int / Float column onto the `Numeric` fast-path
/// backend. An already-`Numeric` column is returned as-is. A `Builtin`
/// column converts only when it can do so without loss:
/// - `raise InvalidOperation` when it carries any null (a `NumericColumn`
///   has no validity bitmap, so nulls cannot be represented);
/// - `raise TypeMismatch` when its dtype is `Bool` / `String` (the fast
///   path is numeric-only).
///
/// The null-free Int / Float arms reuse the raw data array (it is the true
/// data, every slot being valid), so the move allocates no new buffer.
pub fn ColumnStorage::to_numeric(
  self : ColumnStorage,
) -> ColumnStorage raise @types.DataError {
  match self {
    Numeric(_) => self
    Builtin(c) => {
      let nulls = c.null_count()
      if nulls > 0 {
        raise @types.DataError::InvalidOperation(
          "cannot convert a column with nulls to Numeric (null_count=\{nulls})",
        )
      } else {
        match c.data() {
          // Reuse the raw data array (the source column owns it and is
          // immutable) rather than `from_int64s` / `from_doubles`, which now
          // defensively copy — keeping the move buffer-free as documented.
          ColumnData::Int(a) => Numeric({ data: NumericData::Int(a) })
          ColumnData::Float(a) => Numeric({ data: NumericData::Float(a) })
          _ =>
            raise @types.DataError::TypeMismatch(
              "cannot convert a \{c.dtype()} column to Numeric (only Int / Float)",
            )
        }
      }
    }
  }
}
