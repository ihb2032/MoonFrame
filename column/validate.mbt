// Bounds validation shared by the two column backends (`BuiltinColumn` and
// `NumericColumn`), so the half-open-slice and gather-index checks — and
// their exact diagnostics — are produced from one source rather than
// duplicated per backend.
//
// One-file-one-test exemption: these helpers have no dedicated
// `validate_test.mbt`. They are covered through the `BuiltinColumn` /
// `NumericColumn` `slice` / `take` tests that exercise each rejection path.

///|
/// Validate a half-open `[start, end)` slice against a column of length
/// `len`, in the order both backends' `slice` rely on:
/// - `IndexOutOfBounds(start)` when `start < 0`.
/// - `IndexOutOfBounds(end)` when `end > len`.
/// - `InvalidOperation("slice start > end: ...")` when `start > end`.
///
/// `start > len` is not a separate case: it can only occur together with
/// `end > len` or `start > end`, both already rejected above. A no-op on a
/// valid window, so each backend calls it and then slices unchecked.
fn validate_slice_bounds(
  start : Int,
  end : Int,
  len : Int,
) -> Unit raise @types.DataError {
  if start < 0 {
    raise @types.DataError::IndexOutOfBounds(start)
  }
  if end > len {
    raise @types.DataError::IndexOutOfBounds(end)
  }
  if start > end {
    raise @types.DataError::InvalidOperation(
      "slice start > end: \{start} > \{end}",
    )
  }
}

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
