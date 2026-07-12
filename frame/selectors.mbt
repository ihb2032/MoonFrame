// Column-selector helpers. Each reads a frame's schema and returns the
// `Array[@expr.Expr]` of `col(name)` references for the columns it matches, to
// fill a verb's expression container — `select` / `drop` / `with_columns` /
// `group_by` all take `Array[Expr]`, so a selector names a set of columns by a
// rule instead of one by one:
//
//   df.select(numeric_cols(df))          // every Int / Float column
//   df.drop(cols_matching(df, "_tmp$"))  // every column whose name ends "_tmp"
//   df.select(cols_of_dtype(df, DataType::String))
//
// The result is an ordinary `Array[Expr]` in schema order, so it composes with
// hand-written `col(...)` entries (`df.select([col("id"), ..numeric_cols(df)])`)
// and carries no new machinery. Selecting from `df` reads `df.schema()`, so the
// same frame appears twice at the call site — the price of an eager,
// build-time expansion (a lazy `LazyFrame` has no schema until `collect`).

///|
/// Whether `dtype` is one of the numeric dtypes (`Int` / `Float`) — the rule
/// behind `numeric_cols`. Wildcard-free, so a future dtype must decide its
/// numeric-ness here.
fn is_numeric_dtype(dtype : @types.DataType) -> Bool {
  match dtype {
    @types.DataType::Int | @types.DataType::Float => true
    @types.DataType::Bool | @types.DataType::String | @types.DataType::Null =>
      false
  }
}

///|
/// The `col(name)` references of every column of `df` whose `Field` satisfies
/// `keep`, in schema order — the shared driver behind the public selectors.
fn cols_where(
  df : DataFrame,
  keep : (@types.Field) -> Bool,
) -> Array[@expr.Expr] {
  let out : Array[@expr.Expr] = []
  for field in df.schema().fields() {
    if keep(field) {
      out.push(@expr.col(field.name()))
    }
  }
  out
}

///|
/// The `col(...)` references of every **numeric** (`Int` / `Float`) column of
/// `df`, in schema order — Polars' `cs.numeric()`. `df.select(numeric_cols(df))`
/// keeps only the numeric columns.
pub fn numeric_cols(df : DataFrame) -> Array[@expr.Expr] {
  cols_where(df, field => is_numeric_dtype(field.dtype()))
}

///|
/// The `col(...)` references of every column of `df` whose dtype is exactly
/// `dtype`, in schema order — Polars' `cs.by_dtype(dtype)`. An empty array when
/// no column has that dtype.
pub fn cols_of_dtype(
  df : DataFrame,
  dtype : @types.DataType,
) -> Array[@expr.Expr] {
  cols_where(df, field => field.dtype() == dtype)
}

///|
/// The `col(...)` references of every column of `df` whose **name** matches the
/// POSIX regular expression `pattern` (a partial match, like `str_contains_regex`)
/// — Polars' `cs.matches(pattern)`. The dialect is POSIX (`[[:alpha:]]`, not the
/// PCRE `\w`), and an invalid pattern raises `InvalidOperation`. Schema order;
/// empty when nothing matches.
pub fn cols_matching(
  df : DataFrame,
  pattern : String,
) -> Array[@expr.Expr] raise @types.DataError {
  let re = compile_regex(pattern)
  cols_where(df, field => re.execute(field.name()) is Some(_))
}

///|
/// The `col(...)` references of every column of `df` whose **name** starts with
/// the literal `prefix`, in schema order — Polars' `cs.starts_with(prefix)`. A
/// literal (not regex) test, so — unlike `cols_matching` — it is **total**.
/// Empty when nothing matches; an empty `prefix` matches every column.
pub fn cols_starts_with(df : DataFrame, prefix : String) -> Array[@expr.Expr] {
  cols_where(df, field => field.name().has_prefix(prefix))
}

///|
/// The `col(...)` references of every column of `df` whose **name** ends with
/// the literal `suffix`, in schema order — Polars' `cs.ends_with(suffix)`. A
/// literal test, so **total**. Empty when nothing matches; an empty `suffix`
/// matches every column.
pub fn cols_ends_with(df : DataFrame, suffix : String) -> Array[@expr.Expr] {
  cols_where(df, field => field.name().has_suffix(suffix))
}

///|
/// The `col(...)` references of every column of `df` whose **name** contains the
/// literal `substr`, in schema order — Polars' `cs.contains(substr)`. A literal
/// substring test, so **total**. Empty when nothing matches; an empty `substr`
/// matches every column.
pub fn cols_contains(df : DataFrame, substr : String) -> Array[@expr.Expr] {
  cols_where(df, field => field.name().contains(substr))
}
