///|
/// Index a frame's rows by composite join key: maps each non-null key tuple
/// to the ascending list of row indices that carry it. A row whose key has
/// any null cell is unmatchable (`join_row_key` returns `None`), so it is
/// never indexed. Shared by every `how` so the null-key skip and the
/// bucket-append convention live in one place; bucket order is ascending
/// because the row index only grows. Total.
fn index_by_join_key(
  key_scalars : Array[Array[@types.Scalar]],
  n : Int,
) -> Map[Array[KeyCell], Array[Int]] {
  let index : Map[Array[KeyCell], Array[Int]] = {}
  for i in 0..<n {
    match join_row_key(key_scalars, i) {
      Some(k) =>
        match index.get(k) {
          Some(rows) => rows.push(i)
          None => index[k] = [i]
        }
      None => ()
    }
  }
  index
}

///|
/// Equi-join `self` (the left frame) with `other` (the right frame) on the
/// key **expressions** in `options.on` (or the paired `left_on` /
/// `right_on`), producing a new `DataFrame`.
///
/// Each key is an arbitrary expression, evaluated over the whole frame
/// under the rules in `expr_eval.mbt`, exactly like a `sort` / `group_by`
/// key: `options.on` is applied to both frames (a bare `col("id")` joins on
/// an existing column, a derived key such as `col("ts") / lit_int(86400)`
/// joins on the computed value), while `left_on` / `right_on` evaluate
/// position-paired keys on the left and right frame respectively (for
/// differently-named or differently-derived keys). A key that reduces to a
/// single cell (a literal, or an aggregation) broadcasts over the frame.
///
/// Two rows match when every key holds an equal value, using the same
/// composite-`KeyCell`-tuple encoding `group_by` uses (see
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
///     by the right frame's columns (original order). Coalescing applies
///     only to an `on` join whose every key is a bare `col(...)` (the only
///     shape where a key names the same column on both sides); `left_on` /
///     `right_on` and any derived key never coalesce. Whether an eligible
///     right key column is kept is then governed by `options.coalesce`
///     (`None` = auto by `how`, matching Polars: an inner / left / right join
///     coalesces, an outer join does not). When coalesced, the key appears
///     once at the left key's position, taking each row's value from
///     whichever side is present (the left on `Inner` / `Left`, the right
///     on `Right`, the present side per row on `Outer` — the two are equal
///     on a matched pair); the right key column is dropped. When not
///     coalesced, the right key column is kept too — it clashes with the
///     left key name, so it gains `options.suffix` (e.g. `id_right`) and is
///     null wherever its row had no match. Any other right column whose
///     name occurs in the left frame is likewise suffixed; the left column
///     keeps its name. (A derived key contributes no column of its own — it
///     only decides which rows pair — so the output is just the two frames'
///     columns, the right suffixed on a clash.)
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
/// - `ColumnNotFound(name)` — a key expression references an absent column.
///   Reported on the first offending key, in key order, evaluating the left
///   frame's key before the right's.
/// - `TypeMismatch(detail)` — a key's left and right dtypes differ (so its
///   values could never compare equal), or a derived key's own dtypes don't
///   unify. Reported on the first such key, in key order.
/// - `InvalidOperation(detail)` — no keys for a non-`Cross` join (use
///   `how = Cross` for a Cartesian product), any keys on a `Cross` join
///   (which takes none), both `on` and `left_on` / `right_on` given (they
///   are mutually exclusive), or `left_on` and `right_on` of unequal
///   length.
/// - `DuplicateColumn(name)` — either two keys with the same output name
///   (rejected at the repeat during key resolution, like
///   `group_by([col("id"), col("id")])`), or two output columns still
///   colliding after suffixing (e.g. the left frame already has both
///   `value` and `value_right`, and the right contributes a non-key
///   `value`; surfaced by `DataFrame::new`).
/// - `LengthMismatch` — a `lit_series(s)` key whose embedded series is
///   neither length 1 nor the frame's height (the evaluator's broadcast
///   rule, surfacing through key evaluation).
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
      // A cross join takes no keys (Polars rejects keys with `how="cross"`).
      if !options.on.is_empty() ||
        !options.left_on.is_empty() ||
        !options.right_on.is_empty() {
        raise @types.DataError::InvalidOperation(
          "cross join takes no key columns",
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
      let (left_key_scalars, right_key_scalars) = resolve_join_keys(
        self, other, options,
      )
      // Hash the left frame: composite key -> ascending matching left rows
      // (null-key rows unmatchable, so never indexed).
      let left_index = index_by_join_key(left_key_scalars, self.nrows())
      // Probe each right row in order. A null right key (`None`) and a key
      // with no left entry are the same case: no match, keep the right row
      // with null left columns.
      for j in 0..<other.nrows() {
        let matches = join_row_key(right_key_scalars, j).bind(k => {
          left_index.get(k)
        })
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
      let (left_key_scalars, right_key_scalars) = resolve_join_keys(
        self, other, options,
      )
      // Hash the right frame: composite key -> ascending matching right rows
      // (null-key rows unmatchable, so never indexed).
      let right_index = index_by_join_key(right_key_scalars, other.nrows())
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
        let matches = join_row_key(left_key_scalars, i).bind(k => {
          right_index.get(k)
        })
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
  // Resolve key coalescing. Only an `on` join whose every key is a bare
  // `col(...)` can coalesce — that is the one shape where a key names the
  // same column on both sides (`coalesce_key_names` returns those names);
  // `left_on` / `right_on` and derived keys turn coalescing off. When
  // eligible, an explicit `with_coalesce` wins, else it is auto by `how`
  // (inner / left / right coalesce → key once; outer / cross do not),
  // matching Polars' `coalesce = None`. `on_set` is the set of names to
  // coalesce — empty whenever coalescing is off, so the assembly below
  // keeps every column.
  let coalesce_names = coalesce_key_names(options)
  let coalesce = if coalesce_names is Some(_) {
    options.coalesce.unwrap_or(
      match options.how {
        Inner | Left | Right => true
        _ => false
      },
    )
  } else {
    false
  }
  let on_set : Map[String, Unit] = {}
  if coalesce_names is Some(names) {
    for k in names {
      on_set[k] = ()
    }
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
      // Surface the documented side's value: the left on `Inner` / `Left`, and
      // the present side on `Outer` (the left key is the base — taken where the
      // row has a left match, else the right fills the gap), but the **right**
      // on `Right`, where every output row has the right key present and the
      // left only on matched rows. Folded float keys make the side observable:
      // `-0.0` and `+0.0` share a group, so a `Right` join must surface the
      // right's signed zero, not the left's.
      let merged = match options.how {
        Right => coalesce_into(right_key, left_key, col.name())
        _ => coalesce_into(left_key, right_key, col.name())
      }
      out_cols.push(preserve_backend(col, merged))
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
/// Resolve and materialise the join key columns of both frames. Picks the
/// effective key expressions (`join_key_exprs`: `on` applied to both sides,
/// or the paired `left_on` / `right_on`), evaluates each over its own frame
/// (broadcasting a length-1 key up to frame height, like `sort` /
/// `group_by`), checks the left and right dtypes agree per key (so the
/// values could compare equal), and returns the per-key left and right cell
/// vectors (`to_scalars`, total — callers index by plain `[i]`). Shared by
/// the `Right` and `Inner` / `Left` / `Outer` row planners.
///
/// Raises:
/// - `InvalidOperation(detail)` — no keys at all, both `on` and
///   `left_on` / `right_on` given, or `left_on` / `right_on` of unequal
///   length (all via `join_key_exprs`).
/// - `DuplicateColumn(name)` — a bare `col(name)` key is repeated on an `on`
///   join. Reported at the repeat, in key order, mirroring `group_by`'s
///   key-list contract (a repeated bare `on` key would otherwise be silently
///   redundant). A `left_on` / `right_on` join does *not* check this — a
///   repeated left key is a valid multi-condition join (`a == b AND a == c`).
///   Only bare-`col` keys are checked: derived keys contribute no output
///   column, so two distinct derived keys sharing a leftmost name are different
///   keys, not a collision. Checked before that key is evaluated, so a
///   *missing* repeated key still surfaces as `ColumnNotFound` at its first
///   appearance.
/// - `ColumnNotFound(name)` — a key expression references an absent column,
///   first offending key in key order (the left key evaluated before the
///   right).
/// - `TypeMismatch(detail)` — a key whose left and right dtypes differ (or
///   whose own derived dtypes don't unify), first such key in key order.
/// - `LengthMismatch` — a `lit_series(s)` key whose embedded series is
///   neither length 1 nor the frame's height (the evaluator's broadcast
///   rule).
fn resolve_join_keys(
  left : DataFrame,
  right : DataFrame,
  options : JoinOptions,
) -> (Array[Array[@types.Scalar]], Array[Array[@types.Scalar]]) raise @types.DataError {
  let (left_exprs, right_exprs) = join_key_exprs(options)
  if left_exprs.is_empty() {
    raise @types.DataError::InvalidOperation(
      "a non-cross join requires at least one key column; use how = Cross for a Cartesian product",
    )
  }
  let ln = left.nrows()
  let rn = right.nrows()
  let lscope = Array::makei(ln, i => i)
  let rscope = Array::makei(rn, i => i)
  let left_key_scalars : Array[Array[@types.Scalar]] = []
  let right_key_scalars : Array[Array[@types.Scalar]] = []
  // The running `seen` set raises `DuplicateColumn` at a bare-`col` key
  // repeated by name — before that key is evaluated a second time — so an `on`
  // join matches `group_by`'s "no duplicate keys" contract instead of silently
  // treating two equal keys as one. This applies to `on` only (`dedup`): with
  // `left_on` / `right_on`, a repeated *left* key is a legitimate
  // multi-condition join (`left_on([a, a]).right_on([b, c])` means `a == b AND
  // a == c`, which Polars allows) — the left and right key columns carry their
  // own names, so there is no output-column collision to pre-empt. Only a bare
  // `col(name)` participates even on the `on` path: a *derived* key (any
  // non-`Col` expression) contributes no output column — the output is the two
  // frames' own columns, never the key expressions — so two distinct derived
  // keys that share a leftmost-column name (`col("ts") / day` and
  // `col("ts") % day`) are legitimately different keys and must not collide.
  // Checked before evaluation, so a *missing* repeated key still surfaces as
  // `ColumnNotFound` at its first appearance (its own evaluation fails before
  // the repeat is reached).
  let dedup = options.left_on.is_empty()
  let seen : Map[String, Unit] = {}
  for i in 0..<left_exprs.length() {
    let name = expr_output_name(left_exprs[i])
    if dedup && left_exprs[i] is @expr.Expr::Col(_) {
      if seen.contains(name) {
        raise @types.DataError::DuplicateColumn(name)
      }
      seen[name] = ()
    }
    let lcol = broadcast_series(eval_expr(left_exprs[i], left, lscope), ln)
    let rcol = broadcast_series(eval_expr(right_exprs[i], right, rscope), rn)
    if lcol.dtype() != rcol.dtype() {
      // For `left_on` / `right_on` the two keys can be named differently, so
      // name both sides; an `on` join shares one name and keeps the short form.
      let where_ = if options.left_on.is_empty() {
        "join key \"\{name}\""
      } else {
        "join key \"\{name}\" (left) / \"\{expr_output_name(right_exprs[i])}\" (right)"
      }
      raise @types.DataError::TypeMismatch(
        "\{where_} has dtype \{lcol.dtype()} on the left but \{rcol.dtype()} on the right",
      )
    }
    left_key_scalars.push(lcol.to_scalars())
    right_key_scalars.push(rcol.to_scalars())
  }
  (left_key_scalars, right_key_scalars)
}

///|
/// Choose the effective `(left_keys, right_keys)` expression lists for a
/// non-cross join: `on` is the shorthand for "the same keys on both sides",
/// while `left_on` / `right_on` pair differently-named or -derived keys.
/// The two forms are mutually exclusive, and a `left_on` / `right_on` pair
/// must name the same number of keys. The empty-key case is left to
/// `resolve_join_keys` (which knows the `how = Cross` hint to suggest).
///
/// Raises `InvalidOperation` when both `on` and `left_on` / `right_on` are
/// given, or when `left_on` and `right_on` differ in length.
fn join_key_exprs(
  options : JoinOptions,
) -> (Array[@expr.Expr], Array[@expr.Expr]) raise @types.DataError {
  let has_on = !options.on.is_empty()
  let has_sided = !options.left_on.is_empty() || !options.right_on.is_empty()
  if has_on && has_sided {
    raise @types.DataError::InvalidOperation(
      "join takes either `on` or `left_on` / `right_on`, not both",
    )
  }
  if has_on {
    (options.on, options.on)
  } else {
    if options.left_on.length() != options.right_on.length() {
      raise @types.DataError::InvalidOperation(
        "left_on and right_on must name the same number of keys; got \{options.left_on.length()} and \{options.right_on.length()}",
      )
    }
    (options.left_on, options.right_on)
  }
}

///|
/// The bare-column key names eligible for coalescing, or `None` when this
/// join cannot coalesce. Only an `on` join whose every key is a bare
/// `col(...)` reads the same-named column from both frames — the
/// precondition for merging a key into one output column. `left_on` /
/// `right_on` (paired, possibly differently-named keys) and any derived
/// `on` key turn coalescing off (matching Polars: "join on a non-column
/// expression turns off coalescing"), so both key columns are kept.
fn coalesce_key_names(options : JoinOptions) -> Array[String]? {
  if !options.left_on.is_empty() || !options.right_on.is_empty() {
    return None
  }
  let names = []
  for k in options.on {
    match k {
      @expr.Expr::Col(name) => names.push(name)
      _ => return None
    }
  }
  Some(names)
}

///|
/// The matched source rows when `idx` has no unmatched (`None`) slot and
/// every index lies in `[0, len)`, else `None` — the gate for
/// `gather_series_opt`'s `Numeric` fast path, which reads the raw data array
/// unguarded and so can only fire when every output row provably maps to a
/// real source row. A stray out-of-range index demotes the whole gather to
/// the guarded `_` arm (a null cell there), mirroring `gather_series`'
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
/// Total — the caller (`join`) only ever stores in-bounds row indices, and
/// `None` marks a row kept without a match on this side. The result is named
/// `out_name` (so a colliding right column can be suffixed) and keeps the
/// source dtype. A `Numeric` source with no unmatched (`None`) row takes the
/// all-valid fast path straight onto the `Numeric` backend; everything else
/// materialises through the option constructors (the shared `rebuild_options`
/// skeleton → a `Builtin` column, which `join` re-converges via
/// `preserve_backend`).
fn gather_series_opt(
  s : Series,
  idx : Array[Int?],
  out_name : String,
) -> Series {
  // `Numeric` fast path: a `Numeric` source is all-valid, so a gather with no
  // unmatched (`None`) row is itself all-valid — build the numeric array
  // straight onto the `Numeric` backend, skipping the `Array[T?]` + `Bitmap`
  // round-trip `rebuild_options` would allocate only to drop on re-convergence.
  // Mirrors `gather_series`' `Numeric` arm.
  let matched = if s.storage().kind() is @column.StorageKind::Numeric {
    collect_matched(idx, s.len())
  } else {
    None
  }
  match (s.storage().data(), matched) {
    (@column.ColumnData::Int(a), Some(rows)) =>
      Series::from_ints(out_name, rows.map(j => a[j]))
    (@column.ColumnData::Float(a), Some(rows)) =>
      Series::from_floats(out_name, rows.map(j => a[j]))
    (@column.ColumnData::Int(_) | @column.ColumnData::Float(_), None)
    | (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _) => {
      let validity = s.storage().validity()
      // Output cell `k` reads source row `idx[k]` when it is `Some` (and the
      // cell there is valid), else a null. Read each matched row's validity by
      // O(1) bit lookup (`is_valid_total`) rather than materialising the whole
      // O(source) mask — a high-selectivity join emits far fewer rows than the
      // source has, so the gather stays O(output) (mirrors `gather_series`).
      // The four closures are identical bar their element type; `rebuild_options`
      // picks the one matching `s`'s dtype.
      rebuild_options(
        s,
        out_name,
        idx.length(),
        (a, k) => {
          idx[k].bind(j => {
            if validity.is_valid_total(j) {
              Some(a[j])
            } else {
              None
            }
          })
        },
        (a, k) => {
          idx[k].bind(j => {
            if validity.is_valid_total(j) {
              Some(a[j])
            } else {
              None
            }
          })
        },
        (a, k) => {
          idx[k].bind(j => {
            if validity.is_valid_total(j) {
              Some(a[j])
            } else {
              None
            }
          })
        },
        (a, k) => {
          idx[k].bind(j => {
            if validity.is_valid_total(j) {
              Some(a[j])
            } else {
              None
            }
          })
        },
      )
    }
  }
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
