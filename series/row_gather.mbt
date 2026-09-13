// The row-rebuild machine: turn a description of a row set — an index
// vector, optional indices, a contiguous window, a predicate mask, a
// two-column merge — into a new `Series`. The `pub` entries are
// `#doc(hidden)` + `#internal(engine)` engine seams, pinned signature and
// consumers in `engine_seams.snapshot`; none is on the supported surface.
// They serve the engine layers above, not the `Series` API. Consumers:
//
//   - `gather_series`     ← the row gathers of `frame` (reverse / unique /
//     window, the aggregation row collection, the expression engine) and
//     `internal/kernel`'s broadcast kernels
//   - `gather_series_opt` +
//     `coalesce_columns`  ← `join`'s output assembly
//   - `mask_true_indices` ← `filter` and the predicate-absorbing file scans
//   - `slice_series`      ← head / tail / `DataFrame::slice`
//
// The shared skeleton underneath is `rebuild_options` — the single 4-arm
// match over the source's dtype — with `rebuild_by_row` and
// `collect_matched` on top of it. A new row-level verb starts here:
// describe its rows through one of these entries instead of touching a
// column buffer, and the rebuild keeps the content-determined backend
// invariant for free.

///|
/// The ascending positions where a `Bool` mask column is `true`, or `None`
/// when the column holds another dtype. A null cell is not a `true` — an
/// unknown is not a keep, the Kleene reading `filter` and the predicate-absorbed
/// file scans both want.
///
/// The result is a freshly built index array, which is the point: handing back
/// the mask's own `Array[Bool]` would give a caller in another package the
/// ability to write into a live column's buffer, and a `Series` is supposed to
/// be immutable once built. Deciding what a non-`Bool` predicate *means* stays
/// with the caller — hence `None` rather than a raise.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn mask_true_indices(mask : Series) -> Array[Int]? {
  let cells = match mask.storage.data() {
    @column.ColumnData::Bool(cells) => cells
    @column.ColumnData::Int(_)
    | @column.ColumnData::Float(_)
    | @column.ColumnData::String(_) => return None
  }
  let valid = validity_bools(mask)
  let kept : Array[Int] = []
  for i in 0..<cells.length() {
    if valid[i] && cells[i] {
      kept.push(i)
    }
  }
  Some(kept)
}

///|
/// Merge two equal-dtype, equal-length columns into one, taking `base`'s cell
/// where it is non-null and `fill`'s otherwise; a cell null on both sides
/// stays null. The coalesced join key: `base` is one side's key gathered over
/// the output rows, `fill` the other's, and on a matched row the two agree —
/// so the choice only shows where the row is present on a single side.
///
/// A column-level merge, so it lives beside the column rather than in the join
/// that wants it: the cells come out of `base`'s own buffer, and reading that
/// buffer is this package's business. `fill` is read through the total
/// `to_scalars`, so no unreachable error arm is introduced — the caller's
/// equal-dtype precondition guarantees the matching `Scalar` variant, and the
/// `_` arm catches only the both-null case.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn coalesce_columns(base : Series, fill : Series, name : String) -> Series {
  let base_valid = validity_bools(base)
  let fills = fill.to_scalars()
  // The four closures differ only in the `Scalar` variant they read `fill` as.
  rebuild_options(
    base,
    name,
    base.len(),
    (a, i) => {
      if base_valid[i] {
        Some(a[i])
      } else {
        match fills[i] {
          @types.Scalar::Int(v) => Some(v)
          _ => None
        }
      }
    },
    (a, i) => {
      if base_valid[i] {
        Some(a[i])
      } else {
        match fills[i] {
          @types.Scalar::Float(v) => Some(v)
          _ => None
        }
      }
    },
    (a, i) => {
      if base_valid[i] {
        Some(a[i])
      } else {
        match fills[i] {
          @types.Scalar::Bool(v) => Some(v)
          _ => None
        }
      }
    },
    (a, i) => {
      if base_valid[i] {
        Some(a[i])
      } else {
        match fills[i] {
          @types.Scalar::String(v) => Some(v)
          _ => None
        }
      }
    },
  )
}

///|
/// Total contiguous slice `[start, start + len)`. Delegates to
/// `ColumnStorage::slice_total`, which keeps the source backend and shares
/// the validity bitmap as a zero-copy view while copying the row data — the
/// single slice path behind `head` / `tail` /
/// `DataFrame::slice` (no rebuild, no `Result`). The caller guarantees
/// `0 <= start` and `start + len <= self.len()`; `slice_total` clamps anyway,
/// so a stray bound can never abort.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn slice_series(s : Series, start : Int, len : Int) -> Series {
  { name: s.name, storage: s.storage.slice_total(start, start + len), }
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
/// `gather_series`' nullable path, `gather_series_opt`, and `coalesce_columns`:
/// the per-caller cell logic is all that differs between them, so it is all
/// each caller supplies. The `match` stays exhaustive over the four dtypes —
/// every arm is the live path for a column of that dtype, so none is dead.
///
/// The rebuilt column is **canonicalised** (`try_column_to_numeric`): a row /
/// cell selection that leaves an Int / Float column all-valid lands on the
/// `Numeric` fast path, even when its source carried nulls those dropped rows
/// held. This makes a column's backend a function of its *content*, not of how
/// it was produced — the invariant that keeps a rewritten plan on the same
/// execution path as the chain it rewrites, so that sinking a `Filter` below a
/// stage (recomputing a derived column over the surviving rows) cannot leave
/// the result on a different backend, with different per-cell costs, from the
/// eager chain. Not an equality concern: `ColumnStorage`'s `Eq` compares
/// content, so two columns holding the same cells are equal whichever backend
/// they sit on. It is the reason the backend can be asserted at all.
///
/// Package-private, deliberately: the four closures receive the source's own
/// typed data array, so anything holding this could write into a live column.
/// Every caller is in this package — the row gathers and `coalesce_columns` —
/// and the seam other packages get is the finished `Series`.
fn rebuild_options(
  source : Series,
  name : String,
  n : Int,
  int_cell : (ArrayView[Int64], Int) -> Int64?,
  float_cell : (ArrayView[Double], Int) -> Double?,
  bool_cell : (ArrayView[Bool], Int) -> Bool?,
  string_cell : (ArrayView[String], Int) -> String?,
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
/// Total gather: position `k` of the result is `s[idx[k]]`. The caller is
/// expected to pass indices in `[0, s.len())`; a stray index outside that
/// range yields a **null cell** at its position — never a panic — the same
/// on both storage backends, mirroring `Bitmap::take_view`'s hardening (a
/// caller that breaks the in-bounds contract still cannot abort). The
/// result is **canonical**: a `Numeric` source rebuilds straight onto the
/// `Numeric` fast path, and a `Builtin` source whose gathered rows leave it
/// all-valid re-converges onto `Numeric` too (via `rebuild_options`), so
/// the backend is a function of the gathered content, not the source — the
/// invariant predicate pushdown relies on. Backs `drop_nulls` and the
/// row-gather DataFrame transforms. `Series::gather` keeps the same backend
/// invariant by a different route (`ColumnStorage::take`, which *raises* on an
/// out-of-range index rather than yielding a null cell).
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn gather_series(s : Series, idx : Array[Int]) -> Series {
  // A `Numeric` source is all-valid, so when every index is in-bounds its
  // gather is itself all-valid: rebuild directly onto the `Numeric` backend,
  // materialising no validity mask and allocating no transient bitmap. A
  // `Numeric` column only ever backs `Int` / `Float`, so the two guarded
  // arms are the whole `Numeric` case (`Bool` / `String` are always
  // `Builtin`). Routing a `Numeric` source through the option constructors
  // instead would round-trip `Numeric` → `Builtin` → `try_column_to_numeric`
  // → `Numeric`, allocating an `Array[T?]` and a `Bitmap` only to drop them
  // on re-convergence. The fast path reads the raw data array unguarded, so
  // it fires only after a cheap `O(idx)` all-in-bounds scan; a stray index
  // falls through to the `_` arm, whose `is_valid_total` gating turns it
  // into a null cell (a `Numeric` source synthesises an all-valid bitmap),
  // keeping the misuse abort-free and backend-agnostic. A `Builtin` source
  // (any dtype) always takes the `_` arm and shares the `rebuild_options`
  // skeleton, reading each gathered slot's validity straight off the source
  // bitmap (`is_valid_total`), so the gather costs `O(idx)` rather than
  // materialising the whole `O(source)` mask — a per-group gather in the
  // grouped-aggregation engine touches only its group's rows, keeping a
  // derived reduction linear instead of quadratic on a high-cardinality key.
  let n = s.len()
  let fast = s.storage.kind() is @column.StorageKind::Numeric &&
    idx.iter().all(k => k >= 0 && k < n)
  match s.storage.data() {
    @column.ColumnData::Int(a) if fast =>
      Series::from_ints(s.name, idx.map(k => a[k]))
    @column.ColumnData::Float(a) if fast =>
      Series::from_floats(s.name, idx.map(k => a[k]))
    _ => {
      let validity = s.storage.validity()
      rebuild_by_row(s, s.name, idx.length(), k => {
        let j = idx[k]
        if validity.is_valid_total(j) {
          Some(j)
        } else {
          None
        }
      })
    }
  }
}

///|
/// Shared skeleton of the row gathers: rebuild `source`'s dtype via
/// `rebuild_options`, reading output cell `k` from source row `row_at(k)`
/// when it is `Some` (the row is in bounds and valid there), else a null
/// cell. The four per-dtype closures are identical bar their element type —
/// monomorphisation keeps them syntactically separate — so they are spelled
/// once here instead of once per gather call site.
fn rebuild_by_row(
  source : Series,
  name : String,
  n : Int,
  row_at : (Int) -> Int?,
) -> Series {
  rebuild_options(
    source,
    name,
    n,
    (a, k) => row_at(k).map(j => a[j]),
    (a, k) => row_at(k).map(j => a[j]),
    (a, k) => row_at(k).map(j => a[j]),
    (a, k) => row_at(k).map(j => a[j]),
  )
}

///|
/// The matched source rows when `idx` has no unmatched (`None`) slot and
/// every index lies in `[0, len)`, else `None` — the gate for
/// `gather_series_opt`'s `Numeric` fast path, which reads the raw data array
/// unguarded and so can only fire when every output row provably maps to a
/// real source row. A stray out-of-range index demotes the whole gather to
/// the guarded arm (a null cell there), mirroring `gather_series`'
/// abort-free handling of the same misuse.
fn collect_matched(idx : Array[Int?], len : Int) -> Array[Int]? {
  let rows : Array[Int] = []
  for j in idx {
    match j {
      Some(v) => if v >= 0 && v < len { rows.push(v) } else { return None }
      None => return None
    }
  }
  Some(rows)
}

///|
/// Gather a column by optional row indices: output cell `k` is
/// `s[idx[k]]` when `idx[k]` is `Some`, or a null cell when it is `None`.
/// Total — the caller (`join`'s output assembly) only ever stores in-bounds
/// row indices, and `None` marks a row kept without a match on this side.
/// The result is named `out_name` (so a colliding right column can be
/// suffixed) and keeps the source dtype. A `Numeric` source with no
/// unmatched (`None`) row takes the all-valid fast path straight onto the
/// `Numeric` backend; everything else materialises through the option
/// constructors (the shared `rebuild_by_row` skeleton → a `Builtin` column,
/// which `join` re-converges via `preserve_backend`).
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn gather_series_opt(
  s : Series,
  idx : Array[Int?],
  out_name : String,
) -> Series {
  // `Numeric` fast path: a `Numeric` source is all-valid, so a gather with no
  // unmatched (`None`) row is itself all-valid — build the numeric array
  // straight onto the `Numeric` backend, skipping the `Array[T?]` + `Bitmap`
  // round-trip `rebuild_options` would allocate only to drop on re-convergence.
  // Mirrors `gather_series`' `Numeric` arm.
  let matched = if s.storage.kind() is @column.StorageKind::Numeric {
    collect_matched(idx, s.len())
  } else {
    None
  }
  match (s.storage.data(), matched) {
    (@column.ColumnData::Int(a), Some(rows)) =>
      Series::from_ints(out_name, rows.map(j => a[j]))
    (@column.ColumnData::Float(a), Some(rows)) =>
      Series::from_floats(out_name, rows.map(j => a[j]))
    (@column.ColumnData::Int(_) | @column.ColumnData::Float(_), None)
    | (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _) => {
      let validity = s.storage.validity()
      // Output cell `k` reads source row `idx[k]` when it is `Some` (and the
      // cell there is valid), else a null. Read each matched row's validity by
      // O(1) bit lookup (`is_valid_total`) rather than materialising the whole
      // O(source) mask — a high-selectivity join emits far fewer rows than the
      // source has, so the gather stays O(output) (mirrors `gather_series`).
      rebuild_by_row(s, out_name, idx.length(), k => {
        idx[k].bind(j => if validity.is_valid_total(j) { Some(j) } else { None })
      })
    }
  }
}
