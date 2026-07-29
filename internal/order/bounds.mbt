///|
/// Clamp a requested row count into `[0, len]`: a negative request yields `0`,
/// a request past the end yields `len`. Every *saturating* row limit goes
/// through here — `Series::head` / `tail`, `DataFrame::head` / `tail`, and the
/// `to_html` / `to_markdown` row caps — so an out-of-range ask means the same
/// thing wherever it is made. A range that validates instead of saturating is
/// a different contract and does not come here: `DataFrame::slice` raises
/// `IndexOutOfBounds` on a window it cannot honour.
pub fn clamp_take(n : Int, len : Int) -> Int {
  if n < 0 {
    0
  } else if n > len {
    len
  } else {
    n
  }
}
