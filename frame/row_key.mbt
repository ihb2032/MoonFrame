// Per-row composite group / join keys, shared by `group_by` and `join`. Both
// partition rows by one or more key columns; this module assembles a row's key
// cells into the value that hashes and compares as a `Map` key. The per-cell
// normalisation — `NaN` collapsing to one bucket, `-0.0` folding into `+0.0`,
// the `KeyCell` encoding itself — lives one layer down in `series`
// (`@series.key_cell` / `@series.KeyCell`, bound unqualified through
// `series_use.mbt`), shared there with `Series::n_unique`; this file only
// builds the per-row tuples on top of it. Multi-key injectivity is structural:
// a tuple `[a, b]` equals only another `[a, b]`, so distinct key tuples never
// collide the way a naive delimiter-joined string might.
//
// One-file-one-test exemption: these row-key builders have no dedicated
// `row_key_test.mbt`. They are exercised to full coverage through the
// `group_by` and `join` blackbox tests that depend on them.

///|
/// Build row `i`'s composite group key: one `KeyCell` per key column, in
/// order. A null cell becomes `KNull`, so a null key forms its **own**
/// group — the `group_by` contract, and the deliberate difference from
/// `join`. `col` has `nrows` cells and `i` ranges over `[0, nrows)`, so
/// each `col[i]` read is in-bounds.
fn row_group_key(
  key_scalars : Array[Array[@types.Scalar]],
  i : Int,
) -> Array[KeyCell] {
  key_scalars.map(col => key_cell(col[i]))
}

///|
/// Build row `i`'s composite join key, or `None` if **any** key cell is
/// null (a null key matches nothing — the SQL / Polars default, and join's
/// deliberate difference from `group_by`). Non-null cells use the same
/// `KeyCell` encoding as `row_group_key`, so a left and a right key match
/// iff they encode identically (dtypes are pre-checked equal per key, so an
/// `Int` `5` and a `Float` `5.0` are never compared in the first place).
fn join_row_key(
  key_scalars : Array[Array[@types.Scalar]],
  i : Int,
) -> Array[KeyCell]? {
  let cells : Array[KeyCell] = []
  for col in key_scalars {
    let sc = col[i]
    if sc.is_null() {
      return None
    }
    cells.push(key_cell(sc))
  }
  Some(cells)
}
