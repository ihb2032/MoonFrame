///|
/// Blackbox tests for the `Map` escape hatch — `Expr::map_elements` /
/// `map_many` — driven through the expression verbs. Covers single- and
/// multi-input application, the per-row `Scalar` interface (null cells in,
/// null / typed cells out), dtype inference (each backend, the `Numeric`
/// convergence, the all-null / empty `Unsupported`), the literal / aggregation
/// broadcast, closure error propagation, and the multi-input form's use as
/// a `filter` predicate, matching the equivalent native expression.

///|
/// Mixed frame: a nullable Int, an all-valid Int, and a String, exercising
/// the single- / multi-input maps and the null-in / typed-out paths.
fn map_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("q", [Some(1), None, Some(3)]),
    Series::from_ints("base", [10, 20, 30]),
    Series::from_strings("tag", ["a", "b", "c"]),
  ])
}

///|
test "map_elements: applies the closure per row over a column (Int out)" {
  // Double the nullable column; the closure sees `Scalar::Null` for the null
  // cell and decides its own output (here it passes the null through).
  let out = map_df().with_columns([
    @expr.col("q").map_elements(label="double", s => {
      match s {
        @types.Scalar::Int(v) => @types.Scalar::Int(v * 2)
        _ => @types.Scalar::Null
      }
    }),
  ])
  assert_eq(out.get_column("q").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("q").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Null,
    @types.Scalar::Int(6),
  ])
}

///|
test "map_elements: an all-valid numeric result converges onto Numeric" {
  let out = map_df().with_columns([
    @expr.col("base")
    .map_elements(label="half", s => {
      @types.Scalar::Float(s.as_int().to_double() / 2.0)
    })
    .with_alias("half"),
  ])
  assert_eq(out.get_column("half").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("half").to_scalars(), [
    @types.Scalar::Float(5.0),
    @types.Scalar::Float(10.0),
    @types.Scalar::Float(15.0),
  ])
  // A computed, all-valid numeric column rides the `Numeric` fast path — the
  // expression engine's backend convention.
  assert_eq(out.get_column("half").storage_kind(), @column.StorageKind::Numeric)
}

///|
test "map_many: combines several inputs row by row (heterogeneous dtypes)" {
  // The closure receives one cell per input, in order — an Int and a String.
  let out = map_df().with_columns([
    @expr.map_many(label="label", [@expr.col("base"), @expr.col("tag")], vs => {
      @types.Scalar::String(vs[0].to_string() + "-" + vs[1].as_string())
    }).with_alias("combo"),
  ])
  assert_eq(out.get_column("combo").dtype(), @types.DataType::String)
  assert_eq(out.get_column("combo").to_scalars(), [
    @types.Scalar::String("10-a"),
    @types.Scalar::String("20-b"),
    @types.Scalar::String("30-c"),
  ])
}

///|
test "map: a Bool result is usable as a filter predicate" {
  // The reified row predicate: a `map_many` returning `Scalar::Bool`.
  let kept = map_df().filter(
    @expr.map_many(label="keep", [@expr.col("q")], vs => {
      match vs[0] {
        @types.Scalar::Int(v) => @types.Scalar::Bool(v >= 3)
        _ => @types.Scalar::Bool(false)
      }
    }),
  )
  // Only the third row (q = 3) survives; the null row drops (false).
  assert_eq(kept.nrows(), 1)
  assert_eq(kept.get_column("base").to_scalars(), [@types.Scalar::Int(30)])
}

///|
test "map: a closure returning null on some rows yields a nullable column" {
  let out = map_df().with_columns([
    @expr.col("base")
    .map_elements(label="gate", s => {
      match s {
        @types.Scalar::Int(v) =>
          if v > 15 {
            @types.Scalar::Int(v)
          } else {
            @types.Scalar::Null
          }
        _ => @types.Scalar::Null
      }
    })
    .with_alias("gated"),
  ])
  // The leading null cell is skipped for dtype inference; the first non-null
  // (row 1) fixes the column to Int.
  assert_eq(out.get_column("gated").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
  ])
  // A nullable result stays on the Builtin backend.
  assert_eq(
    out.get_column("gated").storage_kind(),
    @column.StorageKind::Builtin,
  )
}

///|
test "map: a closure raise propagates from the consuming verb" {
  let result = try? map_df().with_columns([
    @expr.col("q").map_elements(label="boom", s => {
      match s {
        @types.Scalar::Int(v) => @types.Scalar::Int(v)
        _ => raise @types.DataError::InvalidOperation("null cell")
      }
    }),
  ])
  assert_eq(result, Err(@types.DataError::InvalidOperation("null cell")))
}

///|
test "map: an all-null result has no representable dtype and raises" {
  let result = try? map_df().with_columns([
    @expr.col("q").map_elements(label="nullify", _s => @types.Scalar::Null),
  ])
  assert_eq(
    result,
    Err(
      @types.DataError::Unsupported(
        "cannot infer the dtype of a map result with no non-null cell: no Null-dtype column backend",
      ),
    ),
  )
}

///|
test "map_many: an empty input list is a constant broadcast over the frame" {
  // `map_many([], f)` calls the closure once with no cells — a length-1
  // constant that broadcasts to every row, named "literal".
  let out = map_df().with_columns([
    @expr.map_many(label="const", [], _vs => @types.Scalar::Int(42)),
  ])
  assert_eq(out.get_column("literal").to_scalars(), [
    @types.Scalar::Int(42),
    @types.Scalar::Int(42),
    @types.Scalar::Int(42),
  ])
}

///|
test "map_many: a length-1 input broadcasts against a column input" {
  // Mixing a column and a literal — the literal is stretched to the column's
  // height before the closure runs.
  let out = map_df().with_columns([
    @expr.map_many(label="bump", [@expr.col("base"), @expr.lit_int(100)], vs => {
      @types.Scalar::Int(vs[0].as_int() + vs[1].as_int())
    }).with_alias("bumped"),
  ])
  assert_eq(out.get_column("bumped").to_scalars(), [
    @types.Scalar::Int(110),
    @types.Scalar::Int(120),
    @types.Scalar::Int(130),
  ])
}

///|
test "map_elements: used in select, producing a standalone column" {
  let out = map_df().select([
    @expr.col("tag").map_elements(label="up", s => {
      @types.Scalar::String(s.as_string() + "!")
    }),
  ])
  assert_eq(out.ncols(), 1)
  assert_eq(out.get_column("tag").to_scalars(), [
    @types.Scalar::String("a!"),
    @types.Scalar::String("b!"),
    @types.Scalar::String("c!"),
  ])
}

///|
test "map over an empty frame cannot infer a dtype and raises" {
  // The closure runs once per row — zero times here — so there is no
  // non-null cell to type the column, the same limit as a `Null` literal.
  let empty = DataFrame::new([Series::from_ints("i", [])])
  let result = try? empty.with_columns([
    @expr.col("i").map_elements(label="id", s => s),
  ])
  assert_eq(
    result,
    Err(
      @types.DataError::Unsupported(
        "cannot infer the dtype of a map result with no non-null cell: no Null-dtype column backend",
      ),
    ),
  )
}

///|
test "map_many as a filter predicate matches the native expression" {
  let df = map_df()
  // The `map_many` escape hatch reproduces a native predicate — keep rows
  // where `q >= 3`. The closure returns `Bool(false)` for the null cell
  // while the native `ge` returns null there, but both drop the row, so the
  // two filters agree row for row.
  let by_map = df.filter(
    @expr.map_many(label="keep", [@expr.col("q")], vs => {
      match vs[0] {
        @types.Scalar::Int(v) => @types.Scalar::Bool(v >= 3)
        _ => @types.Scalar::Bool(false)
      }
    }),
  )
  let by_native = df.filter(@expr.col("q").ge(@expr.lit_int(3)))
  assert_eq(by_map, by_native)
}
