///|
/// Equi-join `self` (the left frame) with `other` (the right frame) on
/// the key columns named in `options.on`, producing a new `DataFrame`.
///
/// Two rows match when every key column holds an equal value, using the
/// same composite-`KeyCell`-tuple encoding `group_by` uses (see
/// `frame/row_key.mbt`; the tuple is structurally injective across key
/// columns). The one deliberate difference from `group_by`: a **null** key
/// cell matches **nothing** (`null != null`, the SQL / Polars default) —
/// such an unmatched row is dropped by `Inner` and kept (with the other
/// side's columns null) by `Left` / `Right` / `Outer`. A `Float` `NaN` key
/// is *not* null, so — as in `group_by`, and matching Polars' "NaN compares
/// equal" rule — all `NaN` keys match each other.
///
/// `how` selects which unmatched rows survive:
///   * `Inner` — only matched pairs.
///   * `Left` — matched pairs plus every unmatched **left** row (right
///     columns null).
///   * `Right` — matched pairs plus every unmatched **right** row (left
///     columns null); the mirror of `Left`.
///   * `Outer` — matched pairs plus every unmatched row from **both** sides.
///   * `Cross` — the keyless Cartesian product (see below).
///
/// Output shape:
///   * **columns** = the left columns (original order and names) followed
///     by the right frame's columns (original order). Whether each right
///     **key** column is kept is governed by `options.coalesce` (`None` =
///     auto by `how`, matching Polars: an inner join coalesces, a
///     left / right / outer join does not). When coalesced, the key appears
///     once at the left key's position, taking each row's value from
///     whichever side is present (the left on `Inner` / `Left`, the right
///     on `Right`, the present side per row on `Outer` — the two are equal
///     on a matched pair); the right key column is dropped. When not
///     coalesced, the right key column is kept too — it clashes with the
///     left key name, so it gains `options.suffix` (e.g. `id_right`) and is
///     null wherever its row had no match. Any other right column whose
///     name occurs in the left frame is likewise suffixed; the left column
///     keeps its name.
///   * **rows** = left rows in their original order (each with its right
///     matches in ascending right-row order, then — for `Left` / `Outer` —
///     unmatched left rows in place with null right columns), followed for
///     `Outer` by the unmatched right rows in right-row order. A `Right`
///     join instead emits every right row in right-row order (each with its
///     left matches in ascending left-row order, else the right row alone
///     with null left columns). The order is fully determined by the input
///     order, so results are snapshot-stable.
///
/// `how = Cross` is the **Cartesian product** (every left row paired with
/// every right row); it takes no keys, ignores `coalesce`, and keeps all
/// columns of both frames (suffixing a right column that clashes with a
/// left name). It is the explicit form of what `group_by([])`'s
/// grand-total group is for aggregation.
///
/// The result routes through `DataFrame::new`, so it satisfies
/// `check_invariants()`.
///
/// Raises:
/// - `ColumnNotFound(name)` — a key in `options.on` is absent from `self`
///   or from `other` (a non-`Cross` join). Reported on the first offending
///   key, in `on` order, checking the left frame before the right.
/// - `TypeMismatch(detail)` — a key column's dtype differs between the two
///   frames (so its values could never compare equal). Reported on the
///   first such key, in `on` order.
/// - `InvalidOperation(detail)` — `on` is empty for a non-`Cross` join (use
///   `how = Cross` for a Cartesian product), or non-empty for a `Cross`
///   join (which takes no keys).
/// - `DuplicateColumn(name)` — either a key **repeated in `options.on`**
///   (rejected at the repeat during key resolution, like
///   `group_by([col("id"), col("id")])`), or two output columns still colliding after
///   suffixing (e.g. the left frame already has both `value` and
///   `value_right`, and the right contributes a non-key `value`; surfaced by
///   `DataFrame::new`).
pub fn DataFrame::join(
  self : DataFrame,
  other : DataFrame,
  options : JoinOptions,
) -> DataFrame raise @types.DataError {
  // Build the output row plan as parallel optional-index vectors: for output
  // row `r`, `left_rows[r]` is its left row (`None` = a right row kept with
  // no left match) and `right_rows[r]` its right row (`None` = a left row
  // kept with no right match). At least one side is always `Some`. A `Cross`
  // join is the keyless Cartesian product; the key joins hash one frame by
  // key and probe it with the other.
  let left_rows : Array[Int?] = []
  let right_rows : Array[Int?] = []
  match options.how {
    Cross => {
      // A cross join takes no keys (Polars rejects `on` with `how="cross"`).
      if !options.on.is_empty() {
        raise @types.DataError::InvalidOperation(
          "cross join takes no key columns; got " +
          options.on.length().to_string(),
        )
      }
      // Every left row paired with every right row, both in input order.
      for i in 0..<self.nrows() {
        for j in 0..<other.nrows() {
          left_rows.push(Some(i))
          right_rows.push(Some(j))
        }
      }
    }
    Right => {
      // Mirror of `Left`: hash the LEFT frame by key, then probe it with
      // each right row in order. The row set is every right row — its left
      // matches (in ascending left-row order), else the right row alone with
      // null left columns. Output column order is unchanged (left then
      // right); only the surviving rows differ.
      if options.on.is_empty() {
        raise @types.DataError::InvalidOperation(
          "a non-cross join requires at least one key column in `on`; use how = Cross for a Cartesian product",
        )
      }
      let (left_key_scalars, right_key_scalars) = resolve_join_keys(
        self,
        other,
        options.on,
      )
      // Hash the left frame: composite key -> matching left row indices, in
      // ascending order (`i` only grows). A left row with a null key cell is
      // unmatchable, so it is never indexed.
      let left_index : Map[Array[KeyCell], Array[Int]] = {}
      for i in 0..<self.nrows() {
        match join_row_key(left_key_scalars, i) {
          Some(k) =>
            match left_index.get(k) {
              Some(rows) => rows.push(i)
              None => left_index[k] = [i]
            }
          None => ()
        }
      }
      // Probe each right row in order. A null right key (`None`) and a key
      // with no left entry are the same case: no match, keep the right row
      // with null left columns.
      for j in 0..<other.nrows() {
        let matches = match join_row_key(right_key_scalars, j) {
          Some(k) => left_index.get(k)
          None => None
        }
        match matches {
          Some(rows) =>
            for i in rows {
              left_rows.push(Some(i))
              right_rows.push(Some(j))
            }
          None => {
            left_rows.push(None)
            right_rows.push(Some(j))
          }
        }
      }
    }
    Inner | Left | Outer => {
      // A key join needs at least one key; an empty list would otherwise be
      // a silent Cartesian product — require `how = Cross` for that.
      if options.on.is_empty() {
        raise @types.DataError::InvalidOperation(
          "a non-cross join requires at least one key column in `on`; use how = Cross for a Cartesian product",
        )
      }
      let (left_key_scalars, right_key_scalars) = resolve_join_keys(
        self,
        other,
        options.on,
      )
      // Hash the right frame: composite key -> matching right row indices,
      // in ascending order (`j` only grows). A right row with a null key
      // cell is unmatchable, so it is never indexed.
      let right_index : Map[Array[KeyCell], Array[Int]] = {}
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
      // `Left` / `Outer` keep an unmatched left row (null right); `Inner`
      // drops it. `Outer` additionally appends the unmatched right rows.
      let keep_unmatched_left = match options.how {
        Left | Outer => true
        _ => false
      }
      let emit_unmatched_right = match options.how {
        Outer => true
        _ => false
      }
      // Track which right rows were paired, so `Outer` can emit the rest.
      // Only `Outer` reads this, so `Inner` / `Left` skip both the buffer and
      // the per-match write below.
      let right_matched = if emit_unmatched_right {
        Array::make(other.nrows(), false)
      } else {
        []
      }
      // Probe each left row in order. A null left key (`None`) and a key
      // with no right entry are the same case: no match.
      for i in 0..<self.nrows() {
        let matches = match join_row_key(left_key_scalars, i) {
          Some(k) => right_index.get(k)
          None => None
        }
        match matches {
          Some(rows) =>
            for j in rows {
              left_rows.push(Some(i))
              right_rows.push(Some(j))
              if emit_unmatched_right {
                right_matched[j] = true
              }
            }
          None =>
            if keep_unmatched_left {
              left_rows.push(Some(i))
              right_rows.push(None)
            }
        }
      }
      // Full outer: append every right row that never paired, in right-row
      // order, with null left columns.
      if emit_unmatched_right {
        for j in 0..<other.nrows() {
          if !right_matched[j] {
            left_rows.push(None)
            right_rows.push(Some(j))
          }
        }
      }
    }
  }
  // Resolve key coalescing: an explicit `with_coalesce` wins, else auto by
  // `how` (inner coalesces → key once; left / right / outer / cross do not),
  // matching Polars' `coalesce = None`. `on_set` is empty for a cross join,
  // so the value is moot there.
  let coalesce = match options.coalesce {
    Some(b) => b
    None =>
      match options.how {
        Inner => true
        _ => false
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
  // Assemble the output columns. Left columns are gathered with `None ->
  // null` (a kept unmatched-right row has no left cell). A coalesced key
  // sits in its left position but draws each cell from whichever side is
  // present (`coalesce_into`); the matching right key column is then dropped
  // below.
  //
  // Each assembled column is re-converged to its source's backend with
  // `preserve_backend`, so a `Numeric` source column that picks up no null
  // (no `None` row injected on this side, and `Numeric` sources carry none
  // of their own) stays on the `Numeric` fast path rather than silently
  // demoting to `Builtin` — matching `filter` / `sort` / `take` /
  // `drop_nulls` / `fill_null`, which all preserve the backend. A column
  // that does pick up a null (an unmatched row's `None`) is necessarily
  // nullable and stays `Builtin`. The coalesced key follows the **left** key
  // column's backend (its values share the pre-checked-equal key dtype).
  let out_cols : Array[Series] = []
  for col in self.column_series() {
    if coalesce && on_set.contains(col.name()) {
      // `other` has this key (validated above), so `get_column`'s
      // `ColumnNotFound` is forwarded but never taken.
      let left_key = gather_series_opt(col, left_rows, col.name())
      let right_key = gather_series_opt(
        other.get_column(col.name()),
        right_rows,
        col.name(),
      )
      out_cols.push(
        preserve_backend(col, coalesce_into(left_key, right_key, col.name())),
      )
    } else {
      out_cols.push(
        preserve_backend(col, gather_series_opt(col, left_rows, col.name())),
      )
    }
  }
  // Right columns are gathered with `None -> null` and renamed on a name
  // collision with the left frame. A right key column is dropped only when
  // coalescing (its values are already in the kept key); otherwise every
  // right column is emitted, suffixed on a clash — a kept key column always
  // clashes, so it becomes `<key><suffix>`.
  for col in other.column_series() {
    if !(coalesce && on_set.contains(col.name())) {
      let out_name = if left_names.contains(col.name()) {
        col.name() + options.suffix
      } else {
        col.name()
      }
      out_cols.push(
        preserve_backend(col, gather_series_opt(col, right_rows, out_name)),
      )
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
/// Right join convenience: the mirror of `left_join` — keep every right
/// row, filling the left columns with nulls where it has no match.
/// Equivalent to `self.join(other, JoinOptions::on(on).with_how(Right))` —
/// so, per the auto-coalesce default, **both** key columns are kept (the
/// right one as `<key><suffix>`); use the options form with
/// `with_coalesce(true)` to merge the key into one column (taken from the
/// always-present right side).
pub fn DataFrame::right_join(
  self : DataFrame,
  other : DataFrame,
  on : Array[String],
) -> DataFrame raise @types.DataError {
  self.join(other, JoinOptions::on(on).with_how(Right))
}

///|
/// Outer (full) join convenience: keep matched pairs plus every unmatched
/// row from both sides, the missing side's columns null. Equivalent to
/// `self.join(other, JoinOptions::on(on).with_how(Outer))` — so, per the
/// auto-coalesce default, **both** key columns are kept (the right one as
/// `<key><suffix>`); use the options form with `with_coalesce(true)` to
/// merge the key into one column, taking each row's value from whichever
/// side is present (a full-outer row can be present on either side only).
pub fn DataFrame::outer_join(
  self : DataFrame,
  other : DataFrame,
  on : Array[String],
) -> DataFrame raise @types.DataError {
  self.join(other, JoinOptions::on(on).with_how(Outer))
}

///|
/// Cross join convenience: the Cartesian product of `self` and `other`
/// (every left row paired with every right row), with no key columns.
/// Equivalent to `self.join(other, JoinOptions::cross())`. A right column
/// whose name clashes with a left one gains the default `"_right"` suffix;
/// use the options form (`JoinOptions::cross().with_suffix(...)`) to change
/// it.
pub fn DataFrame::cross_join(
  self : DataFrame,
  other : DataFrame,
) -> DataFrame raise @types.DataError {
  self.join(other, JoinOptions::cross())
}

///|
/// Resolve and materialise the join key columns of both frames. Validates
/// that each key in `on` exists in **both** (the left checked before the
/// right, in `on` order) and that its dtype matches across the two frames
/// (so the values could compare equal), then returns the per-key left and
/// right cell vectors (`to_scalars`, total — callers index by plain `[i]`).
/// Shared by the `Right` and `Inner` / `Left` / `Outer` row planners.
///
/// Raises:
/// - `DuplicateColumn(name)` — `name` appears twice in `on`. Reported at the
///   repeat, in `on` order, mirroring `group_by`'s key-list contract (a
///   repeated key would otherwise resolve to the same column twice, the
///   second occurrence silently redundant). Like `group_by`, a key that is
///   *missing* surfaces as `ColumnNotFound` at its first appearance before a
///   later duplicate is examined.
/// - `ColumnNotFound(name)` — a key absent from `left` or `right`, first
///   offending key in `on` order (left before right).
/// - `TypeMismatch(detail)` — a key whose dtype differs between the frames,
///   first such key in `on` order.
fn resolve_join_keys(
  left : DataFrame,
  right : DataFrame,
  on : Array[String],
) -> (Array[Array[@types.Scalar]], Array[Array[@types.Scalar]]) raise @types.DataError {
  let left_key_scalars : Array[Array[@types.Scalar]] = []
  let right_key_scalars : Array[Array[@types.Scalar]] = []
  // The running `seen` set raises `DuplicateColumn` at a key repeated in
  // `on` — before its columns are resolved a second time — so `join` matches
  // `group_by` / `select`'s "no duplicate keys" contract instead of silently
  // treating `["id", "id"]` as the single key `["id"]`. Checked before the
  // lookups, so a *missing* repeated key still surfaces as `ColumnNotFound`
  // at its first appearance.
  let seen : Map[String, Unit] = {}
  for key in on {
    if seen.contains(key) {
      raise @types.DataError::DuplicateColumn(key)
    }
    seen[key] = ()
    let lcol = left.get_column(key)
    let rcol = right.get_column(key)
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
  (left_key_scalars, right_key_scalars)
}

///|
/// Gather a column by optional row indices: output cell `k` is
/// `s[idx[k]]` when `idx[k]` is `Some`, or a null cell when it is `None`.
/// Total — the caller (`join`) only ever stores in-bounds row indices, and
/// `None` marks a row kept without a match on this side. The result is named
/// `out_name` (so a colliding right column can be suffixed) and keeps the
/// source dtype. It always materialises through the option constructors (the
/// shared `rebuild_options` skeleton → a `Builtin` column); `join` wraps the
/// result in `preserve_backend` to re-converge a no-null gather of a `Numeric`
/// source back onto the fast path.
fn gather_series_opt(
  s : Series,
  idx : Array[Int?],
  out_name : String,
) -> Series {
  let valid = validity_bools(s.storage())
  // Output cell `k` reads source row `idx[k]` when it is `Some` (and the cell
  // there is valid), else a null. The four closures are identical bar their
  // element type; `rebuild_options` picks the one matching `s`'s dtype.
  rebuild_options(
    s,
    out_name,
    idx.length(),
    (a, k) => {
      match idx[k] {
        Some(j) => if valid[j] { Some(a[j]) } else { None }
        None => None
      }
    },
    (a, k) => {
      match idx[k] {
        Some(j) => if valid[j] { Some(a[j]) } else { None }
        None => None
      }
    },
    (a, k) => {
      match idx[k] {
        Some(j) => if valid[j] { Some(a[j]) } else { None }
        None => None
      }
    },
    (a, k) => {
      match idx[k] {
        Some(j) => if valid[j] { Some(a[j]) } else { None }
        None => None
      }
    },
  )
}

///|
/// Merge two gathered, equal-dtype, equal-length key columns into one,
/// taking `base`'s cell where it is non-null and `fill`'s otherwise. Used
/// for a coalesced join key: `base` is the left key gathered over the output
/// rows, `fill` the right key. On a matched row the two are equal, so the
/// choice only shows where the row is present on a single side (`base` null
/// → take `fill`); a row null on **both** sides (a kept null-keyed row)
/// stays null. Builds through the shared `rebuild_options` skeleton
/// (dispatching on `base`'s storage variant once), reading `fill` through the
/// total `to_scalars` so no unreachable error arm is introduced — the
/// pre-checked equal key dtype guarantees the matching `Scalar` variant, the
/// `_` arm catching only the both-null case.
fn coalesce_into(base : Series, fill : Series, name : String) -> Series {
  let base_valid = validity_bools(base.storage())
  let fills = fill.to_scalars()
  // Each output cell takes `base`'s value where present, else `fill`'s; a
  // both-null cell falls through both to a null. The four closures differ only
  // in the `Scalar` variant they read `fill` as.
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
