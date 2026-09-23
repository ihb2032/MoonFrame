// Bounds validation shared by the two column backends (`BuiltinColumn` and
// `NumericColumn`), so the gather-index checks — and their exact diagnostics
// — are produced from one source rather than duplicated per backend.
//
// One-file-one-test exemption: this shared file has no dedicated test file
// of its own. (doc-guard: unresolved) It is covered through the `BuiltinColumn` /
// `NumericColumn` `take` tests that exercise each rejection path.

///|
/// Validate gather `indices` against a column of length `len`: the first
/// out-of-range index `raise IndexOutOfBounds(idx)`. Shared by both backends'
/// `take` so the diagnostic is identical.
fn validate_gather_indices(
  indices : Array[Int],
  len : Int,
) -> Unit raise @types.DataError {
  for i in indices {
    if i < 0 || i >= len {
      raise @types.DataError::IndexOutOfBounds(i)
    }
  }
}
