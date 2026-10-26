///|
/// The next bottom-up merge width, or `None` once the current run already
/// covers at least half of `n`. The guards make this total for every `Int`:
/// subtraction only happens after `0 < width < n`, and doubling only happens
/// when `width < n - width`, which proves `2 * width < n <= Int::MAX`.
/// Keeping this arithmetic separate lets tests exercise the `2^30` boundary
/// without allocating multi-gigabyte sort buffers.
fn next_merge_width(width : Int32, n : Int32) -> Int32? {
  if width <= 0 || n <= 1 || width >= n {
    return None
  }
  if width >= n - width {
    None
  } else {
    Some(width * 2)
  }
}

///|
/// Iterative bottom-up stable merge sort over the index permutation
/// `[0, 1, ..., n - 1]`. Returns the permutation that, when applied to
/// any length-`n` array via `take`, yields the data in `cmp` order.
///
/// Stability comes from the `<= 0` tie-break in `merge_run`: on equal
/// keys, the left run's element is emitted first, which preserves the
/// original relative order (left run came before right run in the
/// input).
///
/// Complexity: `O(n log n)` comparisons, `O(n)` auxiliary memory
/// (two buffers of length `n`, alternating source / destination — each
/// pass fully writes the buffer it merges into, merged pairs and
/// unpaired tail runs alike, so the next pass can read it and no
/// per-pass copy-back is paid).
pub fn stable_mergesort_indices(
  n : Int32,
  cmp : (Int32, Int32) -> Int32,
) -> Array[Int32] {
  let buf = Array::makei(n, i => i)
  if n <= 1 {
    return buf
  }
  let aux = Array::make(n, 0)
  let mut src = buf
  let mut dst = aux
  let mut width = 1
  while width < n {
    let mut start = 0
    while start < n {
      let left = start
      // Derive the run boundaries by subtraction against the room left
      // (`n - start`, `n - mid`) rather than `start + width` / `start + 2*width`,
      // so the arithmetic can't overflow `Int` on a pathologically large `n`
      // (the same overflow-avoidance the validity bitmap uses). `right_end` is the
      // second run's end, so advancing `start` to it equals the old
      // `start + 2*width`: both land at `min(start + 2*width, n)` and end the
      // pass once they reach `n`.
      let mid = if width < n - start { start + width } else { n }
      let right_end = if width < n - mid { mid + width } else { n }
      // A lone left run (mid == n) is carried into `dst` by `merge_run`'s
      // tail loop — every slot of `dst` is written every pass, which is
      // what makes the alternating buffers safe to read next pass.
      merge_run(src, dst, left, mid, right_end, cmp)
      start = right_end
    }
    // Swap the buffers' roles: this pass's destination is the next one's
    // source, so the merged data never rides a copy back.
    let swapped = src
    src = dst
    dst = swapped
    match next_merge_width(width, n) {
      Some(next) => width = next
      None => break
    }
  }
  src
}

///|
/// Merge `src[left..mid)` and `src[mid..right_end)` into
/// `dst[left..right_end)`. Stable: on `cmp(left, right) <= 0`, the
/// left element wins the slot.
fn merge_run(
  src : Array[Int32],
  dst : Array[Int32],
  left : Int32,
  mid : Int32,
  right_end : Int32,
  cmp : (Int32, Int32) -> Int32,
) -> Unit {
  let mut p = left
  let mut q = mid
  let mut k = left
  while p < mid && q < right_end {
    if cmp(src[p], src[q]) <= 0 {
      dst[k] = src[p]
      p = p + 1
    } else {
      dst[k] = src[q]
      q = q + 1
    }
    k = k + 1
  }
  while p < mid {
    dst[k] = src[p]
    p = p + 1
    k = k + 1
  }
  while q < right_end {
    dst[k] = src[q]
    q = q + 1
    k = k + 1
  }
}
