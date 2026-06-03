///|
/// Equi-join `self` (the left frame) with `other` (the right frame) on
/// the key columns named in `options.on`, producing a new `DataFrame`.
///
/// Two rows match when every key column holds an equal value, with the
/// same composite-key encoding `group_by` uses (each cell's
/// `Scalar::to_string`, length-prefixed so the multi-key composite is
/// injective across field boundaries). The one deliberate difference from
/// `group_by`: a **null** key cell matches **nothing** (`null != null`,
/// the SQL / Polars default) — for `Inner` such a left row is dropped, for
/// `Left` it is kept with null right columns. A `Float` `NaN` key is *not*
/// null, so — as in `group_by`, and matching Polars' "NaN compares equal"
/// rule — it renders `"NaN"` and matches other `NaN` keys.
///
/// Output shape:
///   * **columns** = the left columns (original order and names) followed
///     by the right frame's columns (original order). Whether each right
///     **key** column is kept is governed by `options.coalesce` (`None` =
///     auto by `how`, matching Polars: an inner join coalesces, a left join
///     does not). When coalesced, the key appears once, taken from the left
///     (keeping the left dtype). When not coalesced, the right key column is
///     kept too — it clashes with the left key name, so it gains
///     `options.suffix` (e.g. `id_right`) and is null wherever a left row
///     had no match. Any other right column whose name occurs in the left
///     frame is likewise suffixed; the left column keeps its name.
///   * **rows** = left rows in their original order; within one left row,
///     its right matches appear in ascending right-row order. `Inner`
///     emits only matched pairs; `Left` additionally emits every
///     unmatched left row once, with the right columns null. The order is
///     fully determined by the input order, so results are
///     snapshot-stable.
///
/// An empty `options.on` is a **cross join**: with no key cells every left
/// row's key is the empty composite, which matches every (non-null-keyed,
/// i.e. every) right row, so the output is the Cartesian product. This is
/// the natural dual of `group_by([])`'s grand-total group.
///
/// The result routes through `DataFrame::new`, so it satisfies
/// `check_invariants()`.
///
/// Raises:
/// - `ColumnNotFound(name)` — a key in `options.on` is absent from `self`
///   or from `other`. Reported on the first offending key, in `on` order,
///   checking the left frame before the right for each key.
/// - `TypeMismatch(detail)` — a key column's dtype differs between the two
///   frames (so its values could never compare equal). Reported on the
///   first such key, in `on` order.
/// - `DuplicateColumn(name)` — two output columns still collide after
///   suffixing (e.g. the left frame already has both `value` and
///   `value_right`, and the right contributes a non-key `value`). Surfaced
///   by `DataFrame::new`.
pub fn DataFrame::join(
  self : DataFrame,
  other : DataFrame,
  options : JoinOptions,
) -> DataFrame raise @types.DataError {
  // Resolve each key in both frames once, validating existence (in `on`
  // order, left before right) and matching dtypes up front. `get_column`
  // raises `ColumnNotFound`; a dtype clash raises `TypeMismatch`. The
  // per-row key cells are materialised here so the build/probe loops below
  // index by plain `[i]` with no bounds-checked `get`.
  let left_key_scalars : Array[Array[@types.Scalar]] = []
  let right_key_scalars : Array[Array[@types.Scalar]] = []
  for key in options.on {
    let lcol = self.get_column(key)
    let rcol = other.get_column(key)
    if lcol.dtype() != rcol.dtype() {
      raise @types.DataError::TypeMismatch(
        "join key \"" +
        key +
        "\" has dtype " +
        lcol.dtype().to_string() +
        " on the left but " +
        rcol.dtype().to_string() +
        " on the right",
      )
    }
    left_key_scalars.push(lcol.to_scalars())
    right_key_scalars.push(rcol.to_scalars())
  }
  // Hash the right frame: composite key -> matching right row indices, in
  // ascending order (`j` only grows). A right row with a null key cell is
  // unmatchable, so it is never indexed.
  let right_index : Map[String, Array[Int]] = {}
  for j in 0..<other.nrows() {
    match join_row_key(right_key_scalars, j) {
      Some(k) =>
        match right_index.get(k) {
          Some(rows) => rows.push(j)
          None => right_index[k] = [j]
        }
      None => ()
    }
  }
  // Probe each left row in order, accumulating the output row plan as a
  // pair of parallel index vectors: `left_rows[r]` is the left row feeding
  // output row `r`, `right_rows[r]` its right row (`None` for an unmatched
  // left row kept by a `Left` join).
  let left_rows : Array[Int] = []
  let right_rows : Array[Int?] = []
  for i in 0..<self.nrows() {
    // A null left key (`None` from `join_row_key`) and a key with no right
    // entry are the same case: no match.
    let matches = match join_row_key(left_key_scalars, i) {
      Some(k) => right_index.get(k)
      None => None
    }
    match matches {
      Some(rows) =>
        for j in rows {
          left_rows.push(i)
          right_rows.push(Some(j))
        }
      None =>
        match options.how {
          Inner => ()
          Left => {
            left_rows.push(i)
            right_rows.push(None)
          }
        }
    }
  }
  // Assemble the output columns. Left columns keep their name and dtype
  // (`gather_series` is total — every index in `left_rows` is a valid left
  // row). Right non-key columns are gathered with `None -> null` and
  // renamed on a name collision with the left frame.
  let out_cols : Array[Series] = []
  for col in self.column_series() {
    out_cols.push(gather_series(col, left_rows))
  }
  // Resolve key coalescing: an explicit `with_coalesce` wins, else auto by
  // `how` (inner coalesces → key once; left does not → right key kept),
  // matching Polars' `coalesce = None`.
  let coalesce = match options.coalesce {
    Some(b) => b
    None =>
      match options.how {
        Inner => true
        Left => false
      }
  }
  let on_set : Map[String, Unit] = {}
  for k in options.on {
    on_set[k] = ()
  }
  let left_names : Map[String, Unit] = {}
  for n in self.columns() {
    left_names[n] = ()
  }
  for col in other.column_series() {
    // A right key column is dropped only when coalescing (its values are
    // already in the kept left key column); otherwise every right column is
    // emitted, suffixed on a name clash with the left frame — a kept key
    // column always clashes, so it becomes `<key><suffix>`.
    if !(coalesce && on_set.contains(col.name())) {
      let out_name = if left_names.contains(col.name()) {
        col.name() + options.suffix
      } else {
        col.name()
      }
      out_cols.push(gather_series_opt(col, right_rows, out_name))
    }
  }
  DataFrame::new(out_cols)
}

///|
/// Inner join convenience: keep only rows whose `on` keys match in both
/// frames. Equivalent to `self.join(other, JoinOptions::on(on))`.
pub fn DataFrame::inner_join(
  self : DataFrame,
  other : DataFrame,
  on : Array[String],
) -> DataFrame raise @types.DataError {
  self.join(other, JoinOptions::on(on))
}

///|
/// Left join convenience: keep every left row, filling the right columns
/// with nulls where it has no match. Equivalent to
/// `self.join(other, JoinOptions::on(on).with_how(Left))` — so, per the
/// auto-coalesce default, **both** key columns are kept (the right one as
/// `<key><suffix>`, null on unmatched rows); use the options form with
/// `with_coalesce(true)` to merge the key into one column instead.
pub fn DataFrame::left_join(
  self : DataFrame,
  other : DataFrame,
  on : Array[String],
) -> DataFrame raise @types.DataError {
  self.join(other, JoinOptions::on(on).with_how(Left))
}

///|
/// Build row `i`'s composite join key, or `None` if any key cell is null
/// (a null key matches nothing). For non-null cells the encoding matches
/// `group_by`'s `row_group_key`: each cell contributes a length-prefixed
/// `"V" + len + ":" + Scalar::to_string` token, so the composite is
/// injective — `("a", "bc")` and `("ab", "c")` never collide. Both frames
/// run through this same function, so a left and a right key match iff
/// they encode identically (dtypes are pre-checked equal per key, so an
/// `Int` `5` and a `Float` `5.0` are never compared in the first place).
fn join_row_key(key_scalars : Array[Array[@types.Scalar]], i : Int) -> String? {
  let buf = StringBuilder::new()
  for col in key_scalars {
    // `col` has `nrows` cells and `i` ranges over `[0, nrows)`, so the read
    // is in-bounds.
    let sc = col[i]
    if sc.is_null() {
      return None
    }
    let s = sc.to_string()
    buf.write_string("V")
    buf.write_string(s.length().to_string())
    buf.write_string(":")
    buf.write_string(s)
  }
  Some(buf.to_string())
}

///|
/// Gather a column by optional row indices: output cell `k` is
/// `s[idx[k]]` when `idx[k]` is `Some`, or a null cell when it is `None`.
/// Total — the caller (`join`) only ever stores in-bounds right-row
/// indices, and `None` marks an unmatched left row in a `Left` join. The
/// result is named `out_name` (so a colliding right column can be
/// suffixed) and keeps the source dtype, matching on `data()` exactly as
/// the total `gather_series` does.
fn gather_series_opt(
  s : Series,
  idx : Array[Int?],
  out_name : String,
) -> Series {
  let valid = s.storage().validity().to_bools()
  match s.storage().data() {
    @column.ColumnData::Int(a) =>
      Series::from_int_options(
        out_name,
        idx.map(o => {
          match o {
            Some(k) => if valid[k] { Some(a[k]) } else { None }
            None => None
          }
        }),
      )
    @column.ColumnData::Float(a) =>
      Series::from_float_options(
        out_name,
        idx.map(o => {
          match o {
            Some(k) => if valid[k] { Some(a[k]) } else { None }
            None => None
          }
        }),
      )
    @column.ColumnData::Bool(a) =>
      Series::from_bool_options(
        out_name,
        idx.map(o => {
          match o {
            Some(k) => if valid[k] { Some(a[k]) } else { None }
            None => None
          }
        }),
      )
    @column.ColumnData::String(a) =>
      Series::from_string_options(
        out_name,
        idx.map(o => {
          match o {
            Some(k) => if valid[k] { Some(a[k]) } else { None }
            None => None
          }
        }),
      )
  }
}
