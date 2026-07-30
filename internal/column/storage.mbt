///|
/// Pluggable column-storage seam. `ColumnStorage` is the closed enum a
/// `Series` holds instead of a bare `BuiltinColumn`: one arm per backend,
/// each forwarding the shared
/// accessor surface to the column it wraps.
///
/// The design discipline is **transparent forwarding**: every accessor here
/// matches both arms and delegates to the identically-named method on the
/// underlying column, so a caller reads a column the same way whichever
/// backend it sits on. Who those callers are is a layering rule rather than a
/// list: `ColumnStorage` is consumed directly by `series` and
/// `internal/kernel` only, and every package above them reaches column
/// capability through engine seams that return a `Series`, a scalar, or a
/// freshly built array — never this buffer. The `Numeric` arm has no stored
/// bitmap, so `validity()` synthesises an all-valid one on demand
/// (`Bitmap::all_valid(len)`) — the one point the two backends diverge.
///
/// Two shapes of accessor:
///   * **structural / value reads** (`dtype` / `len` / `get` / `slice` /
///     `take` / `data` / `validity` …) forward to both arms; `slice` / `take` keep
///     the backend (a sub-range of an all-valid `Numeric` column is itself
///     all-valid, so it stays `Numeric` — the fast path survives the
///     transform).
///   * **cross-dtype transforms** (`cast`) widen to the `Builtin` backend
///     first, package-privately, and let `BuiltinColumn` do the work rather
///     than re-implementing the whole cast machine on the `Numeric` arm. This
///     keeps `NumericColumn`'s surface lean (the numeric fast path only), and
///     the result comes back `Builtin`-backed.
///
/// Convergence runs the other way and lives above this package:
/// `@series.try_column_to_numeric` moves an all-valid Int / Float column onto
/// `NumericColumn` and leaves every other column as it is. Nothing here
/// selects a backend for a caller — a column's backend follows its content.

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
pub extend StorageKind with Eq::{equal, not_equal}

///|
pub extend StorageKind with Debug::{to_repr}

///|
/// A column behind one of the pluggable backends. `Builtin` is the
/// general-purpose Arrow column (any dtype, nullable); `Numeric` is the
/// all-valid unboxed numeric fast path.
pub(all) enum ColumnStorage {
  Builtin(BuiltinColumn)
  Numeric(NumericColumn)
} derive(Debug)

///|
pub extend ColumnStorage with Eq::{equal, not_equal}

///|
pub extend ColumnStorage with Debug::{to_repr}

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
    // Spelled variant-by-variant (no wildcard) so a future `ColumnData`
    // variant fails compilation here instead of silently comparing unequal
    // to every column — itself included.
    (
      ColumnData::Int(_),
      ColumnData::Float(_)
      | ColumnData::Bool(_)
      | ColumnData::String(_),
    )
    | (
      ColumnData::Float(_),
      ColumnData::Int(_)
      | ColumnData::Bool(_)
      | ColumnData::String(_),
    )
    | (
      ColumnData::Bool(_),
      ColumnData::Int(_)
      | ColumnData::Float(_)
      | ColumnData::String(_),
    )
    | (
      ColumnData::String(_),
      ColumnData::Int(_)
      | ColumnData::Float(_)
      | ColumnData::Bool(_),
    ) => false
  }
}

///|
/// Per-cell equality for `ColumnStorage::equal`: parallel value arrays `a` /
/// `b` (equal length by the caller's check) and their validity `av` / `bv`. A
/// cell pair is equal when both are null, or both valid with `eq`-equal values;
/// a valid-vs-null pair is unequal. `eq` is the dtype's value comparison, so
/// `Float` keeps `NaN != NaN`.
fn[T] storage_cells_equal(
  a : ArrayView[T],
  b : ArrayView[T],
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
/// The raw backing storage, discriminated by dtype, forwarded to whichever
/// backend the column is on. The bulk read behind the vectorized kernels:
/// `internal/kernel` matches this to walk a column's cells without boxing one
/// `Scalar` per row. It is not a read for the verb layer — `frame` reaches a
/// column through `Series`, and the layering guard refuses the import that
/// would let it do otherwise.
///
/// This hands out the column's *live* buffer with no copy, as an
/// `ArrayView` — readable and indexable, but with no `op_set` and none of
/// `Array`'s in-place methods, so a consumer cannot write through it. That is
/// the point: a column is logically immutable and buffers are shared by
/// zero-copy slicing, so one index assignment would corrupt this column and
/// every column sharing the buffer, with no signature or import changing to
/// show it. The view makes that a compile error rather than a convention.
/// `ColumnData` stays `pub(all)` so the engine can `match` it across packages.
pub fn ColumnStorage::data(self : ColumnStorage) -> ColumnData {
  match self {
    Builtin(c) => c.data()
    Numeric(c) => c.data()
  }
}

///|
/// The validity bitmap (`1 = valid`). The `Numeric` arm has no stored
/// bitmap, so it synthesises an all-valid one sized to the column — the one
/// point the two backends diverge. The other half of the bulk read: `data()`
/// hands back a dense buffer whose null slots hold a placeholder, and this
/// says which slots those are.
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
/// is the single slice path behind the total `head` / `tail` and behind the
/// per-column half of `DataFrame::slice` — which is itself fallible, but
/// validates its window against `nrows` once before reaching here, as
/// `head` / `tail` clamp theirs — so the clamp is a no-op for all three, while
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

// ── Materialise ───────────────────────────────────────────────────────

///|
/// The column as a `BuiltinColumn` (the general-purpose Arrow backend).
/// Total: a `Builtin` is already one; a `Numeric` widens losslessly via
/// `NumericColumn::to_builtin` (an all-valid bitmap is synthesised). The
/// escape hatch the cross-dtype transforms route through.
fn ColumnStorage::to_builtin(self : ColumnStorage) -> BuiltinColumn {
  match self {
    Builtin(c) => c
    Numeric(c) => c.to_builtin()
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
  ColumnStorage::Builtin(self.to_builtin().cast(target))
}

// ── Converge onto the Numeric backend ─────────────────────────────────
