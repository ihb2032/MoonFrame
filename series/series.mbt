///|
/// A one-dimensional, dtype-aware column with a name. `Series` is the
/// per-column unit behind `DataFrame`, exposing the structural, nullability,
/// transform, cast, and (in `series_stats.mbt`) statistics surface that the
/// `frame` and `io` layers build on.
///
/// Its backend is an internal representation — Arrow-style storage with an
/// explicit validity bitmap, or an all-valid unboxed numeric fast path — decided
/// by a column's content rather than by its caller: the row rebuilds and the
/// expression engine's computed columns converge a null-free numeric result onto
/// the fast path (`try_column_to_numeric`), the nullable constructors and
/// `cast` produce a `Builtin` column whatever they started from, and the
/// backend-preserving windows leave a column on whichever
/// backend they found it. The **supported** API neither
/// observes nor selects it: the few methods that do (`storage` /
/// `storage_kind` / `is_canonical`) are engine seams, absent from the generated
/// interface and carrying no compatibility promise, so a caller outside this
/// module has no supported way to tell which one a column is on — and no way at
/// all to choose it, since nothing here moves a column onto a backend its
/// content does not call for. See `internal/column` and
/// [`docs/performance.md`](../docs/performance.md).
///
/// The fields are `priv`, so the struct is opaque outside this package: reach a
/// column through the value-level accessors (`name()` / `dtype()` / `len()` /
/// `get()` / `to_scalars()` / …) and build one through the named constructors,
/// so the underlying column always keeps its data-and-validity invariants.
pub struct Series {
  priv name : String
  priv storage : @column.ColumnStorage
} derive(Eq, Debug)

///|
pub extend Series with Eq::{equal, not_equal}

///|
pub extend Series with Debug::{to_repr}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Wrap an existing `ColumnStorage` under the given name — the canonical
/// constructor at the backend seam. The backend (and validity / null-count)
/// is whatever the storage already carries. Callers holding a
/// `BuiltinColumn` use `from_builtin` instead.
///
/// Package-private. A `#doc(hidden)` seam is still `pub` to the compiler, so
/// one taking a storage type is an entry point a downstream caller could reach
/// past `Series` with; this one has no caller outside this package, so it need
/// not be `pub` at all. The seams that remain — `storage()` for
/// `internal/kernel`, `Expr::node` for the evaluator and optimizer — are the
/// ones another package genuinely needs.
fn Series::new(name : String, storage : @column.ColumnStorage) -> Series {
  { name, storage, }
}

///|
/// Wrap an existing `BuiltinColumn` under the given name, behind a
/// `ColumnStorage::Builtin` — the adapter the constructors and transforms in
/// this package use when they have already produced a `BuiltinColumn`.
/// Package-private for the same reason as `new`.
fn Series::from_builtin(
  name : String,
  storage : @column.BuiltinColumn,
) -> Series {
  { name, storage: @column.ColumnStorage::Builtin(storage), }
}

///|
/// An empty (0-row) `Series` of the given dtype — the physical dispatch behind
/// `DataFrame::empty`, kept here in `series` (which owns the column) so `frame`
/// need not match storage backends to build an empty column. A `Null` dtype has
/// no physical backend, so it `raise`s `Unsupported`.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::empty_of(
  name : String,
  dtype : @types.DataType,
) -> Series raise @types.DataError {
  let storage = match @column.physical_type(dtype) {
    Some(@column.PhysicalType::I64) => @column.BuiltinColumn::from_ints([])
    Some(@column.PhysicalType::F64) => @column.BuiltinColumn::from_floats([])
    Some(@column.PhysicalType::Bool) => @column.BuiltinColumn::from_bools([])
    Some(@column.PhysicalType::Utf8) => @column.BuiltinColumn::from_strings([])
    None =>
      raise @types.DataError::Unsupported(
        "cannot build an empty column of dtype Null: \{name}",
      )
  }
  Series::from_builtin(name, storage)
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
    @column.ColumnStorage::Numeric(@column.NumericColumn::from_ints(values)),
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
    @column.ColumnStorage::Numeric(@column.NumericColumn::from_floats(values)),
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
  let valid = validity_bools(self)
  // Both the index (to consult `valid`) and the value are needed per cell, so
  // an index+value comprehension reads more directly than a `makei` over `a[i]`.
  match self.storage.data() {
    @column.ColumnData::Int(a) =>
      [
        for i, v in a => {
          if valid[i] {
            @types.Scalar::Int(v)
          } else {
            @types.Scalar::Null
          }
        }
      ]
    @column.ColumnData::Float(a) =>
      [
        for i, v in a => {
          if valid[i] {
            @types.Scalar::Float(v)
          } else {
            @types.Scalar::Null
          }
        }
      ]
    @column.ColumnData::Bool(a) =>
      [
        for i, v in a => {
          if valid[i] {
            @types.Scalar::Bool(v)
          } else {
            @types.Scalar::Null
          }
        }
      ]
    @column.ColumnData::String(a) =>
      [
        for i, v in a => {
          if valid[i] {
            @types.Scalar::String(v)
          } else {
            @types.Scalar::Null
          }
        }
      ]
  }
}

///|
/// Expose the underlying `ColumnStorage`. The one caller outside this package
/// is `internal/kernel`, which walks `data()` — alongside the mask
/// `validity_bools` hands it — to run a
/// column pass without `Scalar` boxing; `frame` and above never call it — they
/// hold the `Series`.
/// The type handed back is `ColumnStorage` rather than a bare
/// `BuiltinColumn`; the `data()` / `validity()` surface is the same either
/// way, so a column-reading call site does not care which backend it got.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::storage(self : Series) -> @column.ColumnStorage {
  self.storage
}

// ── Transforms ────────────────────────────────────────────────────────

///|
/// Return a copy of this series with a different column name. Storage
/// is shared (immutable), so this is `O(1)`.
pub fn Series::rename(self : Series, new_name : String) -> Series {
  { name: new_name, storage: self.storage, }
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
  { name: self.name, storage: self.storage.slice(start, end), }
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
  try_column_to_numeric({
    name: self.name,
    storage: self.storage.take(indices),
  })
}

///|
/// Best-effort, **total** move of one column onto the `Numeric` fast-path
/// backend: an all-valid Int / Float `Builtin` column is rebuilt on
/// `NumericColumn`; every other column — already `Numeric`, carrying nulls,
/// or non-numeric — is returned unchanged. This is the whole of how a column
/// reaches that backend after construction: the canonicalisation in the row
/// gathers (`gather_series` / `Series::gather` / `rebuild_options`), in
/// `preserve_backend`, and in the expression engine's computed-column
/// convergence. Total by design, so a column that cannot move is simply kept
/// rather than failing (and rather than leaving a dead error arm,
/// `feedback_lib_no_abort`). The null-free Int /
/// Float arms rebuild through the `NumericColumn` constructors, which copy
/// their input, ingestion being immutable — one extra `O(n)`
/// array copy per converged column. (The buffer-free move the column package
/// used to offer alongside it is gone: nothing outside `series` converged a
/// column, so the entry point went with it.)
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
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
              @column.ColumnStorage::Numeric(
                @column.NumericColumn::from_ints(a),
              ),
            )
          @column.ColumnData::Float(a) =>
            Series::new(
              s.name,
              @column.ColumnStorage::Numeric(
                @column.NumericColumn::from_floats(a),
              ),
            )
          // No wildcard: a future `ColumnData` variant must decide here
          // whether it converges onto the `Numeric` backend.
          @column.ColumnData::Bool(_) | @column.ColumnData::String(_) => s
        }
      }
  }
}

///|
/// Re-converge a freshly rebuilt (`Builtin`-backed) column to `source`'s
/// backend: a `Numeric` source's all-valid rebuild moves back onto the
/// `Numeric` fast path, a `Builtin` source's stays `Builtin`. This is the
/// *preserve* class in `docs/performance.md`, which classifies every path — for
/// the transforms that must hold their source's backend rather than derive one
/// from content, `fill_null` being the one that needs it (its filled column is
/// built straight on `Builtin`). A caller whose input already canonicalised —
/// the join assembly, over a `rebuild_options` result — gets a no-op
/// passthrough; the slices preserve the backend by sharing the validity bitmap
/// and never reach here.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
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
/// the fast path. The row-level scanners (`sort` and `drop_nulls`; `group_by`
/// and `join` build keys from `to_scalars` instead) and the elementwise
/// expression kernels (`expr_eval` and `internal/kernel`,
/// whose operands are frequently `Numeric`) read the mask by plain index, so
/// they share this instead of each repacking a throwaway bitmap for a
/// `Numeric` column. Takes the `Series`, not its storage, so a caller reads a
/// column's validity without naming the storage layer.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn validity_bools(column : Series) -> Array[Bool] {
  let storage = column.storage
  match storage.kind() {
    @column.StorageKind::Numeric => Array::make(storage.len(), true)
    @column.StorageKind::Builtin => storage.validity().to_bools()
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
fn[T] fill_buffer(data : ArrayView[T], valid : Array[Bool], v : T) -> Array[T] {
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
  let valid = validity_bools(self)
  let filled = match value {
    @types.Scalar::Null =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message("cannot fill nulls with Null"),
      )
    @types.Scalar::Int(v) =>
      match self.storage.data() {
        @column.ColumnData::Int(data) => {
          let buf = fill_buffer(data, valid, v)
          Series::from_builtin(self.name, @column.BuiltinColumn::from_ints(buf))
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "fill_null type Int does not match column type \{self.dtype()}",
            ),
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
            @types.TypeMismatchDetail::Message(
              "fill_null type Float does not match column type \{self.dtype()}",
            ),
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
            @types.TypeMismatchDetail::Message(
              "fill_null type Bool does not match column type \{self.dtype()}",
            ),
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
            @types.TypeMismatchDetail::Message(
              "fill_null type String does not match column type \{self.dtype()}",
            ),
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
/// `Builtin` backend; the engine re-converges it onto the unboxed fast path
/// where a later step benefits. `Bool` and `Null` targets `raise Unsupported(_)`.
pub fn Series::cast(
  self : Series,
  target : @types.DataType,
) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.cast(target), }
}

// ── Storage backend control ───────────────────────────────────────────

///|
/// Which storage backend currently backs this column: `Numeric` for the
/// all-valid unboxed fast path (built by `from_ints` / `from_floats`, and
/// preserved through structural transforms), `Builtin` otherwise.
///
/// No production code outside this package calls it — the packages above
/// choose a backend through `try_column_to_numeric` / `preserve_backend`
/// rather than by asking. It stays `pub` for the *assertions*: "an operator's
/// output backend is a function of its content" is engine-wide behaviour, and
/// the operators live in `frame`, whose tests are a separate package and can
/// only observe the backend through a `pub` reader. That is a declared
/// exception in the seam guard's allowlist, not a precedent — see
/// `#internal(engine)` in `docs/api.md`.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::storage_kind(self : Series) -> @column.StorageKind {
  self.storage.kind()
}

///|
/// Whether this column sits on its **canonical** storage backend — the fixed
/// point of `try_column_to_numeric`, the representation every
/// content-determined transform (`gather` / `drop_nulls` / `filter`
/// and the expression engine's computed columns) lands its result on.
///
/// A column is canonical unless it is a `Builtin` column that is both
/// all-valid *and* numeric (`Int` / `Float`): that lone shape can move onto
/// the unboxed `Numeric` fast path losslessly, so a content-determined
/// transform never leaves a result there. Every other shape is already
/// canonical — a `Numeric` column (all-valid Int / Float by construction), a
/// `Builtin` column carrying a null (a `NumericColumn` has no validity bitmap
/// to record it), or a `Builtin` `Bool` / `String` column (the fast path is
/// numeric-only).
///
/// This is the representation invariant the query optimizer relies on for
/// `collect ≡ eager` — a derived column's backend is a function of its
/// *content*, not of how it was produced — surfaced as a predicate so tests
/// can assert it directly instead of pinning a specific `storage_kind`. It
/// mirrors `try_column_to_numeric` arm for arm: `is_canonical` is `true`
/// exactly when that total move is a backend no-op. The `ColumnData` match is
/// wildcard-free, so a future dtype must decide here whether it converges onto
/// `Numeric`. A backend-preserving transform (`slice` / `head` / `fill_null`)
/// can still return a non-canonical column when its source was one — the
/// invariant governs the content-determined path, not every column.
///
/// Like every invariant predicate in this repository it has no production
/// caller: what it is *for* is being asserted, once per transform that claims
/// to produce a canonical column. That is why it stays `pub` while the
/// backend-forcing helpers around it did not, and it is listed as such in the
/// seam guard's allowlist.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::is_canonical(self : Series) -> Bool {
  match self.storage.kind() {
    @column.StorageKind::Numeric => true
    @column.StorageKind::Builtin =>
      if self.storage.null_count() > 0 {
        // A null forces the bitmap-backed `Builtin` backend — already canonical.
        true
      } else {
        match self.storage.data() {
          @column.ColumnData::Int(_) | @column.ColumnData::Float(_) => false
          @column.ColumnData::Bool(_) | @column.ColumnData::String(_) => true
        }
      }
  }
}
