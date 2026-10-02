// Vertical concatenation — Polars' `vstack`: the rows of `other` appended
// under `self`'s, one frame on top of the other. The two frames must agree
// column-for-column **by position** — same column count, same dtype in each
// slot — and the output takes `self`'s names and column order (Polars'
// rule: the stacked frame's names do not travel). The dtype check is exact,
// not unifying: an `Int` column does not stack under a `Float` one; cast
// first when the sources differ. Row counts are unconstrained — stacking
// onto a 0-row frame is the schema-preserving way to "concat" — and the
// rebuilt columns re-converge onto the `Numeric` fast path exactly as any
// row gather's do, since the backend follows the assembled content.

///|
/// The rows of `other` appended under `self`'s, as one frame (Polars'
/// `df.vstack(other)`). Raises `TypeMismatch` when the column counts
/// differ, or when any same-position pair of columns carries different
/// dtypes; the message names the count or the first offending column.
pub fn DataFrame::vstack(
  self : DataFrame,
  other : DataFrame,
) -> DataFrame raise @types.DataError {
  if self.ncols() != other.ncols() {
    raise @types.DataError::TypeMismatch(
      @types.TypeMismatchDetail::Message(
        "vstack needs equal column counts: \{self.ncols()} vs \{other.ncols()}",
      ),
    )
  }
  let height = self.nrows() + other.nrows()
  let cols : Array[Series] = []
  for i in 0..<self.ncols() {
    let top = self.get_column_at(i)
    let bottom = other.get_column_at(i)
    let dtype = top.dtype()
    if dtype != bottom.dtype() {
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "vstack column \{i} (\{top.name()}) is \{dtype} but the stacked column is \{bottom.dtype()}",
        ),
      )
    }
    // The concatenated cells project through the shared series builder, so
    // the output keeps the declared dtype and takes the gather-style backend
    // canonicalisation — an all-valid numeric stack lands on `Numeric`.
    let cells = top.to_scalars()
    for c in bottom.to_scalars() {
      cells.push(c)
    }
    cols.push(scalars_to_series(dtype, top.name(), cells))
  }
  DataFrame::from_parts(cols, height)
}
