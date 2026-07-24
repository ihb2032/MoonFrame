///|
/// Blackbox tests for the `LitSeries` literal-series node — `lit_series(s)` —
/// driven through the expression verbs. Covers the frame-tall append, the
/// in-place replace, the preserved nulls on the embedded series, the length-1
/// broadcast and the length-mismatch error, use inside a compound expression
/// and as a precomputed filter mask, standalone projection with naming, the
/// preserved backend, an aggregation over the literal, the empty-frame edge,
/// and the not-reduction-shaped rejection under `agg`.

///|
/// Three-row base frame for the literal-series tests.
fn lit_series_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
}

///|
test "lit_series: a frame-tall series appends as a new named column" {
  // A ready-made column joins the frame, named after the series, at the
  // rightmost position.
  let extra = Series::from_floats("c", [
    (1.5 : Double),
    (2.5 : Double),
    (3.5 : Double),
  ])
  let out = lit_series_df().with_columns([@expr.lit_series(extra)])
  assert_eq(out.columns(), ["a", "b", "c"])
  assert_eq(out.get_column("c").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("c").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(2.5),
    @types.Scalar::Float(3.5),
  ])
}

///|
test "lit_series: the embedded series keeps its nulls" {
  // The series is handed through verbatim, so a nullable column arrives with
  // its validity bitmap intact.
  let extra = Series::from_int_options("d", [Some(7), None, Some(9)])
  let out = lit_series_df().with_columns([@expr.lit_series(extra)])
  assert_eq(out.get_column("d").null_count(), 1)
  assert_eq(out.get_column("d").to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Null,
    @types.Scalar::Int(9),
  ])
}

///|
test "lit_series: a frame-tall series replaces an existing column in place" {
  // A same-named series replaces the existing column in place through
  // `with_columns`, keeping its original position (a fresh name appends).
  let replacement = Series::from_ints("a", [10, 20, 30])
  let out = lit_series_df().with_columns([@expr.lit_series(replacement)])
  assert_eq(out.columns(), ["a", "b"])
  assert_eq(out.get_column("a").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
  ])
}

///|
test "lit_series: a renamed series swaps a column in place, dtype and all" {
  // The retired `replace_column(name, s)` is `with_columns([lit_series(s.rename(name))])`:
  // renaming a differently-named series onto an existing column swaps it in
  // place — position and name preserved — with the dtype following the new
  // data (a cross-dtype swap, here Int → Float).
  let fresh = Series::from_floats("ignored", [
    (0.5 : Double),
    (1.5 : Double),
    (2.5 : Double),
  ])
  let out = lit_series_df().with_columns([@expr.lit_series(fresh.rename("a"))])
  assert_eq(out.columns(), ["a", "b"])
  assert_eq(out.get_column("a").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("a").to_scalars(), [
    @types.Scalar::Float(0.5),
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(2.5),
  ])
}

///|
test "lit_series: a length-1 series broadcasts over the frame" {
  // Like a scalar literal, a one-row series fills every row.
  let one = Series::from_ints("k", [7])
  let out = lit_series_df().with_columns([@expr.lit_series(one)])
  assert_eq(out.get_column("k").to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
  ])
}

///|
test "lit_series: a length neither 1 nor the frame height raises LengthMismatch" {
  let two = Series::from_ints("k", [1, 2])
  assert_eq(
    Ok(lit_series_df().with_columns([@expr.lit_series(two)])) catch {
      e => Err(e)
    },
    Err(@types.DataError::LengthMismatch),
  )
}

///|
// `select` agrees with `with_columns`: an off-length literal series is a
// LengthMismatch, not a silent change of the output row count. The frame is
// 3 rows; a 2-row literal series is neither frame-tall nor a length-1
// broadcast, even when it is the only projected column.
test "lit_series: select rejects an off-length series instead of resizing the frame" {
  let two = Series::from_ints("k", [1, 2])
  assert_eq(
    Ok(lit_series_df().select([@expr.lit_series(two)])) catch {
      e => Err(e)
    },
    Err(@types.DataError::LengthMismatch),
  )
}

///|
test "lit_series: combines positionally inside a compound expression" {
  // A frame-tall literal column is row-aligned with the frame, so it adds to
  // a column cell for cell.
  let bonus = Series::from_ints("bonus", [100, 200, 300])
  let out = lit_series_df().with_columns([
    (@expr.col("a") + @expr.lit_series(bonus)).with_alias("total"),
  ])
  assert_eq(out.get_column("total").to_scalars(), [
    @types.Scalar::Int(101),
    @types.Scalar::Int(202),
    @types.Scalar::Int(303),
  ])
}

///|
test "lit_series: a Bool series is usable as a precomputed filter mask" {
  let mask = Series::from_bools("keep", [true, false, true])
  let kept = lit_series_df().filter(@expr.lit_series(mask))
  assert_eq(kept.get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(3),
  ])
}

///|
test "lit_series: projects standalone, named after the series unless aliased" {
  let s = Series::from_ints("vals", [1, 2, 3])
  let out = lit_series_df().select([@expr.lit_series(s)])
  assert_eq(out.columns(), ["vals"])
  let aliased = lit_series_df().select([
    @expr.lit_series(s).with_alias("renamed"),
  ])
  assert_eq(aliased.columns(), ["renamed"])
}

///|
test "lit_series: returned verbatim, so its backend is preserved" {
  // A Numeric, all-valid series stays Numeric — `eval` hands it through, it
  // is not re-derived through `try_column_to_numeric` like a computed column.
  let num = Series::from_ints("n", [1, 2, 3])
  assert_eq(num.storage_kind(), @column.StorageKind::Numeric)
  let out = lit_series_df().with_columns([@expr.lit_series(num)])
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Numeric)
}

///|
test "lit_series: an aggregation over a literal series reduces it whole" {
  // `lit_series(s).sum()` is reduction-shaped (the enclosing `Agg`): it sums
  // the literal series itself — all four of its cells, independent of the
  // base frame's three rows — to one cell.
  let s = Series::from_ints("s", [10, 20, 30, 40])
  let out = lit_series_df().select([@expr.lit_series(s).sum().with_alias("t")])
  assert_eq(out.shape(), (1, 1))
  assert_eq(out.get_column("t").to_scalars(), [@types.Scalar::Int(100)])
}

///|
test "lit_series: a bare literal series is not reduction-shaped under agg" {
  // Row-wise like a bare column, so `agg([lit_series(s)])` raises — the shape
  // gate fires before any group work.
  let s = Series::from_ints("s", [1, 2, 3])
  let grouped = lit_series_df().group_by([@expr.col("b")])
  assert_true(
    (Ok(grouped.agg([@expr.lit_series(s)])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "lit_series on an empty frame accepts a 0-length series" {
  let empty = DataFrame::DataFrame([Series::from_ints("i", [])])
  let out = empty.with_columns([@expr.lit_series(Series::from_ints("z", []))])
  assert_eq(out.shape(), (0, 2))
  assert_eq(out.columns(), ["i", "z"])
}
