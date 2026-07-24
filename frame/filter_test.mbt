///|
/// Blackbox behavior tests for `DataFrame::filter`: boolean row selection,
/// the null→drop rule, broadcast (literal / aggregation) predicates,
/// schema and backend preservation, and the evaluation-time error paths.
/// The predicate *evaluation* semantics (comparison dtype matrix, Kleene
/// tables, NaN) live in `expr_eval_test.mbt`; the `map_many` escape hatch
/// that reifies a row-wise host predicate is covered in `expr_map_test.mbt`.

///|
fn where_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("qty", [5, 120, 80, 200]),
    Series::from_strings("region", ["west", "east", "west", "west"]),
  ])
}

///|
test "keeps exactly the rows where the predicate is true" {
  let out = where_df().filter(@expr.col("qty").gt(@expr.lit_int(50)))
  assert_eq(out.get_column("qty").to_scalars(), [
    @types.Scalar::Int(120),
    @types.Scalar::Int(80),
    @types.Scalar::Int(200),
  ])
  assert_eq(out.columns(), ["qty", "region"])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a compound `&` predicate keeps the rows where every clause holds" {
  // Comparison methods bind tighter than `&`, so the two clauses compose
  // into one Bool mask with no parentheses.
  let df = where_df()
  let out = df.filter(
    @expr.col("qty").gt(@expr.lit_int(50)) &
    @expr.col("region").eq(@expr.lit_str("west")),
  )
  assert_eq(out.get_column("qty").to_scalars(), [
    @types.Scalar::Int(80),
    @types.Scalar::Int(200),
  ])
  assert_eq(out.get_column("region").to_scalars(), [
    @types.Scalar::String("west"),
    @types.Scalar::String("west"),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "null predicate cells drop their rows, like false" {
  // Directly null mask cells: a nullable Bool column as the predicate.
  let df = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2, 3]),
    Series::from_bool_options("flag", [Some(true), None, Some(false)]),
  ])
  let out = df.filter(@expr.col("flag"))
  assert_eq(out.get_column("id").to_scalars(), [@types.Scalar::Int(1)])
  // Null comparison cells (null-propagating `ge` over a nullable column)
  // drop their row the same way.
  let df2 = DataFrame::DataFrame([
    Series::from_int_options("x", [Some(10), None, Some(1)]),
  ])
  let out2 = df2.filter(@expr.col("x").ge(@expr.lit_int(5)))
  assert_eq(out2.get_column("x").to_scalars(), [@types.Scalar::Int(10)])
}

///|
test "Kleene predicates: a dominant true keeps, an unknown drops" {
  let df = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2]),
    Series::from_bool_options("a", [Some(true), None]),
    Series::from_bool_options("b", [None, Some(true)]),
  ])
  // true|null and null|true are both true → every row kept.
  assert_eq(df.filter(@expr.col("a") | @expr.col("b")).nrows(), 2)
  // true&null and null&true are both null → every row dropped.
  assert_eq(df.filter(@expr.col("a") & @expr.col("b")).nrows(), 0)
}

///|
test "rejects-everything predicate keeps the schema at zero rows" {
  let df = where_df()
  let out = df.filter(@expr.col("qty").gt(@expr.lit_int(1000)))
  assert_eq(out.shape(), (0, 2))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "length-1 predicates broadcast: literals keep every row or none" {
  let df = where_df()
  assert_eq(df.filter(@expr.lit_bool(true)), df)
  assert_eq(df.filter(@expr.lit_bool(false)).nrows(), 0)
}

///|
test "length-1 predicates broadcast: aggregation comparisons gate the frame" {
  // qty sums to 405: the whole frame passes one threshold, none the other.
  let df = where_df()
  assert_eq(df.filter(@expr.col("qty").sum().gt(@expr.lit_int(100))), df)
  assert_eq(
    df.filter(@expr.col("qty").sum().gt(@expr.lit_int(1000))).nrows(),
    0,
  )
}

///|
test "zero-row frame: column and broadcast predicates both stay empty" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [])])
  assert_eq(df.filter(@expr.col("a").gt(@expr.lit_int(0))).nrows(), 0)
  let out = df.filter(@expr.lit_bool(true))
  assert_eq(out.shape(), (0, 1))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "column backends survive the row filter" {
  let df = DataFrame::DataFrame([
    Series::from_ints("n", [1, 2, 3]),
    Series::from_int_options("m", [Some(1), None, Some(3)]),
  ])
  let out = df.filter(@expr.col("n").gt(@expr.lit_int(1)))
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Numeric)
  assert_eq(out.get_column("m").storage_kind(), @column.StorageKind::Builtin)
}

///|
test "non-Bool predicates raise TypeMismatch" {
  // A frame-tall non-Bool result raises…
  assert_eq(
    Ok(where_df().filter(@expr.col("qty"))) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "filter predicate must be Bool, got Int",
        ),
      ),
    ),
  )
  // …and so does a length-1 non-Bool literal (the broadcast path).
  assert_eq(
    Ok(where_df().filter(@expr.lit_str("west"))) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "filter predicate must be Bool, got String",
        ),
      ),
    ),
  )
}

///|
test "evaluation errors surface: unknown column in the predicate" {
  assert_eq(
    Ok(where_df().filter(@expr.col("zzz").gt(@expr.lit_int(0)))) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
}

///|
test "pipeline: derive with with_columns, then filter on the derived column" {
  // The expression target feel: declare a derived column, then gate rows
  // on it and a second condition with the `&` operator.
  let df = DataFrame::DataFrame([
    Series::from_ints("revenue", [100, 200, 300]),
    Series::from_ints("cost", [150, 120, 100]),
    Series::from_strings("region", ["west", "east", "west"]),
  ])
  let out = df
    .with_columns([
      (@expr.col("revenue") - @expr.col("cost")).with_alias("profit"),
    ])
    .filter(
      @expr.col("profit").gt(@expr.lit_int(0)) &
      @expr.col("region").eq(@expr.lit_str("west")),
    )
  assert_eq(out.get_column("profit").to_scalars(), [@types.Scalar::Int(200)])
  assert_eq(out.get_column("region").to_scalars(), [
    @types.Scalar::String("west"),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}
