// Blackbox tests for the column selectors (`numeric_cols` / `cols_of_dtype` /
// `cols_matching` and the literal name selectors `cols_starts_with` /
// `cols_ends_with` / `cols_contains`): each returns the `col(...)` list for the
// matching columns in schema order, empty when nothing matches, and composes
// with the eager verbs.

///|
/// A 5-column frame spanning every dtype, with two `name_*` columns so a name
/// regex has something to anchor on.
fn mixed_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("id", [1, 2]),
    Series::from_floats("price", [1.5, 2.5]),
    Series::from_strings("name_a", ["x", "y"]),
    Series::from_bools("flag", [true, false]),
    Series::from_strings("name_b", ["p", "q"]),
  ])
}

///|
test "numeric_cols selects the Int and Float columns in schema order" {
  let df = mixed_df()
  assert_eq(numeric_cols(df), [@expr.col("id"), @expr.col("price")])
  // Filling a `select`: only the numeric columns survive.
  assert_eq(df.select(numeric_cols(df)).columns(), ["id", "price"])
}

///|
test "cols_of_dtype selects an exact dtype; empty when none match" {
  let df = mixed_df()
  assert_eq(cols_of_dtype(df, @types.DataType::String), [
    @expr.col("name_a"),
    @expr.col("name_b"),
  ])
  assert_eq(cols_of_dtype(df, @types.DataType::Bool), [@expr.col("flag")])
  // No Null-dtype column exists, so the selector is empty.
  assert_eq(cols_of_dtype(df, @types.DataType::Null), [])
}

///|
test "cols_matching selects by a POSIX name regex, in schema order" {
  let df = mixed_df()
  // `^name_` matches both name columns.
  assert_eq(df.select(cols_matching(df, "^name_")).columns(), [
    "name_a", "name_b",
  ])
  // Anchored suffix, and a no-match pattern.
  assert_eq(cols_matching(df, "_b$"), [@expr.col("name_b")])
  assert_eq(cols_matching(df, "zzz"), [])
}

///|
test "cols_matching raises InvalidOperation on an invalid pattern" {
  let df = mixed_df()
  assert_true(
    (Ok(cols_matching(df, "[")) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "cols_starts_with selects by a literal name prefix, in schema order" {
  let df = mixed_df()
  assert_eq(cols_starts_with(df, "name_"), [
    @expr.col("name_a"),
    @expr.col("name_b"),
  ])
  // Filling a `select` keeps just those columns.
  assert_eq(df.select(cols_starts_with(df, "name_")).columns(), [
    "name_a", "name_b",
  ])
  // No match → empty; an empty prefix matches every column.
  assert_eq(cols_starts_with(df, "z"), [])
  assert_eq(cols_starts_with(df, "").length(), 5)
}

///|
test "cols_ends_with selects by a literal name suffix, in schema order" {
  let df = mixed_df()
  assert_eq(cols_ends_with(df, "_a"), [@expr.col("name_a")])
  // A non-name column anchors too: only `price` ends in "e".
  assert_eq(cols_ends_with(df, "e"), [@expr.col("price")])
  assert_eq(cols_ends_with(df, "zzz"), [])
}

///|
test "cols_contains selects by a literal name substring, in schema order" {
  let df = mixed_df()
  assert_eq(cols_contains(df, "ame"), [@expr.col("name_a"), @expr.col("name_b")])
  // Composes as a `drop` argument: drop both name columns.
  assert_eq(df.drop(cols_contains(df, "ame")).columns(), ["id", "price", "flag"])
  assert_eq(cols_contains(df, "zzz"), [])
}

///|
test "selectors compose with hand-written col entries, preserving order" {
  let df = mixed_df()
  // A bare column first, then the numeric selector spread after it.
  let sel = [@expr.col("name_a"), ..numeric_cols(df)]
  assert_eq(df.select(sel).columns(), ["name_a", "id", "price"])
  // As a `drop` argument too: drop the numeric columns.
  assert_eq(df.drop(numeric_cols(df)).columns(), ["name_a", "flag", "name_b"])
}
