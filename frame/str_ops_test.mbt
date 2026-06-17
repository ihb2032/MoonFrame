///|
/// Blackbox tests for the string namespace (`Expr::str_*`) driven through the
/// expression verbs: each operation's per-cell semantics over a String
/// column, null propagation, the non-String `TypeMismatch`, the `Numeric`
/// convergence of the Int-valued `str_len_chars`, and integration with
/// `select` / `filter` / grouped `agg` and the literal broadcast. The
/// rendering / equality / introspection of the nodes themselves live in
/// `expr`'s `expr_str_test.mbt`.

///|
/// A String column mixing cases, surrounding whitespace, and a null cell, so
/// one fixture exercises case, trim, length, the predicates, and substitution.
fn str_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_string_options("s", [
      Some("Hello"),
      Some(" hi "),
      None,
      Some("WORLD"),
    ]),
  ])
}

///|
test "str_to_uppercase / str_to_lowercase: case maps per cell, nulls pass through" {
  let df = str_df()
  let up = df.with_columns([@expr.col("s").str_to_uppercase().with_alias("u")])
  assert_eq(up.get_column("u").to_scalars(), [
    @types.Scalar::String("HELLO"),
    @types.Scalar::String(" HI "),
    @types.Scalar::Null,
    @types.Scalar::String("WORLD"),
  ])
  let lo = df.with_columns([@expr.col("s").str_to_lowercase().with_alias("l")])
  assert_eq(lo.get_column("l").to_scalars(), [
    @types.Scalar::String("hello"),
    @types.Scalar::String(" hi "),
    @types.Scalar::Null,
    @types.Scalar::String("world"),
  ])
}

///|
test "str_strip_chars: trims surrounding whitespace, selected standalone" {
  // Also covers `select`: a `str_*` op stands alone as its own column.
  let out = str_df().select([@expr.col("s").str_strip_chars()])
  assert_eq(out.ncols(), 1)
  assert_eq(out.get_column("s").to_scalars(), [
    @types.Scalar::String("Hello"),
    @types.Scalar::String("hi"),
    @types.Scalar::Null,
    @types.Scalar::String("WORLD"),
  ])
}

///|
test "str_len_chars: counts Unicode characters, all-valid converging onto Numeric" {
  // A supplementary-plane character (`😀`, two UTF-16 code units) counts once.
  let df = DataFrame::new([Series::from_strings("s", ["a", "héllo", "😀"])])
  let out = df.with_columns([@expr.col("s").str_len_chars().with_alias("n")])
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(5),
    @types.Scalar::Int(1),
  ])
  // A computed, all-valid numeric column rides the `Numeric` fast path.
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Numeric)
}

///|
test "str_len_chars: a null cell stays null and keeps the column Builtin" {
  let out = str_df().with_columns([
    @expr.col("s").str_len_chars().with_alias("n"),
  ])
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(5),
    @types.Scalar::Int(4),
    @types.Scalar::Null,
    @types.Scalar::Int(5),
  ])
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Builtin)
}

///|
test "str_contains: a Bool column, the null cell stays null" {
  let out = str_df().with_columns([
    @expr.col("s").str_contains("i").with_alias("c"),
  ])
  assert_eq(out.get_column("c").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
  ])
}

///|
test "str_starts_with / str_ends_with: prefix and suffix predicates" {
  let df = str_df()
  let sw = df.with_columns([
    @expr.col("s").str_starts_with("W").with_alias("sw"),
  ])
  assert_eq(sw.get_column("sw").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(true),
  ])
  let ew = df.with_columns([@expr.col("s").str_ends_with("o").with_alias("ew")])
  assert_eq(ew.get_column("ew").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
  ])
}

///|
test "str_replace / str_replace_all: literal substitution, first vs every, nulls pass through" {
  let df = DataFrame::new([
    Series::from_string_options("s", [Some("a-a-a"), None, Some("a")]),
  ])
  let first = df.with_columns([
    @expr.col("s").str_replace("a", "X").with_alias("f"),
  ])
  assert_eq(first.get_column("f").to_scalars(), [
    @types.Scalar::String("X-a-a"),
    @types.Scalar::Null,
    @types.Scalar::String("X"),
  ])
  let all = df.with_columns([
    @expr.col("s").str_replace_all("a", "X").with_alias("g"),
  ])
  assert_eq(all.get_column("g").to_scalars(), [
    @types.Scalar::String("X-X-X"),
    @types.Scalar::Null,
    @types.Scalar::String("X"),
  ])
}

///|
test "str: a predicate filters rows by a (case-sensitive) string test" {
  let df = str_df()
  // `contains` is literal and case-sensitive: only "Hello" has a lowercase
  // "o" ("WORLD" carries an uppercase "O"); " hi " lacks it, and the null row
  // drops.
  let kept = df.filter(@expr.col("s").str_contains("o"))
  assert_eq(kept.get_column("s").to_scalars(), [@types.Scalar::String("Hello")])
}

///|
test "str: a namespace op wraps an aggregation inside grouped agg" {
  let df = DataFrame::new([
    Series::from_strings("region", ["west", "east", "west"]),
    Series::from_strings("name", ["alice", "bob", "carol"]),
  ])
  // `first(name).str_to_uppercase()` is reduction-shaped (the wrapper sees
  // through to the aggregation), so it is one value per group.
  let out = df
    .group_by([@expr.col("region")])
    .agg([@expr.col("name").first().str_to_uppercase().with_alias("lead")])
  assert_eq(out.get_column("region").to_scalars(), [
    @types.Scalar::String("west"),
    @types.Scalar::String("east"),
  ])
  assert_eq(out.get_column("lead").to_scalars(), [
    @types.Scalar::String("ALICE"),
    @types.Scalar::String("BOB"),
  ])
}

///|
test "str: an op on a literal broadcasts over the frame" {
  // A `str_*` op over a length-1 literal column broadcasts like any other
  // literal — every row receives the same transformed constant.
  let out = str_df().with_columns([
    @expr.lit_str("Raw").str_to_uppercase().with_alias("k"),
  ])
  assert_eq(out.get_column("k").to_scalars(), [
    @types.Scalar::String("RAW"),
    @types.Scalar::String("RAW"),
    @types.Scalar::String("RAW"),
    @types.Scalar::String("RAW"),
  ])
}

///|
test "str: a non-String operand is a TypeMismatch" {
  let df = DataFrame::new([Series::from_ints("n", [1, 2, 3])])
  let result = try? df.with_columns([@expr.col("n").str_to_uppercase()])
  assert_eq(
    result,
    Err(
      @types.DataError::TypeMismatch(
        "string operation requires a String operand, got Int",
      ),
    ),
  )
}
