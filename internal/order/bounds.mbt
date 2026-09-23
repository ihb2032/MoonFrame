///|
/// Clamp a requested row count into `[0, len]`: a negative request yields `0`,
/// a request past the end yields `len`. Every *saturating* row limit goes
/// through here — `Series::head` / `tail`, `DataFrame::head` / `tail`, and the
/// `to_html` / `to_markdown` row caps — so an out-of-range ask means the same
/// thing wherever it is made.
pub fn clamp_take(n : Int, len : Int) -> Int {
  if n < 0 {
    0
  } else if n > len {
    len
  } else {
    n
  }
}

///|
/// The start row of a saturating `slice(offset, …)` window over `len` rows —
/// Polars' offset rule. A negative `offset` counts from the end
/// (`-1` names the last row), saturating at row `0` when it reaches past the
/// first; a non-negative one saturates at `len`. Together with `slice_len`
/// this is the whole of `DataFrame::slice` / `Series::slice`'s window
/// arithmetic: pure integer saturation, the provable core under both verbs.
pub fn slice_start(offset : Int, len : Int) -> Int {
  if offset < 0 {
    clamp_take(len + offset, len)
  } else if offset > len {
    len
  } else {
    offset
  }
}

///|
/// The row count of a saturating `slice(offset, length)` window starting at
/// `start` over `len` rows: an omitted `length` runs to the end; a given one
/// saturates at what remains, and a negative one is an empty window.
pub fn slice_len(start : Int, len : Int, length : Int?) -> Int {
  match length {
    None => len - start
    Some(l) => clamp_take(l, len - start)
  }
}
