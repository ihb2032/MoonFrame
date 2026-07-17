///|
/// Blackbox tests for the batched escape hatch `Expr::map_batches` — the
/// whole-`Series` UDF. Covers the row-wise form (`returns_scalar=false`)
/// through `with_columns` / `select`, backend canonicalisation, null handling,
/// closure error propagation, the length-1 broadcast, and the
/// `returns_scalar=true` form as a custom aggregation inside
/// `group_by(...).agg` (plus its rejection when the flag is omitted).

///|
/// A grouping key and a nullable Int payload — exercises the batched map's
/// null-through path and its use as a per-group reduction.
fn mb_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_strings("region", ["west", "east", "west", "east", "west"]),
    Series::from_int_options("q", [Some(1), None, Some(3), Some(4), Some(5)]),
  ])
}

///|
test "map_batches: applies the closure to the whole column at once (Int out)" {
  // Double every cell in one batched call; the null cell stays null.
  let out = mb_df().with_columns([
    @expr.col("q").map_batches(label="double", s => {
      Series::from_int_options(
        s.name(),
        s
        .to_scalars()
        .map(sc => {
          match sc {
            @types.Scalar::Int(v) => Some(v * 2)
            _ => None
          }
        }),
      )
    }),
  ])
  assert_eq(out.get_column("q").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("q").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Null,
    @types.Scalar::Int(6),
    @types.Scalar::Int(8),
    @types.Scalar::Int(10),
  ])
}

///|
test "map_batches: an all-valid numeric result converges onto Numeric" {
  let df = DataFrame::new([Series::from_ints("base", [10, 20, 30])])
  let out = df.with_columns([
    @expr.col("base")
    .map_batches(label="halved", s => {
      Series::from_floats(
        s.name(),
        s.to_scalars().map(sc => sc.as_int().to_double() / 2.0),
      )
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
  // canonicalisation that keeps `collect ≡ execute` even though the closure
  // built a plain `Builtin` series.
  assert_eq(out.get_column("half").storage_kind(), @column.StorageKind::Numeric)
}

///|
test "map_batches: used in select produces a standalone column" {
  // The identity closure returns its input verbatim; the result is named
  // after the leftmost input ("q").
  let out = mb_df().select([@expr.col("q").map_batches(label="id", s => s)])
  assert_eq(out.ncols(), 1)
  assert_eq(out.get_column("q").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Null,
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
  ])
}

///|
test "map_batches: a closure raise propagates from the consuming verb" {
  let result = Ok(
    mb_df().with_columns([
      @expr.col("q").map_batches(label="boom", _s => {
        raise @types.DataError::InvalidOperation("boom")
      }),
    ]),
  ) catch {
    e => Err(e)
  }
  assert_eq(result, Err(@types.DataError::InvalidOperation("boom")))
}

///|
test "map_batches: a length-1 result broadcasts over the frame in with_columns" {
  // A reducing closure used outside `agg`: its length-1 result broadcasts to
  // every row, exactly like a scalar literal.
  let df = DataFrame::new([Series::from_ints("v", [10, 20, 30])])
  let out = df.with_columns([
    @expr.col("v")
    .map_batches(label="total", returns_scalar=true, s => {
      Series::from_ints("total", [s.sum().as_int()])
    })
    .with_alias("total"),
  ])
  assert_eq(out.get_column("total").to_scalars(), [
    @types.Scalar::Int(60),
    @types.Scalar::Int(60),
    @types.Scalar::Int(60),
  ])
}

///|
test "map_batches: returns_scalar acts as a custom aggregation in agg" {
  // A "range" reduction (max - min) — not one of the built-in aggregations.
  // Each group's rows are handed to the closure, which returns a length-1
  // series that becomes the group's cell.
  let out = DataFrame::new([
      Series::from_strings("region", ["west", "east", "west", "east", "west"]),
      Series::from_ints("v", [10, 20, 30, 40, 50]),
    ])
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("v")
      .map_batches(label="range", returns_scalar=true, s => {
        let hi = s.max()
        let lo = s.min()
        match (hi, lo) {
          (@types.Scalar::Int(h), @types.Scalar::Int(l)) =>
            Series::from_ints("range", [h - l])
          _ => Series::from_ints("range", [])
        }
      })
      .with_alias("v_range"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["region", "v_range"])
  // west = rows [0,2,4] (10/30/50) → range 40; east = rows [1,3] (20/40) → 20.
  assert_eq(out.get_column("v_range").to_scalars(), [
    @types.Scalar::Int(40),
    @types.Scalar::Int(20),
  ])
}

///|
test "map_batches: a bare (non-scalar) map is rejected as an aggregation" {
  // Without `returns_scalar`, the node is row-wise, so the reduction-shape
  // gate rejects it before evaluation — the same gate a bare `col` trips.
  assert_eq(
    Ok(
      mb_df()
      .group_by([@expr.col("region")])
      .agg([@expr.col("q").map_batches(label="x", s => s)]),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::InvalidOperation(
        "aggregate expression must reduce each group to a single value: map_batches(\"x\", [col(q)])",
      ),
    ),
  )
}

///|
test "map_batches over an empty frame yields an empty column" {
  let empty = DataFrame::new([Series::from_ints("i", [])])
  let out = empty.with_columns([@expr.col("i").map_batches(label="id", s => s)])
  assert_eq(out.shape(), (0, 1))
  assert_eq(out.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("i").to_scalars(), [])
}
