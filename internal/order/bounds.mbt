///|
/// Clamp a requested row count into `[0, len]`: a negative request yields `0`,
/// a request past the end yields `len`. Every row-count request in the library
/// lands here — `Series::head` / `tail`, `DataFrame::head` / `tail` / `slice`,
/// and the `to_html` / `to_markdown` row caps — so out-of-range asks saturate
/// identically instead of each caller inventing its own bound.
pub fn clamp_take(n : Int, len : Int) -> Int {
  if n < 0 {
    0
  } else if n > len {
    len
  } else {
    n
  }
}
