// Composite group / join key encoding. `Series::unique_count` (this package)
// and `group_by` / `join` (the `frame` package, whose `row_key.mbt` builds
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
// `key_cell_test.mbt`. It is exercised to full coverage through `unique_count`
// here and the `group_by` / `join` blackbox tests in `frame` that depend on it.

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
pub fn key_cell(sc : @types.Scalar) -> KeyCell {
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
