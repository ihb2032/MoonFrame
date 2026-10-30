// Composite group / join key encoding. `Series::n_unique` and
// `group_by` / `join` (whose row-key builder constructs
// per-row keys from `key_cell`) all partition cells by one or more key values;
// this module turns a single key cell into a value that hashes and compares
// correctly as a `Map` key. It replaces the earlier per-row `Scalar::to_string`
// key, which built a length-prefixed string (`"V" + len + ":" + value`) per
// row — an allocation and, for `Int` / `Float` keys, a decimal-string
// conversion on every cell. The key is now a `KeyCell` keyed on the native cell
// value, so a numeric key hashes its `Int64` / `Double` directly; the `Map`'s
// own hash-then-equality resolution is the collision fallback. Two
// normalisations keep the previous string-key semantics exactly:
//   * a `Float` `NaN` collapses to one key (`KNaN`) — every NaN rendered
//     `"NaN"` before, so all NaNs shared a group / matched each other;
//   * `-0.0` folds into `+0.0` (`KFloat(0.0)`) — both rendered `"0"`
//     before (and IEEE treats them equal). Without this fold, `-0.0` and
//     `+0.0` hash to distinct `KFloat` keys.
// Multi-key injectivity is structural on the `frame` side: a tuple `[a, b]`
// equals only another `[a, b]`, so distinct key tuples never collide the way a
// naive delimiter-joined string might.
//
// One-file-one-test exemption: this internal encoding has no dedicated
// test file of its own. (doc-guard: unresolved) It is exercised to full coverage through `n_unique`
// here and the `group_by` / `join` blackbox tests in `frame` that depend on it.

///|
/// One cell of a composite key, normalised for hashing / equality. Kept
/// separate from `Scalar` because keying needs `NaN` to collapse and
/// `-0.0` to fold — both differ from `Scalar`'s IEEE-following `Eq` — and a
/// key never needs `Scalar`'s numeric-promotion comparisons. `KNull` lets
/// `group_by` give a null cell its own group; `join` rejects a null key
/// before building the tuple.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
enum KeyCell {
  KNull
  KInt(Int64)
  KFloat(Double)
  KNaN
  KBool(Bool)
  KStr(String)
} derive(Eq, Hash)

///|
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub extend KeyCell with Eq::{equal, not_equal}

///|
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub extend KeyCell with Hash::{hash, hash_combine}

///|
/// Normalise a `Float` key value to its `KeyCell`: `NaN` collapses to `KNaN`
/// (so every NaN shares one group / key) and `-0.0` folds into the canonical
/// `KFloat(0.0)` (`-0.0 == 0.0`, and both rendered `"0"` under the old string
/// key). Shared by `key_cell` below and `count_distinct`'s native-`Double`
/// reader so `n_unique` / `group_by` / `join` agree, cell for
/// cell, on what counts as one distinct value.
fn float_key_cell(v : Double) -> KeyCell {
  if v.is_nan() {
    KNaN
  } else if v == 0.0 {
    KFloat(0.0)
  } else {
    KFloat(v)
  }
}

///|
/// The whole column's key cells, read off the typed buffer directly — the
/// same per-cell encoding a `Scalar` normalises to (the `float_key_cell`
/// fold on the `F64` arm, raw `KInt` / `KBool` / `KStr` on the others),
/// without materialising the boxed `Scalar` layer in between. The key
/// builder of the group / join / unique paths: what was
/// `column.to_scalars()` then per-cell normalisation becomes one pass
/// here, sharing `count_distinct`'s reader arms so "one key cell" has one
/// spelling per buffer across every consumer.
///
/// Two folds carry premises other code argues from, stated where the fold
/// happens: `NaN` folds to one cell *without* its payload, sound for
/// consumers only because no operator can observe a NaN's payload bits
/// (the predicate pass's aggregate crossing leans on this when it argues
/// a folded group shares one verdict); and a `Decimal` cell keys on the
/// unscaled magnitude *dropping its scale*, injective only because a
/// column's scale is uniform — the dtype carries it. A consumer that
/// could mix scales in one column or read a NaN's payload must not key
/// through here unchanged.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Series::key_cells(self : Series) -> Array[KeyCell] {
  let storage = self.storage()
  let present = reduce_present(storage)
  let n = self.len()
  let key_of : (Int32) -> KeyCell = match storage.data() {
    @column.ColumnData::I64(a) => i => KInt(a[i])
    @column.ColumnData::F64(a) => i => float_key_cell(a[i])
    @column.ColumnData::Bool(a) => i => KBool(a[i])
    @column.ColumnData::Utf8(a) => i => KStr(a.get(i))
  }
  Array::makei(n, i => if present(i) { key_of(i) } else { KNull })
}

///|
/// Normalise one key cell to its `KeyCell`. The per-column path reads the
/// buffer directly (`Series::key_cells`); this single-cell spelling serves
/// the one consumer that already holds a boxed cell of its own — `mode`'s
/// windowed reduction, whose cell read is window-indexed rather than
/// column-whole — so the one caller lives in this package and the
/// spelling stays private. The folds' premises are stated on `key_cells`.
fn key_cell(sc : @types.Scalar) -> KeyCell {
  match sc {
    @types.Scalar::Int(v) => KInt(v)
    @types.Scalar::Float(v) => float_key_cell(v)
    @types.Scalar::Bool(v) => KBool(v)
    @types.Scalar::String(v) => KStr(v)
    @types.Scalar::Date(v) => KInt(v)
    @types.Scalar::Timestamp(v) => KInt(v)
    @types.Scalar::Decimal(_, v) => KInt(v)
    @types.Scalar::Null => KNull
  }
}

///|
/// Whether this key cell is the null bucket's — the join key builder's
/// unmatchable-cell test.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn KeyCell::is_null(self : KeyCell) -> Bool {
  self == KNull
}
