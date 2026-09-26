// Column-selector methods. Each reads a frame's schema and returns an
// `Array[Expr]` of `col(name)` references for the columns it matches, to
// fill a verb's expression container — `select` / `drop` / `with_columns` /
// `group_by` all take `Array[Expr]`, so a selector names a set of columns by a
// rule instead of one by one:
//
//   df.select(df.numeric_cols())          // every Int / Float column
//   df.drop(df.cols_matching("_tmp$"))    // every column whose name ends "_tmp"
//   df.select(df.cols_of_dtype(DataType::String))
//
// The result is an ordinary `Array[Expr]` in schema order, so it composes with
// hand-written `col(...)` entries (`df.select([col("id"), ..df.numeric_cols()])`)
// and carries no new machinery. Selecting reads `df.schema()` at expansion
// time — the price of an eager, build-time expansion (a lazy `LazyFrame` has
// no schema until `collect`).

///|
/// The `col(name)` references of every column of `df` whose `Field` satisfies
/// `keep`, in schema order — the shared driver behind the public selectors.
fn DataFrame::cols_where(
  self : DataFrame,
  keep : (@types.Field) -> Bool,
) -> Array[@expr.Expr] {
  let out : Array[@expr.Expr] = []
  for field in self.schema().fields() {
    if keep(field) {
      out.push(@expr.col(field.name()))
    }
  }
  out
}

///|
/// The `col(...)` references of every **numeric** (`Int` / `Float`) column of
/// this frame, in schema order — Polars' `cs.numeric()`.
/// `df.select(df.numeric_cols())` keeps only the numeric columns. The
/// registry's numericity flag is the whole test (an `I64`-riding dtype like
/// `Date` is correctly not numeric).
pub fn DataFrame::numeric_cols(self : DataFrame) -> Array[@expr.Expr] {
  self.cols_where(field => field.dtype().is_numeric())
}

///|
/// The `col(...)` references of every column of this frame whose dtype is
/// exactly `dtype`, in schema order — Polars' `cs.by_dtype(dtype)`. An empty
/// array when no column has that dtype.
pub fn DataFrame::cols_of_dtype(
  self : DataFrame,
  dtype : @types.DataType,
) -> Array[@expr.Expr] {
  self.cols_where(field => field.dtype() == dtype)
}

///|
/// The `col(...)` references of every column of this frame whose **name**
/// matches the POSIX regular expression `pattern` (a partial match, like
/// `str_contains(pattern, literal=false)` over cells)
/// — Polars' `cs.matches(pattern)`. The dialect is POSIX (`[[:alpha:]]`, not the
/// PCRE `\w`), and an invalid pattern raises `InvalidOperation`. Schema order;
/// empty when nothing matches.
pub fn DataFrame::cols_matching(
  self : DataFrame,
  pattern : String,
) -> Array[@expr.Expr] raise @types.DataError {
  let re = @kernel.compile_regex(pattern)
  self.cols_where(field => re.execute(field.name()) is Some(_))
}

///|
/// The `col(...)` references of every column of this frame whose **name**
/// starts with the literal `prefix`, in schema order — Polars'
/// `cs.starts_with(prefix)`. A literal (not regex) test, so — unlike
/// `cols_matching` — it is **total**. Empty when nothing matches; an empty
/// `prefix` matches every column.
pub fn DataFrame::cols_starts_with(
  self : DataFrame,
  prefix : String,
) -> Array[@expr.Expr] {
  self.cols_where(field => field.name().has_prefix(prefix))
}

///|
/// The `col(...)` references of every column of this frame whose **name** ends
/// with the literal `suffix`, in schema order — Polars' `cs.ends_with(suffix)`.
/// A literal test, so **total**. Empty when nothing matches; an empty `suffix`
/// matches every column.
pub fn DataFrame::cols_ends_with(
  self : DataFrame,
  suffix : String,
) -> Array[@expr.Expr] {
  self.cols_where(field => field.name().has_suffix(suffix))
}

///|
/// The `col(...)` references of every column of this frame whose **name**
/// contains the literal `substr`, in schema order — Polars' `cs.contains(substr)`.
/// A literal substring test, so **total**. Empty when nothing matches; an
/// empty `substr` matches every column.
pub fn DataFrame::cols_contains(
  self : DataFrame,
  substr : String,
) -> Array[@expr.Expr] {
  self.cols_where(field => field.name().contains(substr))
}
