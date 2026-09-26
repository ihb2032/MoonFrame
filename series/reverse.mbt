// The row-order verb: `reverse` reads the series back to front — the
// `Series` twin of `DataFrame::reverse`, one spelling over the same gather
// machine the row-window verbs use.

///|
/// The cells in reverse order, name unchanged — Polars' `Series.reverse`.
/// Total.
pub fn Series::reverse(self : Series) -> Series {
  let len = self.len()
  self.gather_series(Array::makei(len, i => len - 1 - i))
}
