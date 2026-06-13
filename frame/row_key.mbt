// Composite group / join key encoding, shared by `group_by` and `join`.
// Both partition rows by one or more key columns; this module turns a
// row's key cells into a value that hashes and compares correctly as a
// `Map` key. It replaces the earlier per-row `Scalar::to_string` key,
// which built a length-prefixed string (`"V" + len + ":" + value`) per
// row — an allocation and, for `Int` / `Float` keys, a decimal-string
// conversion on every cell. The key is now a `KeyCell` tuple keyed on the
// native cell value, so a numeric key hashes its `Int64` / `Double`
// directly; the `Map`'s own hash-then-equality resolution is the
// collision fallback. Two normalisations keep the previous string-key
// semantics exactly:
//   * a `Float` `NaN` collapses to one key (`KNaN`) — every NaN rendered
//     `"NaN"` before, so all NaNs shared a group / matched each other;
//   * `-0.0` folds into `+0.0` (`KFloat(0.0)`) — both rendered `"0"`
//     before (and IEEE treats them equal). Without this fold, `-0.0` and
//     `+0.0` hash to distinct `KFloat` keys.
// Multi-key injectivity is structural: a tuple `[a, b]` equals only
// another `[a, b]`, so distinct key tuples never collide the way a naive
// delimiter-joined string might.
//
// One-file-one-test exemption: this internal encoding has no dedicated
// `row_key_test.mbt`. It is exercised to full coverage through the
// `group_by` and `join` blackbox tests that depend on it.

///|
/// One cell of a composite key, normalised for hashing / equality. Kept
/// separate from `Scalar` because keying needs `NaN` to collapse and
/// `-0.0` to fold — both differ from `Scalar`'s IEEE-following `Eq` — and a
/// key never needs `Scalar`'s numeric-promotion comparisons. `KNull` lets
/// `group_by` give a null cell its own group; `join` rejects a null key
/// before building the tuple (see `join_row_key`).
enum KeyCell {
  KNull
  KInt(Int64)
  KFloat(Double)
  KNaN
  KBool(Bool)
  KStr(String)
} derive(Eq, Hash)

///|
/// Normalise one key cell to its `KeyCell`. The `Float` arm folds `NaN` to
/// `KNaN` and `-0.0` to `KFloat(0.0)` so the key hashes / compares exactly
/// as the previous `Scalar::to_string` key did; the five `Scalar` variants
/// are exhaustive.
fn key_cell(sc : @types.Scalar) -> KeyCell {
  match sc {
    @types.Scalar::Int(v) => KInt(v)
    @types.Scalar::Float(v) =>
      if v.is_nan() {
        KNaN
      } else if v == 0.0 {
        // `-0.0 == 0.0`, so both land here and share the canonical `+0.0`
        // key (they rendered identically under the old string key too).
        KFloat(0.0)
      } else {
        KFloat(v)
      }
    @types.Scalar::Bool(v) => KBool(v)
    @types.Scalar::String(v) => KStr(v)
    @types.Scalar::Null => KNull
  }
}

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
