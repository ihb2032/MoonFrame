// The storage-backend machine: everything that reads or changes which
// backend a column sits on, in four faces —
//
//   - converge  `try_column_to_numeric`   the total content → `Numeric` move
//     that every canonicalising path lands through
//   - preserve  `preserve_backend`        re-converge a freshly rebuilt
//     column to its source's backend instead of deriving one from content
//   - read      `validity_bools`          a column's validity as a dense
//     `Array[Bool]`, skipping the synthetic bitmap a `Numeric` column has
//     none of
//   - assert    `Series::storage_kind` /
//     `Series::is_canonical`              the invariant readers `frame`'s
//     tests assert through (declared exceptions: no production caller
//     outside this package)
//
// The `pub` entries are `#doc(hidden)` + `#internal(engine)` engine seams,
// with pinned signatures and consumers. The
// differential parity harness guards exactly this
// machine: the same cells must behave identically whichever backend they
// sit on.

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
      match s.storage.data() {
        // The `Numeric` backend is dtype-less: only a *numeric* dtype (the
        // registry's `numeric` flag) with no nulls may converge onto it, so
        // an all-valid `Date` column — also I64-typed, also null-free —
        // keeps its `Builtin` buffer instead of losing its identity on the
        // fast path.
        @column.ColumnData::I64(a) if s.dtype().is_numeric() &&
          s.storage.null_count() == 0 =>
          Series::new(
            s.name,
            @column.ColumnStorage::Numeric(@column.NumericColumn::from_ints(a)),
          )
        @column.ColumnData::F64(a) if s.storage.null_count() == 0 =>
          Series::new(
            s.name,
            @column.ColumnStorage::Numeric(
              @column.NumericColumn::from_floats(a),
            ),
          )
        // Everything else stays `Builtin` as-is: a null-free Int / Float
        // column never reaches this arm (its guard passed), so the arm
        // carries Date (numericity false), any null-carrying Int / Float,
        // and Bool / String.
        @column.ColumnData::I64(_)
        | @column.ColumnData::F64(_)
        | @column.ColumnData::Bool(_)
        | @column.ColumnData::Utf8(_) => s
      }
  }
}

///|
/// Re-converge a freshly rebuilt (`Builtin`-backed) column to `source`'s
/// backend: a `Numeric` source's all-valid rebuild moves back onto the
/// `Numeric` fast path, a `Builtin` source's stays `Builtin`. This is the
/// *preserve* class — the transforms that must hold their source's backend
/// rather than derive one
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
/// expression kernels (the frame evaluator and the kernel layer,
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
/// exception in the seam guard's allowlist, not a precedent — the documented
/// contract for an `#internal(engine)` seam.
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
          // An I64 buffer is non-canonical only when its dtype is numeric:
          // a null-free Date column also rides I64, but the registry's
          // numeric flag keeps `try_column_to_numeric` off it, so `Builtin`
          // is its canonical backend — exactly the arm-for-arm mirror the
          // docstring above promises.
          @column.ColumnData::I64(_) if !self.dtype().is_numeric() => true
          @column.ColumnData::I64(_) | @column.ColumnData::F64(_) => false
          @column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_) => true
        }
      }
  }
}
