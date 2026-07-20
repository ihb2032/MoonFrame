// Blackbox tests for null filling, split across the two surfaces v0.5
// exposes:
//   * the frame-wide `DataFrame::fill_null(value)`, which fills every
//     dtype-compatible column and leaves the rest verbatim;
//   * the per-column `Expr::fill_null(value)`, driven through `with_columns`
//     — the expression form that lowers to a not-null guarded conditional.

// ── Frame-wide DataFrame::fill_null(value) ───────────────────────────

///|
/// Four columns, one per concrete dtype, each carrying a null so the
/// dtype-compatible / skipped split is observable. Two `Int` columns prove
/// the fill reaches *every* compatible column, not just the first.
fn fill_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("a", [Some(1), None, Some(3)]),
    Series::from_int_options("a2", [None, Some(2), Some(3)]),
    Series::from_float_options("b", [Some(1.5), None, None]),
    Series::from_string_options("s", [Some("x"), None, Some("z")]),
  ])
}

///|
test "fill_null fills every Int column and leaves other dtypes untouched" {
  let df = fill_df()
  let out = df.fill_null(@types.Scalar::Int(0))
  // Both Int columns are filled — the fill reaches all compatible columns.
  assert_eq(out.get_column("a").null_count(), 0)
  assert_eq(out.get_column("a2").null_count(), 0)
  assert_eq(out.item(1, "a"), @types.Scalar::Int(0))
  assert_eq(out.item(0, "a2"), @types.Scalar::Int(0))
  // Float / String columns keep their nulls — they are not Int-compatible.
  assert_eq(out.item(1, "b"), @types.Scalar::Null)
  assert_eq(out.item(1, "s"), @types.Scalar::Null)
  // In-place cell rewrite: names, dtypes, and the row count are unchanged.
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  assert_eq(out.shape(), df.shape())
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fill_null with a Float value fills only the Float columns" {
  let out = fill_df().fill_null(@types.Scalar::Float(0.0))
  assert_eq(out.get_column("b").null_count(), 0)
  assert_eq(out.item(1, "b"), @types.Scalar::Float(0.0))
  // Int / String columns keep their nulls.
  assert_eq(out.item(1, "a"), @types.Scalar::Null)
  assert_eq(out.item(1, "s"), @types.Scalar::Null)
}

///|
test "fill_null with a String value fills only the String columns" {
  let out = fill_df().fill_null(@types.Scalar::String("?"))
  assert_eq(out.get_column("s").null_count(), 0)
  assert_eq(out.item(1, "s"), @types.Scalar::String("?"))
  // Int / Float columns keep their nulls.
  assert_eq(out.item(1, "a"), @types.Scalar::Null)
  assert_eq(out.item(1, "b"), @types.Scalar::Null)
}

///|
test "fill_null with a Bool value fills only the Bool columns" {
  let df = DataFrame::new([
    Series::from_bool_options("flag", [Some(true), None, None]),
    Series::from_int_options("n", [Some(1), None, Some(3)]),
  ])
  let out = df.fill_null(@types.Scalar::Bool(false))
  assert_eq(out.get_column("flag").null_count(), 0)
  assert_eq(out.item(1, "flag"), @types.Scalar::Bool(false))
  assert_eq(out.item(2, "flag"), @types.Scalar::Bool(false))
  // The Int column is left untouched.
  assert_eq(out.item(1, "n"), @types.Scalar::Null)
}

///|
test "fill_null with a Null value is a whole-frame no-op" {
  let df = fill_df()
  // Nothing is compatible with Null (filling nulls with null is meaningless),
  // so every column is skipped and the frame comes back unchanged.
  let out = df.fill_null(@types.Scalar::Null)
  assert_eq(out, df)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fill_null leaves a frame with no compatible nulls structurally identical" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]), // Int, no nulls
    Series::from_strings("s", ["x", "y", "z"]), // String, skipped
  ])
  // The Int value matches `a` (which has no nulls to fill) and skips `s`.
  let out = df.fill_null(@types.Scalar::Int(99))
  assert_eq(out, df)
}

///|
test "fill_null on a 0-row frame stays a 0-row frame" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("s", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  let out = df.fill_null(@types.Scalar::Int(0))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
  assert_eq(out.check_invariants(), Ok(()))
}

// ── Per-column Expr::fill_null(value) through with_columns ────────────

///|
test "Expr fill_null replaces an Int column's nulls in place" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None, Some(3)]),
    Series::from_strings("s", ["x", "y", "z"]),
  ])
  let out = df.with_columns([@expr.col("a").fill_null(@expr.lit_int(0))])
  // The result is named after the filled column, so it replaces `a` in
  // place — the column order and the untouched `s` are unchanged.
  assert_eq(out.columns(), ["a", "s"])
  assert_eq(out.get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(0),
    @types.Scalar::Int(3),
  ])
  assert_eq(out.get_column("a").null_count(), 0)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "Expr fill_null replaces a String column's nulls" {
  let df = DataFrame::new([
    Series::from_string_options("s", [Some("a"), None, Some("c")]),
  ])
  let out = df.with_columns([@expr.col("s").fill_null(@expr.lit_str("?"))])
  assert_eq(out.get_column("s").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::String("?"),
    @types.Scalar::String("c"),
  ])
  assert_eq(out.get_column("s").null_count(), 0)
}

///|
test "Expr fill_null keeps a non-null NaN, filling only true nulls" {
  let nan : Double = @double.not_a_number
  // `b` holds a value, a non-null NaN, then a true null. The NaN has
  // validity 1, so `is_not_null` keeps it; only the null cell is filled.
  let df = DataFrame::new([
    Series::from_float_options("b", [Some(1.0), Some(nan), None]),
  ])
  let out = df.with_columns([@expr.col("b").fill_null(@expr.lit_float(0.0))])
  assert_eq(out.item(0, "b"), @types.Scalar::Float(1.0))
  assert_true(out.item(1, "b").as_float().is_nan()) // NaN preserved, not filled
  assert_eq(out.item(2, "b"), @types.Scalar::Float(0.0)) // null filled
}

///|
test "Expr fill_null coalesces from another column" {
  // When `value` is a column, each null in `a` takes `b`'s cell of the same
  // row — and stays null where `b` is also null (a faithful coalesce).
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None, None]),
    Series::from_int_options("b", [Some(10), Some(20), None]),
  ])
  let out = df.with_columns([
    @expr.col("a").fill_null(@expr.col("b")).with_alias("coalesced"),
  ])
  assert_eq(out.get_column("coalesced").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(20),
    @types.Scalar::Null,
  ])
}

///|
test "Expr fill_null promotes an Int column filled with a Float value" {
  // The branches unify like a ternary's: `Int` meets `Float` by promoting
  // the whole column to `Float`.
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None, Some(3)]),
  ])
  let out = df.with_columns([@expr.col("a").fill_null(@expr.lit_float(0.0))])
  assert_eq(out.get_column("a").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("a").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(3.0),
  ])
}

///|
test "Expr fill_null rejects a non-unifiable fill dtype with TypeMismatch" {
  // Int column, String fill value: the branches cannot unify, so evaluation
  // raises (the ternary's branch-unification error).
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None, Some(3)]),
  ])
  assert_true(
    (Ok(df.with_columns([@expr.col("a").fill_null(@expr.lit_str("x"))])) catch {
      e => Err(e)
    })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

///|
test "Expr fill_null on a missing column raises ColumnNotFound" {
  let df = DataFrame::new([Series::from_ints("a", [1, 2, 3])])
  assert_eq(
    Ok(df.with_columns([@expr.col("missing").fill_null(@expr.lit_int(0))])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}
