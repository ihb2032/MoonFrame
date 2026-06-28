///|
/// A one-dimensional, dtype-aware column with a name. `Series` is the
/// per-column unit behind `DataFrame`: it bundles a `ColumnStorage` (the
/// pluggable backend seam — `Builtin` Arrow storage with an explicit
/// validity bitmap, or the all-valid unboxed `Numeric` fast path) with a
/// column name, and exposes the structural, nullability, transform, and
/// cast surface that ops / IO layers rely on. Statistics live in
/// `series_stats.mbt`.
///
/// The `storage` field is a `ColumnStorage` as of v0.3 (it was a bare
/// `BuiltinColumn` through v0.2). Every accessor forwards to the
/// identically-named `ColumnStorage` method, so the backend is transparent
/// to readers — `storage_kind` / `to_numeric` / `to_builtin` are the only
/// surface that observes or chooses it.
///
/// The struct is read-only from outside this package — always go
/// through the named constructors so the underlying column maintains
/// its data-and-validity invariants.
pub struct Series {
  name : String
  storage : @column.ColumnStorage
} derive(Eq, Debug)

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Wrap an existing `ColumnStorage` under the given name — the canonical
/// constructor at the backend seam. The backend (and validity / null-count)
/// is whatever the storage already carries. Callers holding a
/// `BuiltinColumn` use `from_builtin` instead.
pub fn Series::new(name : String, storage : @column.ColumnStorage) -> Series {
  { name, storage }
}

///|
/// Wrap an existing `BuiltinColumn` under the given name, behind a
/// `ColumnStorage::Builtin`. The source-compatible path for callers that
/// already hold a `BuiltinColumn` (the v0.2 `new` signature).
pub fn Series::from_builtin(
  name : String,
  storage : @column.BuiltinColumn,
) -> Series {
  { name, storage: @column.ColumnStorage::from_builtin(storage) }
}

///|
/// Build an `Int` series from raw values (no nulls). Lands on the `Numeric`
/// fast-path backend — no validity bitmap is allocated.
///
/// `values` is defensively copied, so a `Series` is independent of the
/// caller's array: mutating `values` afterwards does not change the series'
/// cells. (The nullable constructors `from_*_options` likewise copy while
/// boxing into `Option`.)
pub fn Series::from_ints(name : String, values : Array[Int64]) -> Series {
  Series::new(
    name,
    @column.ColumnStorage::from_numeric(
      @column.NumericColumn::from_int64s(values),
    ),
  )
}

///|
/// Build an `Int` series where `None` entries are nulls. Nullable, so it
/// lands on the general-purpose `Builtin` backend.
pub fn Series::from_int_options(
  name : String,
  values : Array[Int64?],
) -> Series {
  Series::from_builtin(name, @column.BuiltinColumn::from_int_options(values))
}

///|
/// Build a `Float` series from raw values (no nulls). Lands on the
/// `Numeric` fast-path backend. Like `from_ints`, `values` is defensively
/// copied, so the series is independent of the caller's array.
pub fn Series::from_floats(name : String, values : Array[Double]) -> Series {
  Series::new(
    name,
    @column.ColumnStorage::from_numeric(
      @column.NumericColumn::from_doubles(values),
    ),
  )
}

///|
/// Build a `Float` series where `None` entries are nulls. Nullable, so it
/// lands on the `Builtin` backend.
pub fn Series::from_float_options(
  name : String,
  values : Array[Double?],
) -> Series {
  Series::from_builtin(name, @column.BuiltinColumn::from_float_options(values))
}

///|
/// Build a `Bool` series from raw values (no nulls). `Bool` is non-numeric,
/// so it lands on the `Builtin` backend. `values` is defensively copied, so
/// the series is independent of the caller's array.
pub fn Series::from_bools(name : String, values : Array[Bool]) -> Series {
  Series::from_builtin(name, @column.BuiltinColumn::from_bools(values))
}

///|
/// Build a `Bool` series where `None` entries are nulls.
pub fn Series::from_bool_options(
  name : String,
  values : Array[Bool?],
) -> Series {
  Series::from_builtin(name, @column.BuiltinColumn::from_bool_options(values))
}

///|
/// Build a `String` series from raw values (no nulls). `String` is
/// non-numeric, so it lands on the `Builtin` backend. `values` is defensively
/// copied, so the series is independent of the caller's array.
pub fn Series::from_strings(name : String, values : Array[String]) -> Series {
  Series::from_builtin(name, @column.BuiltinColumn::from_strings(values))
}

///|
/// Build a `String` series where `None` entries are nulls.
pub fn Series::from_string_options(
  name : String,
  values : Array[String?],
) -> Series {
  Series::from_builtin(name, @column.BuiltinColumn::from_string_options(values))
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
  let valid = validity_bools(self.storage)
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
/// Expose the underlying `ColumnStorage`. Ops layers use this to reach the
/// typed (`int_values` / `float_values` / ...) accessors and the
/// `data()` / `validity()` reads, bypassing `Scalar` boxing. The return
/// type changed from `BuiltinColumn` to `ColumnStorage` in v0.3; the
/// `data()` / `validity()` surface is identical, so column-reading call
/// sites are unaffected.
pub fn Series::storage(self : Series) -> @column.ColumnStorage {
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
/// Out-of-bounds indices surface as `IndexOutOfBounds(idx)`. The result is
/// canonicalised onto the `Numeric` fast path when the gathered rows leave an
/// Int / Float column all-valid (the same invariant `gather_series` keeps), so
/// the backend is a function of the gathered content, not the source.
pub fn Series::gather(
  self : Series,
  indices : Array[Int],
) -> Series raise @types.DataError {
  try_column_to_numeric({ name: self.name, storage: self.storage.take(indices) })
}

///|
/// Best-effort, **total** move of one column onto the `Numeric` fast-path
/// backend: an all-valid Int / Float `Builtin` column is rebuilt on
/// `NumericColumn`; every other column — already `Numeric`, carrying nulls,
/// or non-numeric — is returned unchanged. Unlike `Series::to_numeric` this
/// never raises: it is the per-column step behind the total
/// `DataFrame::to_numeric`, the canonicalisation in the row gathers
/// (`gather_series` / `Series::gather` / `rebuild_options`) and
/// `preserve_backend`, and the expression engine's computed-column convergence,
/// so a column that cannot move is simply kept rather than failing (and rather
/// than leaving a dead error arm, `feedback_lib_no_abort`). The null-free Int /
/// Float arms reuse the raw data array — every slot being valid, it is the true
/// data.
pub fn try_column_to_numeric(s : Series) -> Series {
  match s.storage.kind() {
    @column.StorageKind::Numeric => s
    @column.StorageKind::Builtin =>
      if s.storage.null_count() > 0 {
        s
      } else {
        match s.storage.data() {
          @column.ColumnData::Int(a) =>
            Series::new(
              s.name,
              @column.ColumnStorage::from_numeric(
                @column.NumericColumn::from_int64s(a),
              ),
            )
          @column.ColumnData::Float(a) =>
            Series::new(
              s.name,
              @column.ColumnStorage::from_numeric(
                @column.NumericColumn::from_doubles(a),
              ),
            )
          _ => s
        }
      }
  }
}

///|
/// Re-converge a freshly rebuilt (`Builtin`-backed) column to `source`'s
/// backend: a `Numeric` source's all-valid rebuild moves back onto the
/// `Numeric` fast path, a `Builtin` source's stays `Builtin`. The
/// backend-*preserving* re-convergence, kept for the transforms that must hold
/// their source backend rather than canonicalise — `fill_null` (whose filled
/// column is built straight on `Builtin`). The row gathers (`gather_series` /
/// `Series::gather`) and `rebuild_options` now **canonicalise** instead (an
/// all-valid numeric result lands on `Numeric` whatever its source held), so a
/// caller wrapping a `rebuild_options` result here — the join assembly — gets a
/// no-op passthrough; the slices (`slice_series`) preserve the backend by
/// sharing the validity bitmap (the row data is copied), never reaching here.
pub fn preserve_backend(source : Series, rebuilt : Series) -> Series {
  match source.storage.kind() {
    @column.StorageKind::Numeric => try_column_to_numeric(rebuilt)
    @column.StorageKind::Builtin => rebuilt
  }
}

///|
/// Materialise a column's validity as a dense `Array[Bool]` (`true = valid`)
/// for a bounded scan. The `Numeric` arm builds the all-`true` array
/// directly, skipping the synthetic all-valid `Bitmap` that
/// `ColumnStorage::validity()` would allocate for a backend that has none —
/// a `Numeric` column is present in every slot by construction. Equivalent
/// to `storage.validity().to_bools()` but without the intermediate bitmap on
/// the fast path. The row-level scanners (`sort` / `group_by` / `join` /
/// `drop_nulls`) and the elementwise expression kernels (`expr_eval`,
/// whose operands are frequently `Numeric`) read the mask by plain index, so
/// they share this instead of each repacking a throwaway bitmap for a
/// `Numeric` column.
pub fn validity_bools(storage : @column.ColumnStorage) -> Array[Bool] {
  match storage.kind() {
    @column.StorageKind::Numeric => Array::make(storage.len(), true)
    @column.StorageKind::Builtin => storage.validity().to_bools()
  }
}

///|
/// Total contiguous slice `[start, start + len)`. Delegates to
/// `ColumnStorage::slice_total`, which keeps the source backend and shares
/// the validity bitmap as a zero-copy view while copying the row data — the
/// single slice path behind `head` / `tail` /
/// `DataFrame::slice` (no rebuild, no `Result`). The caller guarantees
/// `0 <= start` and `start + len <= self.len()`; `slice_total` clamps anyway,
/// so a stray bound can never abort.
pub fn slice_series(s : Series, start : Int, len : Int) -> Series {
  { name: s.name, storage: s.storage.slice_total(start, start + len) }
}

///|
/// Rebuild a column cell-by-cell through the option constructors, dispatching
/// on `source`'s storage variant exactly once. Output cell `k` (for `k` in
/// `0 ..< n`) is produced by the dtype-matching closure applied to `source`'s
/// typed data array — `int_cell` for an `Int` column, `string_cell` for a
/// `String` one, and so on — each returning `Some(v)` for a value or `None`
/// for a null slot.
///
/// This is the single 4-arm `match data() -> from_*_options` skeleton behind
/// `gather_series`' nullable path, `gather_series_opt`, and `coalesce_into`:
/// the per-caller cell logic is all that differs between them, so it is all
/// each caller supplies. The `match` stays exhaustive over the four dtypes —
/// every arm is the live path for a column of that dtype, so none is dead.
///
/// The rebuilt column is **canonicalised** (`try_column_to_numeric`): a row /
/// cell selection that leaves an Int / Float column all-valid lands on the
/// `Numeric` fast path, even when its source carried nulls those dropped rows
/// held. This makes a column's backend a function of its *content*, not of how
/// it was produced — the invariant the query optimizer relies on, so that
/// sinking a `Filter` below a stage (recomputing a derived column over the
/// surviving rows) cannot flip its backend from `Builtin` to `Numeric` and
/// make `collect` diverge from the eager chain that `Series` equality observes.
pub fn rebuild_options(
  source : Series,
  name : String,
  n : Int,
  int_cell : (Array[Int64], Int) -> Int64?,
  float_cell : (Array[Double], Int) -> Double?,
  bool_cell : (Array[Bool], Int) -> Bool?,
  string_cell : (Array[String], Int) -> String?,
) -> Series {
  let rebuilt = match source.storage.data() {
    @column.ColumnData::Int(a) =>
      Series::from_int_options(name, Array::makei(n, k => int_cell(a, k)))
    @column.ColumnData::Float(a) =>
      Series::from_float_options(name, Array::makei(n, k => float_cell(a, k)))
    @column.ColumnData::Bool(a) =>
      Series::from_bool_options(name, Array::makei(n, k => bool_cell(a, k)))
    @column.ColumnData::String(a) =>
      Series::from_string_options(name, Array::makei(n, k => string_cell(a, k)))
  }
  try_column_to_numeric(rebuilt)
}

///|
/// Total gather: position `k` of the result is `s[idx[k]]`. The caller
/// guarantees every index is in `[0, s.len())`. The result is **canonical**: a
/// `Numeric` source rebuilds straight onto the `Numeric` fast path, and a
/// `Builtin` source whose gathered rows leave it all-valid re-converges onto
/// `Numeric` too (via `rebuild_options`), so the backend is a function of the
/// gathered content, not the source — the invariant predicate pushdown relies
/// on. Backs `drop_nulls`, `take`, and the row-gather DataFrame transforms.
pub fn gather_series(s : Series, idx : Array[Int]) -> Series {
  // A `Numeric` source is all-valid and the caller guarantees in-bounds
  // indices, so its gather is itself all-valid: rebuild directly onto the
  // `Numeric` backend, materialising no validity mask and allocating no
  // transient bitmap. A `Numeric` column only ever backs `Int` / `Float`, so
  // the two guarded arms are the whole `Numeric` case (`Bool` / `String` are
  // always `Builtin`). Routing a `Numeric` source through the option
  // constructors instead would round-trip `Numeric` → `Builtin` →
  // `try_column_to_numeric` → `Numeric`, allocating an `Array[T?]` and a
  // `Bitmap` only to drop them on re-convergence. A `Builtin` source (any
  // dtype) falls to the `_` arm and shares the `rebuild_options` skeleton,
  // reading each gathered slot's validity straight off the source bitmap
  // (`is_valid_total`), so the gather costs `O(idx)` rather than materialising
  // the whole `O(source)` mask — a per-group gather in the grouped-aggregation
  // engine touches only its group's rows, keeping a derived reduction linear
  // instead of quadratic on a high-cardinality key.
  let numeric = s.storage.kind() is @column.StorageKind::Numeric
  match s.storage.data() {
    @column.ColumnData::Int(a) if numeric =>
      Series::from_ints(s.name, idx.map(k => a[k]))
    @column.ColumnData::Float(a) if numeric =>
      Series::from_floats(s.name, idx.map(k => a[k]))
    _ => {
      let validity = s.storage.validity()
      rebuild_options(
        s,
        s.name,
        idx.length(),
        (a, k) => {
          if validity.is_valid_total(idx[k]) {
            Some(a[idx[k]])
          } else {
            None
          }
        },
        (a, k) => {
          if validity.is_valid_total(idx[k]) {
            Some(a[idx[k]])
          } else {
            None
          }
        },
        (a, k) => {
          if validity.is_valid_total(idx[k]) {
            Some(a[idx[k]])
          } else {
            None
          }
        },
        (a, k) => {
          if validity.is_valid_total(idx[k]) {
            Some(a[idx[k]])
          } else {
            None
          }
        },
      )
    }
  }
}

///|
/// Drop every null cell. The returned series has `len = original.len -
/// original.null_count` and no null cells left. A source that already has no
/// nulls is returned unchanged — so an all-valid `Numeric` column stays on the
/// fast path (no bitmap to carry); otherwise the kept cells are gathered, and a
/// numeric result — now necessarily all-valid — canonicalises onto `Numeric`
/// (`gather_series`), so dropping nulls cannot leave a numeric column off the
/// fast path.
pub fn Series::drop_nulls(self : Series) -> Series {
  // No nulls → nothing to drop; return `self` instead of gathering every row
  // into an identical rebuild. `null_count` is O(1) for a `Numeric` column
  // (always 0, so it short-circuits here and stays on the fast path) and a
  // bitmap popcount for `Builtin`. Past this guard the column carries a null,
  // so it is necessarily `Builtin` — the mask read below sees a real bitmap.
  if self.storage.null_count() == 0 {
    return self
  }
  // Keep the indices of the valid cells, in order, then gather them —
  // `gather_series` rebuilds the series with a fully-valid bitmap.
  let valid = self.storage.validity().to_bools()
  let kept = Array::makei(valid.length(), i => i).filter(i => valid[i])
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
/// fully-valid bitmap and keeps the source storage backend
/// (`preserve_backend`) — a no-op fill on an all-valid `Numeric` column
/// stays `Numeric`.
pub fn Series::fill_null(
  self : Series,
  value : @types.Scalar,
) -> Series raise @types.DataError {
  let valid = validity_bools(self.storage)
  let filled = match value {
    @types.Scalar::Null =>
      raise @types.DataError::TypeMismatch("cannot fill nulls with Null")
    @types.Scalar::Int(v) =>
      match self.storage.data() {
        @column.ColumnData::Int(data) => {
          let buf = fill_buffer(data, valid, v)
          Series::from_builtin(self.name, @column.BuiltinColumn::from_ints(buf))
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            "fill_null type Int does not match column type \{self.dtype()}",
          )
      }
    @types.Scalar::Float(v) =>
      match self.storage.data() {
        @column.ColumnData::Float(data) => {
          let buf = fill_buffer(data, valid, v)
          Series::from_builtin(
            self.name,
            @column.BuiltinColumn::from_floats(buf),
          )
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            "fill_null type Float does not match column type \{self.dtype()}",
          )
      }
    @types.Scalar::Bool(v) =>
      match self.storage.data() {
        @column.ColumnData::Bool(data) => {
          let buf = fill_buffer(data, valid, v)
          Series::from_builtin(
            self.name,
            @column.BuiltinColumn::from_bools(buf),
          )
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            "fill_null type Bool does not match column type \{self.dtype()}",
          )
      }
    @types.Scalar::String(v) =>
      match self.storage.data() {
        @column.ColumnData::String(data) => {
          let buf = fill_buffer(data, valid, v)
          Series::from_builtin(
            self.name,
            @column.BuiltinColumn::from_strings(buf),
          )
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            "fill_null type String does not match column type \{self.dtype()}",
          )
      }
  }
  preserve_backend(self, filled)
}

///|
/// Cast to the target dtype, the single cross-dtype conversion entry
/// (Polars' `Series.cast`). Delegates to `BuiltinColumn::cast`; the
/// supported targets are:
///
/// - `Int` — identity on Int; Float truncates toward zero (`NaN`, `±Inf`,
///   and out-of-`Int64`-range values `raise ParseError`); Bool → `1` / `0`;
///   String parses plain base-10 integers (other forms `raise ParseError`).
/// - `Float` — Int promoted; identity on Float; Bool → `1.0` / `0.0`;
///   String parses decimals / scientific notation.
/// - `String` — every dtype renders to its value form; never rejects a
///   value, so the only failure is the unsupported-target guard below.
///
/// Null slots are preserved verbatim. A numeric result lands on the
/// `Builtin` backend (re-converge with `to_numeric` for the fast path).
/// `Bool` and `Null` targets `raise Unsupported(_)`.
pub fn Series::cast(
  self : Series,
  target : @types.DataType,
) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.cast(target) }
}

// ── Storage backend control ───────────────────────────────────────────

///|
/// Which storage backend currently backs this column: `Numeric` for the
/// all-valid unboxed fast path (built by `from_ints` / `from_floats`, and
/// preserved through structural transforms), `Builtin` otherwise.
pub fn Series::storage_kind(self : Series) -> @column.StorageKind {
  self.storage.kind()
}

///|
/// Move this column onto the `Numeric` fast-path backend. The values are
/// unchanged — only the backing representation. `raise TypeMismatch` for a
/// non-numeric column and `raise InvalidOperation` for one carrying nulls
/// (a `NumericColumn` has no validity bitmap to record them); an
/// already-`Numeric` column is returned unchanged.
pub fn Series::to_numeric(self : Series) -> Series raise @types.DataError {
  Series::new(self.name, self.storage.to_numeric())
}

///|
/// Materialise this column onto the general-purpose `Builtin` backend (the
/// inverse of `to_numeric`). Total and lossless: an all-valid `Numeric`
/// column widens to a `BuiltinColumn` with an all-valid bitmap; a `Builtin`
/// column is returned unchanged.
pub fn Series::to_builtin(self : Series) -> Series {
  Series::from_builtin(self.name, self.storage.to_builtin())
}
