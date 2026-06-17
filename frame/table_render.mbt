// Shared table-rendering primitives for `DataFrame::to_html` and
// `DataFrame::to_markdown`. Both materialise the same visible window of cells
// and report the same truncation count; only the surrounding syntax (an HTML
// `<table>` vs a GFM pipe table) and the per-cell escaping differ, so the parts
// that don't differ live here once rather than once per renderer. (The row-cap
// clamp they also share is `clamp_take`, reused from `dataframe.mbt`.)

///|
/// Materialise the first `shown` rows of `df` as a row-major matrix of cell
/// strings — `result[r][c]` is column `c`'s value in row `r`, rendered with the
/// value-form of `Scalar::to_string` (a null cell is the empty string). Reads
/// the whole frame once (column-major) through `to_scalar_matrix`, then
/// transposes the visible window into per-row cells. The strings are
/// **unescaped**: each renderer applies its own escaping (HTML entities vs GFM
/// pipe-escaping) on top. `shown <= df.nrows()` and every column has
/// `df.nrows()` cells, so each read is in-bounds. Total.
fn table_cell_matrix(df : DataFrame, shown : Int) -> Array[Array[String]] {
  let col_scalars = df.to_scalar_matrix()
  let ncols = df.ncols()
  Array::makei(shown, r => {
    Array::makei(ncols, c => col_scalars[c][r].to_string())
  })
}

///|
/// The truncation banner text both renderers show when a row cap hides `hidden`
/// rows: `... (N more rows)`. `to_markdown` appends it as a trailing line and
/// `to_html` wraps it in a `<tfoot>` cell, but the wording lives here so the two
/// never drift.
fn more_rows_banner(hidden : Int) -> String {
  "... (" + hidden.to_string() + " more rows)"
}
