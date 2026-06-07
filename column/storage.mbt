///|
/// Pluggable column-storage seam. `ColumnStorage` is the closed enum a
/// `Series` will hold instead of a bare `BuiltinColumn` (the v0.3 core
/// breaking change, landed in S3): one arm per backend, each forwarding the
/// shared accessor surface to the column it wraps.
///
/// The design discipline is **transparent forwarding**: every accessor here
/// matches both arms and delegates to the identically-named method on the
/// underlying column, so the call sites that read a column through
/// `.storage().data()` / `.storage().validity()` keep compiling verbatim
/// when `Series::storage()` flips its return type. The `Numeric` arm has no
/// stored bitmap, so `validity()` synthesises an all-valid one on demand
/// (`Bitmap::all_valid(len)`) — the only place the two backends diverge.
///
/// ── S0 spike scope ─────────────────────────────────────────────────────
/// This is the Stage 2 spike (`PLAN_v0.3.md` §3 S0): the minimal accessor
/// slice needed to validate, before the `Series.storage` flip, that (1) a
/// closed `{ Builtin; Numeric }` enum's `match` arms are each reachable so
/// coverage stays 100% with no dead arm, and (2) the `data()` / `validity()`
/// forwarders the four ops files (`drop_nulls` / `group_by` / `join` /
/// `sort`) actually call are signature-identical to `BuiltinColumn`'s. S2
/// extends this with the full surface (`slice` / `take` / `cast` / `to_int`
/// / `to_float` / `*_values` / `to_builtin` / `to_string_column` /
/// `to_numeric`). Folds forward additively.

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
} derive(Eq, Debug)

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
/// Which backend is in use — the discriminant `Series::storage_kind` will
/// surface (S3).
pub fn ColumnStorage::kind(self : ColumnStorage) -> StorageKind {
  match self {
    Builtin(_) => StorageKind::Builtin
    Numeric(_) => StorageKind::Numeric
  }
}

///|
pub fn ColumnStorage::dtype(self : ColumnStorage) -> @types.DataType {
  match self {
    Builtin(c) => c.dtype()
    Numeric(c) => c.dtype()
  }
}

///|
pub fn ColumnStorage::len(self : ColumnStorage) -> Int {
  match self {
    Builtin(c) => c.len()
    Numeric(c) => c.len()
  }
}

///|
pub fn ColumnStorage::is_empty(self : ColumnStorage) -> Bool {
  match self {
    Builtin(c) => c.is_empty()
    Numeric(c) => c.is_empty()
  }
}

///|
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
