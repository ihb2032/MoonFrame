///|
/// A one-dimensional, dtype-aware column with a name. `Series` is the
/// per-column unit behind `DataFrame`, exposing the structural, nullability,
/// transform, cast, and statistics surface that the
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
/// content does not call for.
///
/// The engine machinery the verbs build on is the row-rebuild machine (an
/// index vector, a window, a
/// mask, or a column merge turned into a new `Series`) and the storage-backend
/// machine (converge / preserve / read / assert).
/// Both are engine seams serving `frame` and the kernel layer, not
/// `Series` API.
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
/// the kernel layer, `Expr::node` for the evaluator and optimizer — are the
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
  // The envelope check rides the empty column too: a zero-row frame is
  // still a column the library authored, and its dtype would otherwise
  // be the one decimal a later verb could lift a scalar out of.
  if dtype is @types.DataType::Decimal(scale) {
    @types.check_decimal_scale(scale, "column \{name}")
  }
  let storage = match dtype.physical() {
    // The I64 riders share one buffer, so the dtype-carrying constructor
    // serves both `Int` and its riders (`Date`) — no per-dtype branch.
    Some(@types.PhysicalType::I64) =>
      @column.BuiltinColumn::from_i64_options(dtype, [])
    Some(@types.PhysicalType::F64) => @column.BuiltinColumn::from_floats([])
    Some(@types.PhysicalType::Bool) => @column.BuiltinColumn::from_bools([])
    Some(@types.PhysicalType::Utf8) => @column.BuiltinColumn::from_strings([])
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
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::from_int_options(
  name : String,
  values : Array[Int64?],
) -> Series {
  Series::from_builtin(name, @column.BuiltinColumn::from_int_options(values))
}

///|
/// Build a nullable series whose `dtype` fixes the identity of an `I64`
/// rider — `Int`, or a date-like dtype such as `Date` — from optional raw
/// cells. Nullable, so it lands on the general-purpose `Builtin` backend.
/// The dtype-carrying rebuild keeps a `Date` column a `Date` (an `Int`
/// rebuild would silently retype every cell), so a kernel arm that rebuilds
/// same-physical columns without knowing which rider it holds goes through
/// here, not `from_int_options`. A decimal dtype meets the envelope check
/// here too, so the "every constructor that authors a decimal dtype raises"
/// claim (`check_decimal_scale`) needs no seam exception.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::from_i64_options(
  name : String,
  dtype : @types.DataType,
  values : Array[Int64?],
) -> Series raise @types.DataError {
  match dtype {
    @types.DataType::Decimal(scale) =>
      @types.check_decimal_scale(scale, "column \{name}")
    _ => ()
  }
  Series::from_builtin(
    name,
    @column.BuiltinColumn::from_i64_options(dtype, values),
  )
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
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
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
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
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
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::from_string_options(
  name : String,
  values : Array[String?],
) -> Series {
  Series::from_builtin(name, @column.BuiltinColumn::from_string_options(values))
}

///|
/// The one public nullable constructor — Polars' `pl.Series(name, [1, None])`
/// translated to a statically-typed language: the cells carry their own
/// nullness as `Scalar`, and the column's dtype is `dtype~` when given, or
/// the dtype of the first non-null cell when not. The null-free `from_ints` /
/// `from_floats` / `from_bools` / `from_strings` constructors stay the typed
/// fast path; this is the door for cells that may be null — including
/// `Scalar::Date`, which has no other public constructor.
///
/// Every non-null cell must carry the target dtype exactly — an `Int` cell in
/// a `Float` column is a `cast`, not a construction, so it `raise`s
/// `TypeMismatch(Expected(target, got, name))` here (on the first offending
/// cell, in cell order). Two targets cannot be inferred and `raise` instead:
/// an all-null `cells` without `dtype~` has nothing to decide from
/// (`InvalidOperation`), and `dtype~ = Null` names no physical column
/// (`Unsupported`). A nullable series lands on the general-purpose `Builtin`
/// backend, like every `from_*_options` build.
pub fn Series::from_scalars(
  name : String,
  cells : Array[@types.Scalar],
  dtype? : @types.DataType,
) -> Series raise @types.DataError {
  let target : @types.DataType = match dtype {
    Some(d) => d
    None => {
      let mut found : @types.DataType? = None
      for cell in cells {
        if !(cell is @types.Scalar::Null) {
          found = Some(cell.dtype())
          break
        }
      }
      match found {
        Some(d) => d
        None =>
          raise @types.DataError::InvalidOperation(
            "cannot infer a dtype for column \"\{name}\": every cell is null, pass dtype~ to lock one",
          )
      }
    }
  }
  match target {
    @types.DataType::Int =>
      Series::from_int_options(
        name,
        typed_cells(cells, target, name, cell => {
          if cell is @types.Scalar::Int(v) {
            Some(v)
          } else {
            None
          }
        }),
      )
    @types.DataType::Float =>
      Series::from_float_options(
        name,
        typed_cells(cells, target, name, cell => {
          if cell is @types.Scalar::Float(v) {
            Some(v)
          } else {
            None
          }
        }),
      )
    @types.DataType::Bool =>
      Series::from_bool_options(
        name,
        typed_cells(cells, target, name, cell => {
          if cell is @types.Scalar::Bool(v) {
            Some(v)
          } else {
            None
          }
        }),
      )
    @types.DataType::String =>
      Series::from_string_options(
        name,
        typed_cells(cells, target, name, cell => {
          if cell is @types.Scalar::String(v) {
            Some(v)
          } else {
            None
          }
        }),
      )
    @types.DataType::Date =>
      Series::from_date_options(
        name,
        typed_cells(cells, target, name, cell => {
          if cell is @types.Scalar::Date(v) {
            Some(v)
          } else {
            None
          }
        }),
      )
    @types.DataType::Timestamp =>
      Series::from_timestamp_options(
        name,
        typed_cells(cells, target, name, cell => {
          if cell is @types.Scalar::Timestamp(v) {
            Some(v)
          } else {
            None
          }
        }),
      )
    @types.DataType::Decimal(scale) =>
      Series::from_decimal_options(
        scale,
        name,
        typed_cells(cells, target, name, cell => {
          if cell is @types.Scalar::Decimal(s, v) && s == scale {
            Some(v)
          } else {
            None
          }
        }),
      )
    @types.DataType::Null =>
      raise @types.DataError::Unsupported(
        "cannot build a column of dtype Null: \{name}",
      )
  }
}

///|
/// Decode `Scalar` cells into the typed optional cells a nullable constructor
/// takes: `Scalar::Null` becomes `None`, a cell `decode` recognises is
/// unwrapped, and anything else `raise`s
/// `TypeMismatch(Expected(target, got, name))`. Cells are visited in order, so
/// the reported cell is the first offending one.
fn[T] typed_cells(
  cells : Array[@types.Scalar],
  target : @types.DataType,
  name : String,
  decode : (@types.Scalar) -> T?,
) -> Array[T?] raise @types.DataError {
  cells.map(cell => {
    match cell {
      @types.Scalar::Null => None
      c =>
        match decode(c) {
          Some(v) => Some(v)
          None =>
            raise @types.DataError::TypeMismatch(
              @types.TypeMismatchDetail::Expected(target, c.dtype(), name),
            )
        }
    }
  })
}

///|
/// Build a `Date` series from optional raw day-counts (whole days since the
/// Unix epoch, `1970-01-01` = day `0`), `None` entries nulls. The date face
/// of the shared `I64` buffer constructor: the cells are the same `Int64`
/// buffer an int column carries, with date semantics on read — the registry's
/// per-dtype lift turns a cell back into a `Scalar::Date`.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::from_date_options(
  name : String,
  values : Array[Int64?],
) -> Series {
  Series::from_builtin(
    name,
    @column.BuiltinColumn::from_i64_options(@types.DataType::Date, values),
  )
}

///|
/// Build a `Timestamp` series from optional raw microsecond-counts (whole
/// microseconds since the Unix epoch, `1970-01-01T00:00:00` = microsecond
/// `0`), `None` entries nulls. The timestamp face of the shared `I64` buffer
/// constructor: the cells are the same `Int64` buffer an int column carries,
/// with timestamp semantics on read — the registry's per-dtype lift turns a
/// cell back into a `Scalar::Timestamp`.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::from_timestamp_options(
  name : String,
  values : Array[Int64?],
) -> Series {
  Series::from_builtin(
    name,
    @column.BuiltinColumn::from_i64_options(@types.DataType::Timestamp, values),
  )
}

///|
/// Build a `Decimal(scale)` series from optional raw unscaled magnitudes
/// (the value is `unscaled x 10^-scale`), `None` entries nulls. The decimal
/// face of the shared `I64` buffer constructor: the cells are the same
/// `Int64` buffer an int column carries, with decimal semantics on read —
/// the registry's per-dtype lift turns a cell back into a
/// `Scalar::Decimal(scale, v)`.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::from_decimal_options(
  scale : Int32,
  name : String,
  values : Array[Int64?],
) -> Series raise @types.DataError {
  @types.check_decimal_scale(scale, "column \{name}")
  Series::from_builtin(
    name,
    @column.BuiltinColumn::from_i64_options(
      @types.DataType::Decimal(scale),
      values,
    ),
  )
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
pub fn Series::len(self : Series) -> Int32 {
  self.storage.len()
}

///|
/// `true` when the series has zero cells.
pub fn Series::is_empty(self : Series) -> Bool {
  self.storage.is_empty()
}

///|
/// Number of null cells.
pub fn Series::null_count(self : Series) -> Int32 {
  self.storage.null_count()
}

///|
/// Whether any **present** cell holds the IEEE `NaN` — only a `Float`
/// column can (a null cell is missing, not NaN, and every other dtype's
/// cells are finite by construction). A direct buffer scan with no boxing:
/// the fill that consults it either returns the series verbatim or pays
/// the full re-materialisation, and a NaN-free column deserves the
/// former. Total.
pub fn Series::has_nan(self : Series) -> Bool {
  // Only a `Float` column can hold a `NaN` (a null cell is missing, not
  // NaN, and every other dtype's cells are finite by construction), so
  // the dtype and the buffer test are one fact — stated once, as one
  // tuple pattern whose fallback is every non-Float series.
  let valid = self.validity_bools()
  match (self.dtype(), self.storage.data()) {
    (@types.DataType::Float, @column.ColumnData::F64(buf)) => {
      for i in 0..<buf.length() {
        if valid[i] && buf[i].is_nan() {
          return true
        }
      }
      false
    }
    (_, _) => false
  }
}

///|
/// Whether cell `i` is null. Out-of-bounds indices bubble the
/// underlying `IndexOutOfBounds` error.
pub fn Series::is_null(self : Series, i : Int32) -> Bool raise @types.DataError {
  self.storage.is_null(i)
}

///|
/// Read cell `i` as a `Scalar` (`Null` for null cells) — the bracket
/// spelling `s[0]` (Polars' `s[0]`). Out-of-bounds indices bubble the
/// underlying `IndexOutOfBounds` error; a negative index does **not** wrap
/// from the end (MoonBit indexing convention — the slice spelling `s[-1:]`
/// is where negatives count from the end).
#alias("_[_]")
pub fn Series::get(
  self : Series,
  i : Int32,
) -> @types.Scalar raise @types.DataError {
  self.storage.get(i)
}

///|
/// Materialise every cell as a `Scalar` (`Null` for null cells), in order.
/// Total — reads the backing array and validity mask once. Renderers (CSV
/// / JSON / Markdown) use this to walk a column without a per-cell
/// bounds-checked `get`. Each present cell lifts through the dtype registry
/// (`scalar_of`), so an `I64`-riding dtype like `Date` surfaces its own
/// `Scalar` variant, not the buffer's.
pub fn Series::to_scalars(self : Series) -> Array[@types.Scalar] {
  let valid = self.validity_bools()
  let data = self.storage.data()
  let dtype = self.dtype()
  Array::makei(valid.length(), i => {
    if valid[i] {
      @column.scalar_of(dtype, data, i)
    } else {
      @types.Scalar::Null
    }
  })
}

///|
/// Iterate the cells lazily, in row order — the `for cell in s` spelling.
/// Each step yields one `Scalar`, `Null` for a null cell, lifted through
/// the same dtype-registry read `to_scalars` performs per batch: an
/// I64-riding dtype like `Date` surfaces its own variant, not the
/// buffer's. The one-pass materialising read stays `to_scalars`' job (the
/// renderers use it); this is the streaming counterpart — a cell at a
/// time, with the `Iter` combinator family (`map`, `filter`, `fold`, …)
/// reachable without paying for the intermediate array. Yielding a boxed
/// cell is the standard shape for this surface: Polars' series iteration
/// yields `AnyValue`, nulls included as a variant.
pub fn Series::iter(self : Series) -> Iter[@types.Scalar] {
  let len = self.len()
  let valid = self.validity_bools()
  let data = self.storage.data()
  let dtype = self.dtype()
  let mut i = 0
  Iter::new(
    fn() {
      guard i < len else { None }
      let cell = if valid[i] {
        @column.scalar_of(dtype, data, i)
      } else {
        @types.Scalar::Null
      }
      i += 1
      Some(cell)
    },
    size_hint=len,
  )
}

///|
/// Expose the underlying `ColumnStorage`. The one caller outside this package
/// is the kernel layer, which walks `data()` — alongside the mask
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

///|
/// Return a copy of this series with a different column name. Storage
/// is shared (immutable), so this is `O(1)`.
pub fn Series::rename(self : Series, new_name : String) -> Series {
  { name: new_name, storage: self.storage, }
}
